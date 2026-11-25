//! Generated and mutated documents, held to properties that must be true of any input:
//! the parser never crashes or leaks; whatever it accepts, `Document.write` writes back so that
//! it parses to the same tree; and writing with an indent changes no text.
//!
//! Random bytes almost never get past the first character, so the inputs here are built from the
//! pieces of XML, and then damaged. Each test also checks how far its inputs get, so that it
//! cannot quietly stop exercising anything. The seeds are fixed: a failure repeats.

const std = @import("std");
const xml = @import("root.zig");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Rand = std.Random;

// ------------------------------------------------------------ tree equality

fn expectSameName(a: xml.Name, b: xml.Name) !void {
    try testing.expectEqualStrings(a.qualified, b.qualified);
    try testing.expectEqualStrings(a.prefix, b.prefix);
    try testing.expectEqualStrings(a.local, b.local);
    try testing.expectEqualStrings(a.uri, b.uri);
}

fn isBlank(n: xml.Node) bool {
    return n == .text and std.mem.trim(u8, n.text, " \t\n\r").len == 0;
}

fn holdsText(e: *const xml.Element) bool {
    for (e.children) |c| if (c == .text or c == .cdata) return true;
    return false;
}

const Compare = enum {
    exact,
    /// The second tree was written with an indent from the first. In an element that holds no
    /// text (nor sits inside one that does), whitespace may have been added between children.
    indented,
};

fn expectSameElement(a: *const xml.Element, b: *const xml.Element, how: Compare) !void {
    try expectSameName(a.name, b.name);
    try testing.expectEqual(a.attributes.len, b.attributes.len);
    for (a.attributes, b.attributes) |x, y| {
        try expectSameName(x.name, y.name);
        try testing.expectEqualStrings(x.value, y.value);
    }
    const preserved = std.mem.eql(u8, a.attr("xml:space") orelse "", "preserve");
    const loose = how == .indented and !holdsText(a) and !preserved;
    const inner: Compare = if (loose) .indented else .exact;
    if (!loose) {
        try testing.expectEqual(a.children.len, b.children.len);
        // `<a/>` and `<a></a>` are told apart only when the element is empty.
        if (a.children.len == 0) try testing.expectEqual(a.self_closing, b.self_closing);
    }
    var j: usize = 0;
    for (a.children) |x| {
        if (loose) while (j < b.children.len and isBlank(b.children[j])) : (j += 1) {};
        try testing.expect(j < b.children.len);
        const y = b.children[j];
        j += 1;
        try testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
        switch (x) {
            .element => |e| try expectSameElement(e, y.element, inner),
            .text => |t| try testing.expectEqualStrings(t, y.text),
            .cdata => |t| try testing.expectEqualStrings(t, y.cdata),
            .comment => |t| try testing.expectEqualStrings(t, y.comment),
            .processing_instruction => |p| {
                try testing.expectEqualStrings(p.target, y.processing_instruction.target);
                try testing.expectEqualStrings(p.data, y.processing_instruction.data);
            },
        }
    }
    if (loose) while (j < b.children.len and isBlank(b.children[j])) : (j += 1) {};
    try testing.expectEqual(b.children.len, j);
}

fn expectSameMisc(a: anytype, b: @TypeOf(a)) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
        switch (x) {
            .comment => |t| try testing.expectEqualStrings(t, y.comment),
            .doctype => |t| try testing.expectEqualStrings(t, y.doctype),
            .processing_instruction => |p| {
                try testing.expectEqualStrings(p.target, y.processing_instruction.target);
                try testing.expectEqualStrings(p.data, y.processing_instruction.data);
            },
        }
    }
}

fn expectSameDocument(a: *const xml.Document, b: *const xml.Document, how: Compare) !void {
    try testing.expectEqual(a.declaration == null, b.declaration == null);
    if (a.declaration) |d| {
        try testing.expectEqualStrings(d.version, b.declaration.?.version);
        try testing.expectEqual(d.standalone, b.declaration.?.standalone);
        try testing.expectEqual(d.encoding == null, b.declaration.?.encoding == null);
    }
    try expectSameMisc(a.prolog, b.prolog);
    try expectSameElement(a.root, b.root, how);
    try expectSameMisc(a.epilog, b.epilog);
}

