//! `xml-parse`: a small command line over the library, for checking files and
//! comparing builds with `poop`.
//!
//!   xml-parse check FILE...   exit 1 and print line:column if a file is not well-formed
//!   xml-parse events FILE     one line per event
//!   xml-parse text FILE       the character data only

const std = @import("std");
const xml = @import("xml");
const Io = std.Io;

const usage_text = "usage: xml-parse check FILE... | events FILE | text FILE\n";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const status = command(gpa, io, &args, &out.interface) catch |e| fail(e);
    // Flushed here and not in a `defer`: output that cannot be written must change the status.
    out.interface.flush() catch |e| fail(e);
    if (status != 0) std.process.exit(status);
}

fn fail(e: anyerror) noreturn {
    std.debug.print("xml-parse: {s}\n", .{@errorName(e)});
    std.process.exit(1);
}

fn usage() u8 {
    std.debug.print(usage_text, .{});
    return 2;
}

/// Runs the command in `args`, writing to `out`; returns the exit status.
fn command(gpa: std.mem.Allocator, io: Io, args: *std.process.Args.Iterator, out: *Io.Writer) !u8 {
    const cmd = args.next() orelse return usage();
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage_text);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "check")) {
        var status: u8 = 0;
        var path = args.next() orelse return usage(); // checking nothing must not look like success
        while (true) {
            var diag: xml.Diagnostic = .{};
            run(gpa, io, path, .check, out, &diag) catch |e| {
                status = 1;
                if (diag.line == 0) {
                    try out.print("{s}: {s}\n", .{ path, @errorName(e) });
                } else try out.print("{s}:{f}: {s}\n", .{ path, diag, @errorName(e) });
            };
            path = args.next() orelse return status;
        }
    }

    const mode: Mode = if (std.mem.eql(u8, cmd, "events")) .events else if (std.mem.eql(u8, cmd, "text")) .text else return usage();
    const path = args.next() orelse return usage();
    if (args.next() != null) return usage();
    var diag: xml.Diagnostic = .{};
    run(gpa, io, path, mode, out, &diag) catch |e| {
        if (e == error.WriteFailed) return e;
        try out.flush(); // what was read before the fault comes first
        if (diag.line == 0) {
            std.debug.print("{s}: {s}\n", .{ path, @errorName(e) });
        } else std.debug.print("{s}:{f}: {s}\n", .{ path, diag, @errorName(e) });
        return 1;
    };
    return 0;
}

const Mode = enum { check, events, text };

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
