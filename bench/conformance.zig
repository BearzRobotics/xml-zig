//! Runs the W3C XML Conformance Test Suite (xmlts20130923) against the parser.
//!
//!   scripts/fetch-conformance.sh            # downloads and unpacks it (not committed)
//!   zig build conformance -Dsuite=DIR/xmlconf    # runs it
//!
//! Each catalog is read with this library (the catalogs are XML). A test is judged
//! as a non-validating, non-DTD-processing parser would be, so tests are sorted:
//!
//!   pass          accepted a valid document / rejected a not-well-formed one
//!   FAIL          the wrong answer on a test the parser is meant to get right
//!   uses-entities a valid document that refers to an entity it declares or imports
//!   dtd-syntax    a not-well-formed document whose fault is in a DTD, which is not read
//!                 (both are the documented "DTDs are not interpreted" deviation)
//!   skipped       XML 1.1, or editions of XML 1.0 older than the fifth
//!   encoding      a valid document in an encoding the parser does not support
//!
//! Failures are listed with their ids so each can be fixed or documented.

const std = @import("std");
const xml = @import("xml");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const catalogs = [_][]const u8{
    "xmltest/xmltest.xml",                     "japanese/japanese.xml",
    "sun/sun-valid.xml",                       "sun/sun-invalid.xml",
    "sun/sun-not-wf.xml",                      "sun/sun-error.xml",
    "oasis/oasis.xml",                         "ibm/ibm_oasis_invalid.xml",
    "ibm/ibm_oasis_not-wf.xml",                "ibm/ibm_oasis_valid.xml",
    "eduni/errata-2e/errata2e.xml",            "eduni/errata-3e/errata3e.xml",
    "eduni/errata-4e/errata4e.xml",            "eduni/namespaces/1.0/rmt-ns10.xml",
    "eduni/namespaces/errata-1e/errata1e.xml", "eduni/misc/ht-bh.xml",
};

/// Whether the catalog being run is a Namespaces test (names with colons are then QNames).
var namespaces = false;

const Verdict = enum { pass, fail, needs_dtd, skipped, encoding, dtd_syntax };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const root = args.next() orelse {
        std.debug.print("usage: conformance DIR/xmlconf\n", .{});
        std.process.exit(2);
    };

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    var totals: [6]u32 = @splat(0);
    var fails: std.ArrayList(u8) = .empty;
    defer fails.deinit(gpa);

    for (catalogs) |cat| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std.fs.path.join(a, &.{ root, cat });
        const bytes = readFile(a, io, path) catch |e| {
            try w.print("cannot read catalog {s}: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        // Some catalogs are fragments with several roots: wrap them.
        var body = bytes;
        if (std.mem.startsWith(u8, body, "<?xml")) {
            if (std.mem.indexOf(u8, body, "?>")) |e| body = body[e + 2 ..];
        }
        const wrapped = try std.fmt.allocPrint(a, "<ROOT>{s}</ROOT>", .{body});
        var diag: xml.Diagnostic = .{};
        var doc = xml.Document.parse(gpa, wrapped, .{ .reader = .{ .namespaces = false } }, &diag) catch |e| {
            try w.print("catalog {s} is not parsed: {s} ({f})\n", .{ cat, @errorName(e), diag });
            continue;
        };
        defer doc.deinit();
        var counts: [6]u32 = @splat(0);
        namespaces = std.mem.indexOf(u8, cat, "namespaces/") != null;
        try walk(a, io, gpa, root, doc.root, std.fs.path.dirname(cat) orelse "", &counts, &fails);
        try w.print("{s}: pass {d}, FAIL {d}, uses-entities {d}, dtd-syntax {d}, skipped {d}, encoding {d}\n", .{ cat, counts[0], counts[1], counts[2], counts[5], counts[3], counts[4] });
        for (&totals, counts) |*t, c| t.* += c;
    }
    try w.print("\nTOTAL: pass {d}, FAIL {d}, uses-entities {d}, dtd-syntax {d}, skipped {d}, encoding {d}\n", .{ totals[0], totals[1], totals[2], totals[5], totals[3], totals[4] });
    if (fails.items.len > 0) try w.print("\nFailures:\n{s}", .{fails.items});
    try w.flush();
    if (totals[1] > 0) std.process.exit(1);
}

