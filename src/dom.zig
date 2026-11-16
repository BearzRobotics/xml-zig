//! A small in-memory tree built from the streaming reader, for documents that
//! fit in memory (office-document parts, config files). The `Document` owns an
//! arena holding everything; `deinit` frees it at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const reader = @import("reader.zig");

pub const Name = reader.Name;

pub const Attribute = struct {
    name: Name,
    value: []const u8,
};

const PiData = struct { target: []const u8, data: []const u8 };

pub const Node = union(enum) {
    element: *Element,
    /// Character data (adjacent runs are merged).
    text: []const u8,
    /// A CDATA section, kept apart from text so it is written back as one.
    cdata: []const u8,
    comment: []const u8,
    processing_instruction: PiData,
};

/// Something outside the root element: a comment, processing instruction or DOCTYPE.
pub const Misc = union(enum) {
    comment: []const u8,
    processing_instruction: PiData,
    /// The text between `<!DOCTYPE` and `>`, as read.
    doctype: []const u8,
};

pub const Declaration = struct {
    version: []const u8,
    encoding: ?[]const u8,
    standalone: ?bool,
};

pub const Element = struct {
    name: Name,
    attributes: []const Attribute = &.{},
    children: []const Node = &.{},
    /// Written `<a/>` in the source (kept so it is written back the same way).
    self_closing: bool = false,

    /// The value of the attribute with this qualified name (`xml:lang`), or null.
    pub fn attr(self: *const Element, qualified: []const u8) ?[]const u8 {
        for (self.attributes) |a| if (std.mem.eql(u8, a.name.qualified, qualified)) return a.value;
        return null;
    }

    /// The value of the attribute `local` in namespace `ns` (use "" for none).
    pub fn attrNs(self: *const Element, ns: []const u8, local: []const u8) ?[]const u8 {
        for (self.attributes) |a| if (a.name.is(ns, local)) return a.value;
        return null;
    }

    /// The first child element with this qualified name.
    pub fn child(self: *const Element, qualified: []const u8) ?*Element {
        for (self.children) |c| switch (c) {
            .element => |e| if (std.mem.eql(u8, e.name.qualified, qualified)) return e,
            else => {},
        };
        return null;
    }

    /// The first child element `local` in namespace `ns`.
    pub fn childNs(self: *const Element, ns: []const u8, local: []const u8) ?*Element {
        for (self.children) |c| switch (c) {
            .element => |e| if (e.name.is(ns, local)) return e,
            else => {},
        };
        return null;
    }

    /// Iterates the child elements (skipping text and comments).
    pub fn elements(self: *const Element) ElementIterator {
        return .{ .nodes = self.children };
    }

    /// All text below this element, in document order, appended to `out`.
    pub fn appendText(self: *const Element, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        for (self.children) |c| switch (c) {
            .text, .cdata => |t| try out.appendSlice(gpa, t),
            .element => |e| try e.appendText(gpa, out),
            else => {},
        };
    }

    /// The concatenated text below this element; the caller frees it.
    pub fn textContent(self: *const Element, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try self.appendText(gpa, &out);
        return out.toOwnedSlice(gpa);
    }
};

pub const ElementIterator = struct {
    nodes: []const Node,
    i: usize = 0,

    pub fn next(self: *ElementIterator) ?*Element {
        while (self.i < self.nodes.len) {
            const n = self.nodes[self.i];
            self.i += 1;
            switch (n) {
                .element => |e| return e,
                else => {},
            }
        }
        return null;
    }
};

