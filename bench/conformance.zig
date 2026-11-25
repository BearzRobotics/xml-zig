//! Runs the W3C XML Conformance Test Suite (xmlts20130923) against the parser.
//!
//!   scripts/fetch-conformance.sh            # downloads and unpacks it (not committed)
//!   zig build conformance -Dsuite=DIR/xmlconf    # runs it
//!
//! Each catalog is read with this library (the catalogs are XML). A test is judged
//! as a non-validating, non-DTD-processing parser would be:
//!
//!   - a valid document must be accepted; where the suite gives its canonical form, what was
//!     read must match it; and writing it back with `Document.write` must preserve it;
//!   - a not-well-formed document must be refused.
//!
//! Where the parser cannot meet that because DTDs are not interpreted, the test is listed by id
//! in `conformance_excused.txt` with the one way it is allowed to fall short. Nothing is excused
//! by guesswork: an unlisted shortfall is a FAIL, and so is a listed one that no longer happens.
//! XML 1.1 tests and those of editions before the fifth are skipped.
//!
//! A refusal of a not-well-formed document passes whatever its reason. Those refused only for
//! an unknown entity or an unsupported encoding, which may not be the fault under test, are
//! also counted, so that the number cannot grow unseen.

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

/// Tests in each catalog of xmlts20130923, in the order above.
const catalog_sizes = [catalogs.len]u32{ 365, 12, 28, 74, 56, 1, 348, 48, 731, 149, 34, 13, 393, 48, 3, 9 };

/// Whether the catalog being run is a Namespaces test (names with colons are then QNames).
var namespaces = false;

const Verdict = enum { pass, fail, entities, dtd_fault, dtd_output, skipped };
const verdicts = @typeInfo(Verdict).@"enum".field_names.len;

/// The ways a listed test may fall short; the names used in the list.
const Excuse = enum {
    /// A valid document refused with `UndefinedEntity`: it uses an entity its DTD declares or imports.
    entities,
    /// A not-well-formed document accepted: the fault is in what the DTD declares, or needs it.
    dtd_fault,
    /// A valid document accepted, with output differing from the canonical form because the DTD
    /// would have changed it (default or tokenized attribute values, notations).
    dtd_output,
};

const Excused = struct { excuse: Excuse, seen: bool = false };

/// Not-well-formed documents refused for a reason that may not be the one under test.
/// A change in their number means refusals have moved; look before updating it.
var indirect_refusals: u32 = 0;
const expected_indirect: u32 = 99;

fn readExcuses(a: Allocator) !std.StringArrayHashMapUnmanaged(Excused) {
    var map: std.StringArrayHashMapUnmanaged(Excused) = .empty;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("conformance_excused.txt"), '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const reason = words.next() orelse continue;
        const excuse = std.meta.stringToEnum(Excuse, reason) orelse return error.UnknownExcuse;
        while (words.next()) |id| {
            const entry = try map.getOrPut(a, id);
            if (entry.found_existing) return error.TestExcusedTwice;
            entry.value_ptr.* = .{ .excuse = excuse };
        }
    }
    return map;
}

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

    var excuse_arena = std.heap.ArenaAllocator.init(gpa);
    defer excuse_arena.deinit();
    var excuses = try readExcuses(excuse_arena.allocator());

    var totals: [verdicts]u32 = @splat(0);
    var fails: std.ArrayList(u8) = .empty;
    defer fails.deinit(gpa);
    // A run that could not load its tests must not look like a run that passed them.
    var broken_catalogs: u32 = 0;

    for (catalogs, catalog_sizes) |cat, size| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std.fs.path.join(a, &.{ root, cat });
        const bytes = readFile(a, io, path) catch |e| {
            try w.print("cannot read catalog {s}: {s}\n", .{ path, @errorName(e) });
            broken_catalogs += 1;
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
            broken_catalogs += 1;
            continue;
        };
        defer doc.deinit();
        var counts: [verdicts]u32 = @splat(0);
        namespaces = std.mem.indexOf(u8, cat, "namespaces/") != null;
        try walk(a, io, gpa, root, doc.root, std.fs.path.dirname(cat) orelse "", &excuses, &counts, &fails);
        try w.print("{s}: ", .{cat});
        try printCounts(w, counts);
        var ran: u32 = 0;
        for (counts) |c| ran += c;
        if (ran != size) {
            try w.print("catalog {s}: found {d} tests, expected {d}\n", .{ cat, ran, size });
            broken_catalogs += 1;
        }
        for (&totals, counts) |*t, c| t.* += c;
    }
    try w.writeAll("\nTOTAL: ");
    try printCounts(w, totals);
    try w.print("refused for an entity or encoding, among the not-well-formed passes: {d} (expected {d})\n", .{ indirect_refusals, expected_indirect });
    var stale: u32 = 0;
    for (excuses.keys(), excuses.values()) |id, e| if (!e.seen) {
        stale += 1;
        try fails.print(gpa, "  {s}  listed as {s}, but no such test fell short that way\n", .{ id, @tagName(e.excuse) });
    };
    if (fails.items.len > 0) try w.print("\nFailures:\n{s}", .{fails.items});
    try w.flush();
    if (broken_catalogs > 0) try w.print("\n{d} catalog(s) missing, unreadable or incomplete\n", .{broken_catalogs});
    try w.flush();
    if (totals[@backingInt(Verdict.fail)] > 0 or stale > 0 or broken_catalogs > 0 or indirect_refusals != expected_indirect) std.process.exit(1);
}