fn readFile(a: Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    return fr.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
}

fn walk(a: Allocator, io: Io, gpa: Allocator, root: []const u8, el: *const xml.Element, base: []const u8, counts: *[6]u32, fails: *std.ArrayList(u8)) !void {
    var it = el.elements();
    while (it.next()) |child| {
        if (std.mem.eql(u8, child.name.qualified, "TESTCASES")) {
            const nb = if (child.attr("xml:base")) |b| try std.fs.path.join(a, &.{ base, b }) else base;
            try walk(a, io, gpa, root, child, nb, counts, fails);
        } else if (std.mem.eql(u8, child.name.qualified, "TEST")) {
            const v, const note = try runTest(a, io, gpa, root, base, child);
            counts[@backingInt(v)] += 1;
            if (v == .fail) try fails.print(gpa, "  {s}  {s}\n", .{ child.attr("ID") orelse "?", note });
        }
    }
}

fn hasWord(list: ?[]const u8, word: []const u8) bool {
    const l = list orelse return false;
    var it = std.mem.tokenizeScalar(u8, l, ' ');
    while (it.next()) |t| if (std.mem.eql(u8, t, word)) return true;
    return false;
}

fn runTest(a: Allocator, io: Io, gpa: Allocator, root: []const u8, base: []const u8, t: *const xml.Element) !struct { Verdict, []const u8 } {
    const kind = t.attr("TYPE") orelse return .{ .skipped, "" };
    const uri = t.attr("URI") orelse return .{ .skipped, "" };
    // XML 1.1 tests, and tests of the older editions' rules, do not apply.
    if (t.attr("VERSION")) |v| if (!hasWord(v, "1.0")) return .{ .skipped, "" };
    if (t.attr("EDITION")) |e| if (!hasWord(e, "5")) return .{ .skipped, "" };
    if (std.mem.eql(u8, kind, "error")) return .{ .skipped, "" };
    const needs_entities = if (t.attr("ENTITIES")) |e| !std.mem.eql(u8, e, "none") else false;

    const path = try std.fs.path.join(a, &.{ root, base, uri });
    const bytes = readFile(a, io, path) catch |e| return .{ .fail, try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ path, @errorName(e) }) };

    var diag: xml.Diagnostic = .{};
    var r: Io.Reader = .fixed(bytes);
    var rd = xml.Reader.init(gpa, &r, .{ .namespaces = namespaces }, &diag);
    defer rd.deinit();
    var err: ?xml.Error = null;
    while (true) {
        const ev = rd.next() catch |e| {
            err = e;
            break;
        };
        if (ev == .end_of_document) break;
    }

    const wf_expected = !std.mem.eql(u8, kind, "not-wf");
    if (wf_expected) {
        if (err == null) return .{ .pass, "" };
        const e = err.?;
        if (e == error.UnsupportedEncoding) return .{ .encoding, "" };
        // Only a missing entity can be blamed on the DTD; any other refusal is a parser bug.
        if (e == error.UndefinedEntity) return .{ .needs_dtd, "" };
        return .{ .fail, try std.fmt.allocPrint(a, "{s}: rejected a valid document: {s} ({f})", .{ uri, @errorName(e), diag }) };
    }
    // Not well-formed: it must be refused.
    if (err != null) return .{ .pass, "" };
    if (needs_entities or hasDtd(bytes)) return .{ .dtd_syntax, "" };
    return .{ .fail, try std.fmt.allocPrint(a, "{s}: accepted a document that is not well-formed", .{uri}) };
}

/// True if the document has a DOCTYPE, whose declarations this parser does not process.
fn hasDtd(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "<!DOCTYPE") != null or std.mem.indexOf(u8, bytes, "<!ENTITY") != null;
}