pub const Options = struct {
    reader: reader.Options = .{},
    /// Keep comments and processing instructions, inside the root and around it, so that
    /// `Document.write` writes them back. Set to false to drop them.
    keep_comments: bool = true,
    /// Drop text nodes that are only whitespace.
    trim_blank_text: bool = false,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Element,
    /// The XML declaration, if the document had one.
    declaration: ?Declaration = null,
    /// Comments, processing instructions and the DOCTYPE before the root element.
    prolog: []const Misc = &.{},
    /// Comments and processing instructions after the root element.
    epilog: []const Misc = &.{},
    /// The declared `standalone` value, if any.
    standalone: ?bool = null,

    pub const ParseError = reader.Error;

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parses `source` (UTF-8). `source` is not retained.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options, diag: ?*reader.Diagnostic) ParseError!Document {
        var r: Io.Reader = .fixed(source);
        return parseReader(gpa, &r, options, diag);
    }

    /// Parses XML read incrementally from `src`.
    pub fn parseReader(gpa: Allocator, src: *Io.Reader, options: Options, diag: ?*reader.Diagnostic) ParseError!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var rd = reader.Reader.init(gpa, src, options.reader, diag);
        defer rd.deinit();

        // One open element at a time: a stack of (element, children so far).
        const Frame = struct { el: *Element, kids: std.ArrayList(Node) };
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |*f| f.kids.deinit(gpa);
            stack.deinit(gpa);
        }
        var root: ?*Element = null;
        var standalone: ?bool = null;
        var declaration: ?Declaration = null;
        var before: std.ArrayList(Misc) = .empty;
        defer before.deinit(gpa);
        var after: std.ArrayList(Misc) = .empty;
        defer after.deinit(gpa);

        while (true) {
            switch (try rd.next()) {
                .xml_decl => |d| {
                    standalone = d.standalone;
                    declaration = .{ .version = try a.dupe(u8, d.version), .encoding = if (d.encoding) |e| try a.dupe(u8, e) else null, .standalone = d.standalone };
                },
                .doctype => |t| if (options.keep_comments) try before.append(gpa, .{ .doctype = try a.dupe(u8, t) }),
                .start_element => |s| {
                    const el = try a.create(Element);
                    const attrs = try a.alloc(Attribute, s.attributes.len);
                    for (s.attributes, attrs) |src_attr, *dst| dst.* = .{ .name = try dupName(a, src_attr.name), .value = try a.dupe(u8, src_attr.value) };
                    el.* = .{ .name = try dupName(a, s.name), .attributes = attrs, .self_closing = s.empty };
                    try stack.append(gpa, .{ .el = el, .kids = .empty });
                },
                .end_element => {
                    var f = stack.pop().?;
                    defer f.kids.deinit(gpa);
                    f.el.children = try a.dupe(Node, f.kids.items);
                    if (stack.items.len == 0) {
                        root = f.el;
                    } else {
                        try stack.items[stack.items.len - 1].kids.append(gpa, .{ .element = f.el });
                    }
                },
                .text => |t| {
                    if (stack.items.len == 0) continue;
                    if (options.trim_blank_text and std.mem.trim(u8, t, " \t\n\r").len == 0) continue;
                    try addText(a, gpa, &stack.items[stack.items.len - 1].kids, t);
                },
                .cdata => |t| {
                    if (stack.items.len == 0) continue;
                    try stack.items[stack.items.len - 1].kids.append(gpa, .{ .cdata = try a.dupe(u8, t) });
                },
                .comment => |t| if (options.keep_comments) {
                    if (stack.items.len > 0) {
                        try stack.items[stack.items.len - 1].kids.append(gpa, .{ .comment = try a.dupe(u8, t) });
                    } else try (if (root == null) &before else &after).append(gpa, .{ .comment = try a.dupe(u8, t) });
                },
                .processing_instruction => |p| if (options.keep_comments) {
                    const pi: PiData = .{ .target = try a.dupe(u8, p.target), .data = try a.dupe(u8, p.data) };
                    if (stack.items.len > 0) {
                        try stack.items[stack.items.len - 1].kids.append(gpa, .{ .processing_instruction = pi });
                    } else try (if (root == null) &before else &after).append(gpa, .{ .processing_instruction = pi });
                },
                .end_of_document => break,
            }
        }
        return .{
            .arena = arena,
            .root = root.?,
            .declaration = declaration,
            .prolog = try a.dupe(Misc, before.items),
            .epilog = try a.dupe(Misc, after.items),
            .standalone = standalone,
        };
    }

    pub const WriteOptions = struct {
        /// Spaces per level for elements that hold no text; 0 keeps the whitespace the
        /// document had (text nodes are written as they are).
        indent: u8 = 0,
        /// Write the XML declaration if the document had one.
        declaration: bool = true,
    };

    /// Writes the document, with its comments, processing instructions, CDATA sections and DOCTYPE.
    /// Quote style, entity spelling and whitespace inside tags are normalized; everything else
    /// round-trips: `write(parse(x))` parses back to the same tree.
    pub fn write(self: *const Document, gpa: Allocator, out: *Io.Writer, options: WriteOptions) writer_mod.Error!void {
        var w = writer_mod.Writer.init(gpa, out, .{ .indent = options.indent });
        defer w.deinit();
        if (options.declaration) if (self.declaration) |d| try w.declarationWith(d.version, d.encoding, d.standalone);
        for (self.prolog) |m| try writeMisc(&w, m);
        try writeElement(&w, self.root);
        if (options.indent == 0) try w.lineBreak(); // with an indent the writer has already ended the line
        for (self.epilog) |m| try writeMisc(&w, m);
        try w.finish();
    }
};

fn writeMisc(w: *writer_mod.Writer, m: Misc) writer_mod.Error!void {
    switch (m) {
        .comment => |t| try w.comment(t),
        .processing_instruction => |p| try w.processingInstruction(p.target, p.data),
        .doctype => |t| try w.doctype(t),
    }
    try w.lineBreak();
}

fn writeElement(w: *writer_mod.Writer, el: *const Element) writer_mod.Error!void {
    try w.start(el.name.qualified);
    for (el.attributes) |a| try w.attribute(a.name.qualified, a.value);
    for (el.children) |c| switch (c) {
        .element => |e| try writeElement(w, e),
        .text => |t| try w.text(t),
        .cdata => |t| try w.cdata(t),
        .comment => |t| try w.comment(t),
        .processing_instruction => |p| try w.processingInstruction(p.target, p.data),
    };
    if (el.children.len == 0 and !el.self_closing) try w.endExpanded() else try w.end();
}

const writer_mod = @import("writer.zig");