/// If `src` parses, writing it must give back the same tree, plainly and indented.
/// Returns whether it parsed.
fn checkRoundTrip(src: []const u8, namespaces: bool) !bool {
    const options: xml.dom.Options = .{ .reader = .{ .namespaces = namespaces } };
    var doc = xml.Document.parse(testing.allocator, src, options, null) catch return false;
    defer doc.deinit();
    for ([_]u8{ 0, 2 }) |indent| {
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        errdefer std.debug.print("indent {d}\nread:    \"{f}\"\nwritten: \"{f}\"\n", .{ indent, std.zig.fmtString(src), std.zig.fmtString(out.written()) });
        try doc.write(testing.allocator, &out.writer, .{ .indent = indent });
        var again = try xml.Document.parse(testing.allocator, out.written(), options, null);
        defer again.deinit();
        try expectSameDocument(&doc, &again, if (indent == 0) .exact else .indented);
    }
    return true;
}

/// Reads `src` to the end or to its first error. Returns the number of start tags seen, and
/// whether it was accepted.
fn read(src: []const u8, options: xml.Options) struct { starts: u32, accepted: bool } {
    var r: Io.Reader = .fixed(src);
    var rd = xml.Reader.init(testing.allocator, &r, options, null);
    defer rd.deinit();
    var starts: u32 = 0;
    while (true) {
        const ev = rd.next() catch return .{ .starts = starts, .accepted = false };
        if (ev == .start_element) starts += 1;
        if (ev == .end_of_document) return .{ .starts = starts, .accepted = true };
    }
}

// ------------------------------------------------------------ generation

