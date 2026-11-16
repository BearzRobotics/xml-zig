//! `xml-parse`: a small command line over the library, for checking files and
//! comparing builds with `poop`.
//!
//!   xml-parse check FILE...   exit 1 and print line:column if a file is not well-formed
//!   xml-parse events FILE     one line per event
//!   xml-parse text FILE       the character data only

const std = @import("std");
const xml = @import("xml");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const cmd = args.next() orelse return usage(io);
    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    defer out.interface.flush() catch {};

    if (std.mem.eql(u8, cmd, "check")) {
        var bad: u32 = 0;
        while (args.next()) |path| {
            var diag: xml.Diagnostic = .{};
            run(gpa, io, path, .check, &out.interface, &diag) catch |e| {
                bad += 1;
                try out.interface.print("{s}:{f}: {s}\n", .{ path, diag, @errorName(e) });
            };
        }
        try out.interface.flush();
        if (bad > 0) std.process.exit(1);
        return;
    }
    const mode: Mode = if (std.mem.eql(u8, cmd, "events")) .events else if (std.mem.eql(u8, cmd, "text")) .text else return usage(io);
    const path = args.next() orelse return usage(io);
    var diag: xml.Diagnostic = .{};
    run(gpa, io, path, mode, &out.interface, &diag) catch |e| {
        try out.interface.flush();
        std.debug.print("{s}:{f}: {s}\n", .{ path, diag, @errorName(e) });
        std.process.exit(1);
    };
}

const Mode = enum { check, events, text };

fn usage(io: Io) !void {
    _ = io;
    std.debug.print("usage: xml-parse check FILE... | events FILE | text FILE\n", .{});
    std.process.exit(2);
}

fn run(gpa: std.mem.Allocator, io: Io, path: []const u8, mode: Mode, w: *Io.Writer, diag: *xml.Diagnostic) !void {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    var rd = xml.Reader.init(gpa, &fr.interface, .{}, diag);
    defer rd.deinit();
    while (true) {
        const ev = try rd.next();
        switch (ev) {
            .end_of_document => break,
            .text, .cdata => |t| if (mode == .text) try w.writeAll(t) else if (mode == .events) try w.print("{s} {d} bytes\n", .{ @tagName(ev), t.len }),
            .start_element => |s| if (mode == .events) try w.print("start {s} ({d} attributes)\n", .{ s.name.qualified, s.attributes.len }),
            .end_element => |e| if (mode == .events) try w.print("end {s}\n", .{e.name.qualified}),
            else => if (mode == .events) try w.print("{s}\n", .{@tagName(ev)}),
        }
    }
}