fn readFile(a: Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    return fr.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
}

fn printCounts(w: *Io.Writer, c: [verdicts]u32) !void {
    try w.print("pass {d}, FAIL {d}, excused: entities {d}, dtd-fault {d}, dtd-output {d}; skipped {d}\n", .{ c[0], c[1], c[2], c[3], c[4], c[5] });
}

fn walk(a: Allocator, io: Io, gpa: Allocator, root: []const u8, el: *const xml.Element, base: []const u8, excuses: *std.StringArrayHashMapUnmanaged(Excused), counts: *[verdicts]u32, fails: *std.ArrayList(u8)) !void {
    var it = el.elements();
    while (it.next()) |child| {
        if (std.mem.eql(u8, child.name.qualified, "TESTCASES")) {
            const nb = if (child.attr("xml:base")) |b| try std.fs.path.join(a, &.{ base, b }) else base;
            try walk(a, io, gpa, root, child, nb, excuses, counts, fails);
        } else if (std.mem.eql(u8, child.name.qualified, "TEST")) {
            const id = child.attr("ID") orelse "?";
            const result = try runTest(a, io, gpa, root, base, child);
            var verdict: Verdict = switch (result) {
                .pass => .pass,
                .skipped => .skipped,
                .fail, .short => .fail,
            };
            var note: []const u8 = if (result == .fail) result.fail else "";
            if (result == .short) {
                note = result.short.note;
                if (excuses.getPtr(id)) |e| if (e.excuse == result.short.excuse) {
                    e.seen = true;
                    verdict = switch (e.excuse) {
                        .entities => .entities,
                        .dtd_fault => .dtd_fault,
                        .dtd_output => .dtd_output,
                    };
                };
                if (verdict == .fail) note = try std.fmt.allocPrint(a, "{s} [would be excused as {s}]", .{ note, @tagName(result.short.excuse) });
            }
            counts[@backingInt(verdict)] += 1;
            if (verdict == .fail) try fails.print(gpa, "  {s}  {s}\n", .{ id, note });
        }
    }
}

const Result = union(enum) {
    pass,
    skipped,
    /// Wrong, and nothing can excuse it.
    fail: []const u8,
    /// Wrong in a way that not interpreting DTDs could explain, if the test is listed for it.
    short: struct { excuse: Excuse, note: []const u8 },
};

fn hasWord(list: ?[]const u8, word: []const u8) bool {
    const l = list orelse return false;
    var it = std.mem.tokenizeScalar(u8, l, ' ');
    while (it.next()) |t| if (std.mem.eql(u8, t, word)) return true;
    return false;
}