const Generator = struct {
    rand: Rand,
    out: std.ArrayList(u8) = .empty,

    fn add(g: *Generator, s: []const u8) !void {
        try g.out.appendSlice(testing.allocator, s);
    }

    fn pick(g: *Generator, choices: []const []const u8) []const u8 {
        return choices[g.rand.uintLessThan(usize, choices.len)];
    }

    fn some(g: *Generator, choices: []const []const u8, at_most: usize) !void {
        for (0..g.rand.uintLessThan(usize, at_most + 1)) |_| try g.add(g.pick(choices));
    }

    const text_pieces = [_][]const u8{ "a", "word ", " ", "\n", "\r\n", "\r", "\t", "é", "日本", "\u{1F600}", "&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&#13;", "&#10;", "&#9;", "&#32;", "&#x1F600;", "]", "]]", ">", "\"", "'", "=", "/", "?", "-", "--", "!" };
    const value_pieces = [_][]const u8{ "v", " ", "\n", "\r\n", "\t", "é", "&amp;", "&lt;", "&quot;", "&apos;", "&#13;", "&#10;", "&#9;", ">", "]]>", "/", "--", "?>" };
    const markup_pieces = [_][]const u8{ "x", " ", "\n", "\r\n", "é", "<", ">", "&", "\"", "'", "]", "]]", "-", "?", "!", "/" };
    const names = [_][]const u8{ "a", "b", "item", "é", "_x", "a.b-1", "p:a", "p:b", "q:c" };
    const attribute_names = [_][]const u8{ "k", "id", "é", "p:k", "q:k", "p:id", "xml:lang", "xml:space" };

    fn comment(g: *Generator) !void {
        try g.add("<!--");
        try g.some(&markup_pieces, 5);
        try g.add("-->");
    }

    fn pi(g: *Generator) !void {
        try g.add("<?");
        try g.add(g.pick(&.{ "t", "render", "xml-stylesheet" }));
        if (g.rand.boolean()) {
            try g.add(g.pick(&.{ " ", "\r\n", "\t " }));
            try g.some(&markup_pieces, 5);
        }
        try g.add("?>");
    }

    fn element(g: *Generator, depth: u32, root: bool) !void {
        const name = g.pick(&names);
        try g.add("<");
        try g.add(name);
        // Declared on the root, so that prefixes are usually bound; sometimes redeclared below.
        if (root) try g.add(" xmlns:p='urn:p' xmlns:q='urn:q'");
        if (g.rand.uintLessThan(u8, 12) == 0) try g.add(g.pick(&.{ " xmlns='urn:d'", " xmlns=''", " xmlns:p='urn:other'", " xmlns:q='urn:p'" }));
        for (0..g.rand.uintLessThan(usize, 3)) |_| {
            try g.add(" ");
            const key = g.pick(&attribute_names);
            try g.add(key);
            try g.add("=\"");
            if (std.mem.eql(u8, key, "xml:space")) {
                try g.add(g.pick(&.{ "preserve", "default" }));
            } else {
                // Either quote may appear inside the other.
                for (0..g.rand.uintLessThan(usize, 4)) |_| {
                    const piece = g.pick(&value_pieces);
                    try g.add(piece);
                }
            }
            try g.add("\"");
        }
        if (g.rand.uintLessThan(u8, 5) == 0) return g.add("/>");
        try g.add(">");
        for (0..g.rand.uintLessThan(usize, 5)) |_| switch (g.rand.uintLessThan(u8, 8)) {
            0, 1, 2 => if (depth < 4) try g.element(depth + 1, false),
            3 => try g.some(&text_pieces, 6),
            4 => try g.add(g.pick(&.{ "\n  ", " ", "\r\n\t" })),
            5 => try g.comment(),
            6 => try g.pi(),
            else => {
                try g.add("<![CDATA[");
                try g.some(&markup_pieces, 5);
                try g.add("]]>");
            },
        };
        try g.add("</");
        try g.add(name);
        try g.add(g.pick(&.{ ">", ">", " >", "\n>" }));
    }

    fn misc(g: *Generator) !void {
        for (0..g.rand.uintLessThan(usize, 3)) |_| switch (g.rand.uintLessThan(u8, 3)) {
            0 => try g.comment(),
            1 => try g.pi(),
            else => try g.add(g.pick(&.{ "\n", " ", "\r\n" })),
        };
    }

    /// A document that is usually well-formed: random text can still make `--`, `]]>`, `<` or a
    /// repeated attribute.
    fn document(g: *Generator) ![]const u8 {
        g.out.clearRetainingCapacity();
        if (g.rand.boolean()) try g.add(g.pick(&.{ "<?xml version='1.0'?>", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\r\n", "\u{FEFF}<?xml version='1.5' standalone='yes'?>" }));
        try g.misc();
        if (g.rand.uintLessThan(u8, 4) == 0) try g.add(g.pick(&.{ "<!DOCTYPE a>", "<!DOCTYPE a SYSTEM 'a.dtd'>", "<!DOCTYPE a PUBLIC \"-//x\" \"y\" [ <!ENTITY e \"]>\"> <!-- ]> --> <?p ]>?> ]>", "<!DOCTYPE a [\r\n]\r\n>" }));
        try g.misc();
        try g.element(0, true);
        try g.misc();
        return g.out.items;
    }
};

test "generated documents parse, and write back as the same tree" {
    var prng = Rand.DefaultPrng.init(0x67656e);
    var g: Generator = .{ .rand = prng.random() };
    defer g.out.deinit(testing.allocator);
    const rounds = 3000;
    var accepted: u32 = 0;
    var without_namespaces: u32 = 0;
    for (0..rounds) |_| {
        const src = try g.document();
        if (try checkRoundTrip(src, true)) accepted += 1;
        if (try checkRoundTrip(src, false)) without_namespaces += 1;
    }
    // 2389 when this was written.
    try testing.expect(accepted > rounds * 7 / 10);
    try testing.expect(without_namespaces >= accepted);
}

/// Hand-written starting points for the damage, covering what the generator does not.
const seeds = [_][]const u8{
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- c --><root xmlns:x=\"urn:x\" a=\"1\"><x:item id='1'>one &amp; two</x:item>\n<![CDATA[raw]]><?pi data?><empty/>é日本</root>",
    "<!DOCTYPE r PUBLIC 'p' 's' [ <!ENTITY e \"v\"> <!-- ] > --> <?p ]?> %e; ]><r xmlns='u' xml:space='preserve'>&#x10FFFF;&#65;</r>",
    "<?xml version='1.0' encoding='ISO-8859-1' standalone='yes'?><a b='\xE9'>caf\xE9\r\n</a>",
    "<?xml version='1.0' encoding='US-ASCII'?><a><b/><b></b></a>",
    "\xFF\xFE<\x00a\x00 \x00b\x00=\x00'\x00\x3D\xD8\x00\xDE'\x00>\x00\xE9\x00<\x00/\x00a\x00>\x00",
    "\xFE\xFF\x00<\x00a\x00>\x00<\x00!\x00-\x00-\x00-\x00-\x00>\x00<\x00/\x00a\x00>",
};

fn damage(rand: Rand, buf: []u8, len: usize) usize {
    var n = len;
    // Mostly a single change: a document with several rarely gets far.
    const changes: usize = if (rand.uintLessThan(u8, 4) == 0) 2 + rand.uintLessThan(usize, 3) else 1;
    for (0..changes) |_| {
        if (n == 0) break;
        const at = rand.uintLessThan(usize, n);
        // 0 to 3 four times as often as cutting short.
        switch (if (rand.uintLessThan(u8, 17) == 16) 4 else rand.uintLessThan(u8, 4)) {
            0 => buf[at] = rand.int(u8),
            1 => buf[at] = "<>/=\"'&;!?-[]#: \r\n\x00\xC3\xFF"[rand.uintLessThan(usize, 21)],
            2 => { // delete a stretch
                const k = @min(1 + rand.uintLessThan(usize, 8), n - at);
                @memmove(buf[at .. n - k], buf[at + k .. n]);
                n -= k;
            },
            3 => { // repeat a stretch
                const k = @min(1 + rand.uintLessThan(usize, 8), @min(n - at, buf.len - n));
                @memmove(buf[at + k .. n + k], buf[at..n]);
                n += k;
            },
            else => n = at, // cut short
        }
    }
    return n;
}

test "damaged documents never crash the parser, and what survives writes back" {
    var prng = Rand.DefaultPrng.init(0x64616d);
    const rand = prng.random();
    var g: Generator = .{ .rand = rand };
    defer g.out.deinit(testing.allocator);
    var buf: [8192]u8 = undefined;
    const rounds = 6000;
    var reached: u32 = 0;
    var survived: u32 = 0;
    for (0..rounds) |i| {
        const original = if (i % 2 == 0) seeds[(i / 2) % seeds.len] else try g.document();
        const len = @min(original.len, buf.len - 64);
        @memcpy(buf[0..len], original[0..len]);
        const src = buf[0..damage(rand, &buf, len)];
        const result = read(src, .{});
        if (result.starts > 0) reached += 1;
        if (try checkRoundTrip(src, true)) survived += 1;
        _ = try checkRoundTrip(src, false);
        // Tight limits must fail cleanly too.
        _ = read(src, .{ .max_depth = 2, .max_name_bytes = 3, .max_attributes = 1, .max_token_bytes = 4, .max_tag_bytes = 8, .max_namespace_bindings = 1, .max_namespace_bytes = 6, .max_input_bytes = 40 });
    }
    // 2053 and 555 when this was written.
    try testing.expect(reached > rounds / 4);
    try testing.expect(survived > rounds / 15);
}

test "the seeds themselves are well-formed" {
    for (seeds) |s| {
        errdefer std.debug.print("seed: \"{f}\"\n", .{std.zig.fmtString(s)});
        try testing.expect(try checkRoundTrip(s, true));
    }
}

test "random bytes after the start of a tag never crash the parser" {
    var prng = Rand.DefaultPrng.init(0x584d4c);
    const rand = prng.random();
    const alphabet = "<>/=\"'&;!?-[]#xa b:\n\t\r\x00\xC3\xA9\xFF";
    const openings = [_][]const u8{ "", "<", "<a", "<a ", "<a b='", "<a>", "<a><!", "<a><![CDATA[", "<a><!--", "<a><?", "<a>&", "<!DOCTYPE ", "<?xml " };
    var buf: [128]u8 = undefined;
    for (0..8000) |i| {
        const opening = openings[i % openings.len];
        @memcpy(buf[0..opening.len], opening);
        const n = opening.len + rand.uintLessThan(usize, buf.len - opening.len);
        for (buf[opening.len..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        _ = read(buf[0..n], .{});
        _ = try checkRoundTrip(buf[0..n], true);
    }
}