fn dupName(a: Allocator, n: Name) Allocator.Error!Name {
    const q = try a.dupe(u8, n.qualified);
    const colon = std.mem.indexOfScalar(u8, q, ':');
    return .{
        .qualified = q,
        .prefix = if (colon) |c| q[0..c] else "",
        .local = if (colon) |c| q[c + 1 ..] else q,
        .uri = try a.dupe(u8, n.uri),
    };
}

/// Adds text to `kids`, merging with a text node right before it.
fn addText(a: Allocator, gpa: Allocator, kids: *std.ArrayList(Node), t: []const u8) Allocator.Error!void {
    if (kids.items.len > 0) if (kids.items[kids.items.len - 1] == .text) {
        const prev = kids.items[kids.items.len - 1].text;
        const joined = try a.alloc(u8, prev.len + t.len);
        @memcpy(joined[0..prev.len], prev);
        @memcpy(joined[prev.len..], t);
        kids.items[kids.items.len - 1] = .{ .text = joined };
        return;
    };
    try kids.append(gpa, .{ .text = try a.dupe(u8, t) });
}

const testing = std.testing;

test "a tree with namespaces, attributes and text" {
    var doc = try Document.parse(testing.allocator,
        \\<?xml version="1.0"?>
        \\<w:document xmlns:w="urn:w" xmlns="urn:d">
        \\  <w:body><w:p w:id="1">Hello <w:r>wor</w:r>ld</w:p><x/></w:body>
        \\</w:document>
    , .{ .trim_blank_text = true }, null);
    defer doc.deinit();
    try testing.expect(doc.root.name.is("urn:w", "document"));
    const body = doc.root.childNs("urn:w", "body").?;
    const p = body.childNs("urn:w", "p").?;
    try testing.expectEqualStrings("1", p.attrNs("urn:w", "id").?);
    try testing.expectEqualStrings("1", p.attr("w:id").?);
    const text = try p.textContent(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Hello world", text);
    // The default namespace applies to the unprefixed element.
    try testing.expect(body.childNs("urn:d", "x") != null);
    var it = body.elements();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 2), n);
}

test "comments and CDATA are kept by default and can be dropped" {
    var doc = try Document.parse(testing.allocator, "<!--before--><a>x<!--c-->y<![CDATA[z]]></a><!--after-->", .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 4), doc.root.children.len); // x, comment, y, cdata
    try testing.expectEqualStrings("c", doc.root.children[1].comment);
    try testing.expectEqualStrings("z", doc.root.children[3].cdata);
    try testing.expectEqualStrings("before", doc.prolog[0].comment);
    try testing.expectEqualStrings("after", doc.epilog[0].comment);
    const text = try doc.root.textContent(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("xyz", text);

    var dropped = try Document.parse(testing.allocator, "<!--b--><a>x<!--c-->y</a>", .{ .keep_comments = false }, null);
    defer dropped.deinit();
    try testing.expectEqual(@as(usize, 1), dropped.root.children.len); // x and y merge
    try testing.expectEqualStrings("xy", dropped.root.children[0].text);
    try testing.expectEqual(@as(usize, 0), dropped.prolog.len);
}

fn roundTrip(src: []const u8, options: Document.WriteOptions) ![]u8 {
    var doc = try Document.parse(testing.allocator, src, .{}, null);
    defer doc.deinit();
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try doc.write(testing.allocator, &aw.writer, options);
    return aw.toOwnedSlice();
}

test "write keeps comments, processing instructions, CDATA, DOCTYPE and the declaration" {
    const src =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
        "<!-- top -->\n" ++
        "<?render fast?>\n" ++
        "<!DOCTYPE doc [ <!ENTITY e \"v\"> ]>\n" ++
        "<doc a=\"1\" b=\"x &amp; y\"><!-- inside --><item/><empty></empty>text &lt;tag&gt;<![CDATA[raw <x>]]><?pi data?></doc>\n" ++
        "<!-- end -->\n";
    const out = try roundTrip(src, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out); // already in the writer's own style, so identical
}

test "write normalizes only what the tree does not record" {
    const src = "<?xml version='1.0'?><a  x = 'it\"s' ><b></b><c/>&#65;&amp;</a>";
    const out = try roundTrip(src, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<?xml version=\"1.0\"?>\n<a x=\"it&quot;s\"><b></b><c/>A&amp;</a>\n", out);
    // And the result parses back to the same tree.
    const again = try roundTrip(out, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "write can leave the declaration out and indent" {
    const out = try roundTrip("<?xml version=\"1.0\"?><a><!--c--><b><c/></b></a>", .{ .declaration = false, .indent = 2 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<a>\n  <!--c-->\n  <b>\n    <c/>\n  </b>\n</a>\n", out);
}

test "no leaks when allocation fails part-way" {
    const src = "<?xml version=\"1.0\"?><a x='1'><b>text</b><c y='2'/><!--k--><d>more &amp; more</d></a>";
    var fail_index: usize = 0;
    while (fail_index < 200) : (fail_index += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (Document.parse(fa.allocator(), src, .{}, null)) |d| {
            var doc = d;
            doc.deinit();
            break;
        } else |e| try testing.expect(e == error.OutOfMemory);
    }
    try testing.expect(fail_index > 3);
}