fn runTest(a: Allocator, io: Io, gpa: Allocator, root: []const u8, base: []const u8, t: *const xml.Element) !Result {
    const kind = t.attr("TYPE") orelse return .{ .fail = "the catalog gives no TYPE" };
    const uri = t.attr("URI") orelse return .{ .fail = "the catalog gives no URI" };
    // XML 1.1 tests, and tests of the older editions' rules, do not apply.
    if (t.attr("VERSION")) |v| if (!hasWord(v, "1.0")) return .skipped;
    if (t.attr("EDITION")) |e| if (!hasWord(e, "5")) return .skipped;
    // "error" tests are optional for a processor to report.
    if (std.mem.eql(u8, kind, "error")) return .skipped;

    const path = try std.fs.path.join(a, &.{ root, base, uri });
    const bytes = readFile(a, io, path) catch |e| return .{ .fail = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ path, @errorName(e) }) };

    var diag: xml.Diagnostic = .{};
    var read: std.Io.Writer.Allocating = .init(a);
    var err: ?xml.Error = null;
    canonical(a, gpa, bytes, &read.writer, &diag) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |parse_error| err = parse_error,
    };

    if (std.mem.eql(u8, kind, "not-wf")) {
        if (err) |e| {
            if (e == error.UndefinedEntity or e == error.UnsupportedEncoding) indirect_refusals += 1;
            return .pass;
        }
        return .{ .short = .{ .excuse = .dtd_fault, .note = try std.fmt.allocPrint(a, "{s}: accepted a document that is not well-formed", .{uri}) } };
    }

    if (err) |e| {
        const note = try std.fmt.allocPrint(a, "{s}: rejected a valid document: {s} ({f})", .{ uri, @errorName(e), diag });
        // Only a missing entity can be blamed on the DTD; any other refusal is a parser bug.
        return if (e == error.UndefinedEntity) .{ .short = .{ .excuse = .entities, .note = note } } else .{ .fail = note };
    }

    // The tree and the writer: what is written back must read as the same document.
    var doc = xml.Document.parse(gpa, bytes, .{ .reader = .{ .namespaces = namespaces } }, &diag) catch |e|
        return .{ .fail = try std.fmt.allocPrint(a, "{s}: Document.parse: {s} ({f})", .{ uri, @errorName(e), diag }) };
    defer doc.deinit();
    var written: std.Io.Writer.Allocating = .init(a);
    doc.write(gpa, &written.writer, .{}) catch |e| return .{ .fail = try std.fmt.allocPrint(a, "{s}: Document.write: {s}", .{ uri, @errorName(e) }) };
    var reread: std.Io.Writer.Allocating = .init(a);
    canonical(a, gpa, written.written(), &reread.writer, &diag) catch |e|
        return .{ .fail = try std.fmt.allocPrint(a, "{s}: what was written back does not parse: {s} ({f})", .{ uri, @errorName(e), diag }) };
    if (!std.mem.eql(u8, read.written(), reread.written())) return .{ .fail = try std.fmt.allocPrint(a, "{s}: writing the document back changed it", .{uri}) };

    if (t.attr("OUTPUT")) |output| {
        const output_path = try std.fs.path.join(a, &.{ root, base, output });
        var want: []const u8 = readFile(a, io, output_path) catch |e| return .{ .fail = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ output_path, @errorName(e) }) };
        // The "second canonical form" starts with the notations, which only the DTD declares.
        const notations = std.mem.startsWith(u8, want, "<!DOCTYPE");
        if (notations) {
            if (std.mem.indexOf(u8, want, "]>\n")) |end| want = want[end + 3 ..];
        }
        if (!std.mem.eql(u8, read.written(), want) or notations)
            return .{ .short = .{ .excuse = .dtd_output, .note = try std.fmt.allocPrint(a, "{s}: differs from the canonical form {s}", .{ uri, output }) } };
    }
    return .pass;
}

/// Reads `bytes` and writes the suite's canonical form of what was read: no declaration, comments
/// or DOCTYPE; attributes in order of name; every element with an end tag; CDATA as text.
fn canonical(a: Allocator, gpa: Allocator, bytes: []const u8, w: *Io.Writer, diag: *xml.Diagnostic) (xml.Error || Io.Writer.Error)!void {
    var r: Io.Reader = .fixed(bytes);
    var rd = xml.Reader.init(gpa, &r, .{ .namespaces = namespaces }, diag);
    defer rd.deinit();
    while (true) switch (try rd.next()) {
        .start_element => |s| {
            try w.print("<{s}", .{s.name.qualified});
            const sorted = try a.dupe(xml.Attribute, s.attributes);
            std.mem.sort(xml.Attribute, sorted, {}, byName);
            for (sorted) |at| {
                try w.print(" {s}=\"", .{at.name.qualified});
                try canonicalText(w, at.value);
                try w.writeByte('"');
            }
            try w.writeByte('>');
        },
        .end_element => |e| try w.print("</{s}>", .{e.name.qualified}),
        .text, .cdata => |t| try canonicalText(w, t),
        .processing_instruction => |p| try w.print("<?{s} {s}?>", .{ p.target, p.data }),
        .xml_decl, .comment, .doctype => {},
        .end_of_document => return,
    };
}

fn byName(_: void, a: xml.Attribute, b: xml.Attribute) bool {
    return std.mem.lessThan(u8, a.name.qualified, b.name.qualified);
}

fn canonicalText(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |b| switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\t' => try w.writeAll("&#9;"),
        '\n' => try w.writeAll("&#10;"),
        '\r' => try w.writeAll("&#13;"),
        else => try w.writeByte(b),
    };
}
