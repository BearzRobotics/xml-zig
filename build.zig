//! xml-zig build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Manual pages (Markdown, read by dkman and dkde-help): share/man/manN/NAME.N.md.
    // The section N is the number in the file name.
    if (b.option(bool, "man", "Install the manual pages (default: on)") orelse true) {
        const pages = [_][]const u8{ "xml-parse.1.md", "xml-zig.3.md" };
        for (pages) |page| {
            const stem = page[0 .. page.len - ".md".len];
            const section = stem[std.mem.lastIndexOfScalar(u8, stem, '.').? + 1 ..];
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                b.path(b.fmt("docs/manpages/{s}", .{page})),
                .{ .custom = b.fmt("share/man/man{s}", .{section}) },
                page,
            ).step);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("xml").
    const mod = b.addModule("xml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit and conformance tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // A command line over the library: check, list events, extract text.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("bench/xml_parse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "xml", .module = mod }},
    });
    const cli_exe = b.addExecutable(.{ .name = "xml-parse", .root_module = cli_mod });
    const cli_step = b.step("cli", "Build zig-out/bin/xml-parse");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    // The W3C conformance suite (fetched separately; see scripts/fetch-conformance.sh).
    const conf_mod = b.createModule(.{
        .root_source_file = b.path("bench/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "xml", .module = mod }},
    });
    const conf_exe = b.addExecutable(.{ .name = "xml-conformance", .root_module = conf_mod });
    const conf_run = b.addRunArtifact(conf_exe);
    if (b.option([]const u8, "suite", "Path of the unpacked suite xmlconf directory")) |dir| conf_run.addArg(dir);
    const conf_step = b.step("conformance", "Run the W3C XML conformance suite (zig build conformance -Dsuite=DIR/xmlconf)");
    conf_step.dependOn(&conf_run.step);
}
