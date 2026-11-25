//! Writes XML to any `std.Io.Writer`, escaping text and attribute values and
//! tracking open elements so `end` always matches `start`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const chars = @import("chars.zig");
const doctype_syntax = @import("doctype.zig");

pub const Error = error{
    /// A name that is not a valid XML name.
    InvalidName,
    /// Text with a character XML cannot carry (a control character, U+FFFE, bad UTF-8).
    InvalidCharacter,
    /// `end` with nothing open, an attribute outside a start tag, or the like.
    InvalidState,
    /// Content that cannot be written so that it reads back: `--` in a comment, `]]>` in CDATA,
    /// `?>` in a processing instruction (or whitespace at the start of its data), a carriage
    /// return where it cannot be escaped, or a malformed DOCTYPE.
    InvalidContent,
    /// The same attribute twice in one start tag, by name or by namespace and local name.
    DuplicateAttribute,
    /// A prefix with no `xmlns:` declaration in scope.
    UnboundPrefix,
    WriteFailed,
    OutOfMemory,
};

pub const Options = struct {
    /// Spaces per level; 0 writes everything on one line. Indenting is only
    /// applied around elements that hold no text, so text content is never altered.
    indent: u8 = 0,
    /// Hold names to Namespaces in XML, so that a reader with the same setting accepts the output:
    /// qualified names, legal `xmlns` declarations, and a declaration in scope for every prefix.
    /// Set to false to write without namespace processing, or to write a fragment that relies on
    /// declarations made elsewhere.
    namespaces: bool = true,
};

pub const Writer = struct {
    gpa: Allocator,
    out: *Io.Writer,
    options: Options,
    /// Names of the open elements, back to back, with their lengths.
    names: std.ArrayList(u8) = .empty,
    lens: std.ArrayList(u32) = .empty,
    /// Whether each open element has had element children and no text (so it may be indented).
    only_elements: std.ArrayList(bool) = .empty,
    /// The names of the attributes in the open start tag, back to back, with their lengths.
    attr_names: std.ArrayList(u8) = .empty,
    attr_lens: std.ArrayList(u32) = .empty,
    /// Namespace declarations in scope (prefix and URI back to back), and where each open
    /// element's begin.
    ns_bytes: std.ArrayList(u8) = .empty,
    ns_binds: std.ArrayList(Binding) = .empty,
    ns_marks: std.ArrayList(NsMark) = .empty,
    /// A start tag is still open (`<a` written, `>` not yet).
    in_tag: bool = false,
    wrote_root: bool = false,
    wrote_doctype: bool = false,
    /// Anything at all has been written: too late for an XML declaration.
    wrote_any: bool = false,

    const Binding = struct { at: u32, prefix_len: u32, uri_len: u32 };
    const NsMark = struct { binds: usize, bytes: usize };

    /// A reader turns a literal CR into a line feed, and these places have no way to escape it.
    fn hasCr(s: []const u8) bool {
        return std.mem.indexOfScalar(u8, s, '\r') != null;
    }

    pub fn init(gpa: Allocator, out: *Io.Writer, options: Options) Writer {
        return .{ .gpa = gpa, .out = out, .options = options };
    }

    pub fn deinit(self: *Writer) void {
        self.names.deinit(self.gpa);
        self.lens.deinit(self.gpa);
        self.only_elements.deinit(self.gpa);
        self.attr_names.deinit(self.gpa);
        self.attr_lens.deinit(self.gpa);
        self.ns_bytes.deinit(self.gpa);
        self.ns_binds.deinit(self.gpa);
        self.ns_marks.deinit(self.gpa);
        self.* = undefined;
    }

    fn werr(e: Io.Writer.Error) Error {
        return switch (e) {
            error.WriteFailed => error.WriteFailed,
        };
    }

    /// `<?xml version="1.0" encoding="UTF-8"?>` and a newline.
    pub fn declaration(self: *Writer) Error!void {
        return self.declarationWith("1.0", "UTF-8", null);
    }

    /// An XML declaration with the given pseudo-attributes, and a newline. The writer always
    /// writes UTF-8, so any `encoding` given is written as `UTF-8`; null leaves it out. (This is
    /// what lets a document read as UTF-16 or ISO-8859-1 be written back.)
    pub fn declarationWith(self: *Writer, version: []const u8, encoding: ?[]const u8, standalone: ?bool) Error!void {
        if (self.wrote_any) return error.InvalidState;
        if (std.mem.eql(u8, version, "1.1")) return error.InvalidContent; // not XML 1.0, and not readable here
        if (version.len < 3 or !std.mem.startsWith(u8, version, "1.")) return error.InvalidContent;
        for (version[2..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidContent;
        self.wrote_any = true;
        self.out.writeAll("<?xml version=\"") catch |e| return werr(e);
        self.out.writeAll(version) catch |e| return werr(e);
        self.out.writeByte('"') catch |e| return werr(e);
        // The text is always written as UTF-8 (US-ASCII is a subset); a declaration that names
        // another encoding is replaced by the truth.
        if (encoding != null) self.out.writeAll(" encoding=\"UTF-8\"") catch |e| return werr(e);
        if (standalone) |s| self.out.writeAll(if (s) " standalone=\"yes\"" else " standalone=\"no\"") catch |e| return werr(e);
        self.out.writeAll("?>\n") catch |e| return werr(e);
    }

    /// A processing instruction (`<?target data?>`).
    pub fn processingInstruction(self: *Writer, target: []const u8, data: []const u8) Error!void {
        if (!chars.isName(target) or std.ascii.eqlIgnoreCase(target, "xml")) return error.InvalidName;
        if (self.options.namespaces and std.mem.indexOfScalar(u8, target, ':') != null) return error.InvalidName;
        if (!chars.validText(data)) return error.InvalidCharacter;
        if (std.mem.indexOf(u8, data, "?>") != null) return error.InvalidContent;
        // Leading whitespace would be read as the separator after the target.
        if (data.len > 0 and chars.isSpace(data[0])) return error.InvalidContent;
        if (hasCr(data)) return error.InvalidContent;
        try self.closeTag();
        try self.indentMarkup();
        self.wrote_any = true;
        self.out.writeAll("<?") catch |e| return werr(e);
        self.out.writeAll(target) catch |e| return werr(e);
        if (data.len > 0) {
            self.out.writeByte(' ') catch |e| return werr(e);
            self.out.writeAll(data) catch |e| return werr(e);
        }
        self.out.writeAll("?>") catch |e| return werr(e);
    }

    /// Starts a comment or processing instruction on its own line when it sits among elements only.
    fn indentMarkup(self: *Writer) Error!void {
        const depth = self.lens.items.len;
        if (depth > 0 and self.only_elements.items[depth - 1]) try self.newline(depth);
    }

    /// A DOCTYPE, written as read (`raw` is the text between `<!DOCTYPE` and `>`). Only before the root.
    pub fn doctype(self: *Writer, raw: []const u8) Error!void {
        if (self.wrote_root or self.wrote_doctype) return error.InvalidState;
        if (!chars.validText(raw)) return error.InvalidCharacter;
        // As strict as the reader: anything else could end the declaration early and add markup.
        if (hasCr(raw) or doctype_syntax.check(raw) != null) return error.InvalidContent;
        self.wrote_doctype = true;
        self.wrote_any = true;
        self.out.writeAll("<!DOCTYPE ") catch |e| return werr(e);
        self.out.writeAll(raw) catch |e| return werr(e);
        self.out.writeAll(">") catch |e| return werr(e);
    }

    /// A line break between items outside the root element (after the declaration, comments and so on).
    pub fn lineBreak(self: *Writer) Error!void {
        if (self.lens.items.len > 0) return error.InvalidState;
        self.wrote_any = true;
        self.out.writeByte('\n') catch |e| return werr(e);
    }

    fn lookup(self: *const Writer, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return chars.xml_namespace;
        var i = self.ns_binds.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.ns_binds.items[i];
            if (std.mem.eql(u8, self.ns_bytes.items[b.at..][0..b.prefix_len], prefix)) return self.ns_bytes.items[b.at + b.prefix_len ..][0..b.uri_len];
        }
        return null;
    }

    const Split = struct { prefix: []const u8, local: []const u8 };

    fn split(name: []const u8) Split {
        const c = std.mem.indexOfScalar(u8, name, ':') orelse return .{ .prefix = "", .local = name };
        return .{ .prefix = name[0..c], .local = name[c + 1 ..] };
    }

    /// What can only be judged once a start tag has all its attributes: a declaration may follow
    /// the name that uses it. Nothing is changed on failure, so the missing one can still be added.
    fn checkTag(self: *const Writer) Error!void {
        if (!self.in_tag or !self.options.namespaces) return;
        const element = split(self.names.items[self.names.items.len - self.lens.items[self.lens.items.len - 1] ..]);
        if (element.prefix.len > 0 and self.lookup(element.prefix) == null) return error.UnboundPrefix;
        var from: usize = 0;
        for (self.attr_lens.items, 0..) |len, i| {
            const a = split(self.attr_names.items[from..][0..len]);
            from += len;
            if (a.prefix.len == 0 or std.mem.eql(u8, a.prefix, "xmlns")) continue;
            const uri = self.lookup(a.prefix) orelse return error.UnboundPrefix;
            var before: usize = 0;
            for (self.attr_lens.items[0..i]) |other_len| {
                const other = split(self.attr_names.items[before..][0..other_len]);
                before += other_len;
                if (other.prefix.len == 0 or std.mem.eql(u8, other.prefix, "xmlns")) continue;
                if (std.mem.eql(u8, other.local, a.local) and std.mem.eql(u8, self.lookup(other.prefix).?, uri)) return error.DuplicateAttribute;
            }
        }
    }

    fn closeTag(self: *Writer) Error!void {
        if (self.in_tag) {
            try self.checkTag();
            self.out.writeAll(">") catch |e| return werr(e);
            self.in_tag = false;
        }
    }

    fn newline(self: *Writer, levels: usize) Error!void {
        if (self.options.indent == 0) return;
        self.out.writeByte('\n') catch |e| return werr(e);
        var n = levels * self.options.indent;
        while (n > 0) : (n -= 1) self.out.writeByte(' ') catch |e| return werr(e);
    }

    pub fn start(self: *Writer, name: []const u8) Error!void {
        if (!chars.isName(name)) return error.InvalidName;
        if (self.options.namespaces and (!chars.isQName(name) or std.mem.startsWith(u8, name, "xmlns:"))) return error.InvalidName;
        if (self.lens.items.len == 0 and self.wrote_root) return error.InvalidState;
        // Make room first: once `<name` is written the stacks must record it, whatever fails.
        try self.names.ensureUnusedCapacity(self.gpa, name.len);
        try self.lens.ensureUnusedCapacity(self.gpa, 1);
        try self.only_elements.ensureUnusedCapacity(self.gpa, 1);
        try self.ns_marks.ensureUnusedCapacity(self.gpa, 1);
        try self.closeTag();
        const depth = self.lens.items.len;
        if (depth > 0 and self.only_elements.items[depth - 1]) try self.newline(depth);
        self.out.writeByte('<') catch |e| return werr(e);
        self.out.writeAll(name) catch |e| return werr(e);
        self.names.appendSliceAssumeCapacity(name);
        self.lens.appendAssumeCapacity(@intCast(name.len));
        self.only_elements.appendAssumeCapacity(true);
        self.ns_marks.appendAssumeCapacity(.{ .binds = self.ns_binds.items.len, .bytes = self.ns_bytes.items.len });
        self.in_tag = true;
        self.wrote_any = true;
        self.attr_names.clearRetainingCapacity();
        self.attr_lens.clearRetainingCapacity();
        self.wrote_root = true;
    }

    pub fn attribute(self: *Writer, name: []const u8, value: []const u8) Error!void {
        if (!self.in_tag) return error.InvalidState;
        if (!chars.isName(name)) return error.InvalidName;
        if (!chars.validText(value)) return error.InvalidCharacter;
        var from: usize = 0;
        for (self.attr_lens.items) |len| {
            if (std.mem.eql(u8, self.attr_names.items[from..][0..len], name)) return error.DuplicateAttribute;
            from += len;
        }
        var declares: ?[]const u8 = null; // the prefix, if this is a namespace declaration
        if (self.options.namespaces) {
            if (!chars.isQName(name)) return error.InvalidName;
            const parts = split(name);
            const is_default = std.mem.eql(u8, name, "xmlns");
            if (is_default or std.mem.eql(u8, parts.prefix, "xmlns")) {
                const prefix = if (is_default) "" else parts.local;
                if (chars.bindingFault(is_default, prefix, value)) |fault| return if (fault.bad_name) error.InvalidName else error.InvalidContent;
                try self.ns_bytes.ensureUnusedCapacity(self.gpa, prefix.len + value.len);
                try self.ns_binds.ensureUnusedCapacity(self.gpa, 1);
                declares = prefix;
            }
        }
        try self.attr_names.ensureUnusedCapacity(self.gpa, name.len);
        try self.attr_lens.ensureUnusedCapacity(self.gpa, 1);
        self.attr_names.appendSliceAssumeCapacity(name);
        self.attr_lens.appendAssumeCapacity(@intCast(name.len));
        if (declares) |prefix| {
            self.ns_binds.appendAssumeCapacity(.{ .at = @intCast(self.ns_bytes.items.len), .prefix_len = @intCast(prefix.len), .uri_len = @intCast(value.len) });
            self.ns_bytes.appendSliceAssumeCapacity(prefix);
            self.ns_bytes.appendSliceAssumeCapacity(value);
        }
        self.out.writeByte(' ') catch |e| return werr(e);
        self.out.writeAll(name) catch |e| return werr(e);
        self.out.writeAll("=\"") catch |e| return werr(e);
        try self.escape(value, true);
        self.out.writeByte('"') catch |e| return werr(e);
    }

    fn escape(self: *Writer, s: []const u8, in_attribute: bool) Error!void {
        var from: usize = 0;
        for (s, 0..) |b, i| {
            const rep: ?[]const u8 = switch (b) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => if (in_attribute) "&quot;" else null,
                // Whitespace other than a space would be normalized away on reading.
                '\t' => if (in_attribute) "&#9;" else null,
                '\n' => if (in_attribute) "&#10;" else null,
                '\r' => if (in_attribute) "&#13;" else "&#13;",
                else => null,
            };
            if (rep) |r| {
                self.out.writeAll(s[from..i]) catch |e| return werr(e);
                self.out.writeAll(r) catch |e| return werr(e);
                from = i + 1;
            }
        }
        self.out.writeAll(s[from..]) catch |e| return werr(e);
    }

    pub fn text(self: *Writer, s: []const u8) Error!void {
        if (self.lens.items.len == 0) return error.InvalidState;
        if (!chars.validText(s)) return error.InvalidCharacter;
        try self.closeTag();
        self.only_elements.items[self.only_elements.items.len - 1] = false;
        try self.escape(s, false);
    }

    pub fn cdata(self: *Writer, s: []const u8) Error!void {
        if (self.lens.items.len == 0) return error.InvalidState;
        if (!chars.validText(s)) return error.InvalidCharacter;
        if (std.mem.indexOf(u8, s, "]]>") != null or hasCr(s)) return error.InvalidContent;
        try self.closeTag();
        self.only_elements.items[self.only_elements.items.len - 1] = false;
        self.out.writeAll("<![CDATA[") catch |e| return werr(e);
        self.out.writeAll(s) catch |e| return werr(e);
        self.out.writeAll("]]>") catch |e| return werr(e);
    }

    pub fn comment(self: *Writer, s: []const u8) Error!void {
        if (!chars.validText(s)) return error.InvalidCharacter;
        if (std.mem.indexOf(u8, s, "--") != null or std.mem.endsWith(u8, s, "-") or hasCr(s)) return error.InvalidContent;
        try self.closeTag();
        try self.indentMarkup();
        self.wrote_any = true;
        self.out.writeAll("<!--") catch |e| return werr(e);
        self.out.writeAll(s) catch |e| return werr(e);
        self.out.writeAll("-->") catch |e| return werr(e);
    }

    /// Ends the innermost open element; an element with no content is written as `<a/>`.
    pub fn end(self: *Writer) Error!void {
        return self.endWith(false);
    }

    /// Like `end`, but an element with no content is written `<a></a>`.
    pub fn endExpanded(self: *Writer) Error!void {
        return self.endWith(true);
    }

    fn endWith(self: *Writer, expand: bool) Error!void {
        if (self.lens.items.len == 0) return error.InvalidState;
        try self.checkTag(); // before anything is popped, so a failure changes nothing
        const len = self.lens.pop().?;
        const mark = self.ns_marks.pop().?;
        defer {
            self.ns_binds.items.len = mark.binds;
            self.ns_bytes.items.len = mark.bytes;
        }
        const only = self.only_elements.pop().?;
        const name = self.names.items[self.names.items.len - len ..];
        defer self.names.items.len -= len;
        if (self.in_tag and !expand) {
            self.out.writeAll("/>") catch |e| return werr(e);
            self.in_tag = false;
        } else {
            try self.closeTag();
            if (only) try self.newline(self.lens.items.len);
            self.out.writeAll("</") catch |e| return werr(e);
            self.out.writeAll(name) catch |e| return werr(e);
            self.out.writeAll(">") catch |e| return werr(e);
        }
        if (self.lens.items.len == 0 and self.options.indent > 0) self.out.writeByte('\n') catch |e| return werr(e);
    }

    /// Ends every open element. The document is complete when this returns.
    pub fn finish(self: *Writer) Error!void {
        while (self.lens.items.len > 0) try self.end();
        if (!self.wrote_root) return error.InvalidState;
    }
};

const testing = std.testing;

fn render(options: Options, comptime build: fn (*Writer) Error!void) ![]u8 {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    var w = Writer.init(testing.allocator, &aw.writer, options);
    defer w.deinit();
    try build(&w);
    try w.finish();
    return aw.toOwnedSlice();
}

test "escaping and empty elements" {
    const out = try render(.{}, struct {
        fn f(w: *Writer) Error!void {
            try w.declaration();
            try w.start("a");
            try w.attribute("t", "x\"<&>\ny");
            try w.start("b");
            try w.end();
            try w.text("1 < 2 & 3 > 2");
            try w.cdata("raw <x>");
            try w.comment(" note ");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a t=\"x&quot;&lt;&amp;&gt;&#10;y\"><b/>1 &lt; 2 &amp; 3 &gt; 2<![CDATA[raw <x>]]><!-- note --></a>", out);
}

test "indentation leaves text alone" {
    const out = try render(.{ .indent = 2 }, struct {
        fn f(w: *Writer) Error!void {
            try w.start("a");
            try w.start("b");
            try w.text("t");
            try w.end();
            try w.start("c");
            try w.start("d");
            try w.end();
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<a>\n  <b>t</b>\n  <c>\n    <d/>\n  </c>\n</a>\n", out);
}

fn writeNested(gpa: Allocator) !void {
    var out_buf: [16 * 1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var w = Writer.init(gpa, &out, .{ .indent = 1 });
    defer w.deinit();
    // Names long and deep enough that every one of the writer's lists has to grow more than once.
    const long: []const u8 = &@as([40]u8, @splat('n'));
    var failed: ?Error = null;
    for (0..40) |_| w.start(long) catch |e| {
        failed = e;
        break;
    };
    for ([_][]const u8{ "xmlns", "xmlns:p", "p:k" }) |name| w.attribute(name, long) catch |e| {
        failed = failed orelse e;
        break;
    };
    w.attribute("k", "v") catch |e| {
        failed = failed orelse e;
    };
    // Whatever failed, the writer is still consistent: closing it gives a complete document.
    if (w.lens.items.len > 0) {
        try w.finish();
        const doc_len = out.buffered().len;
        try testing.expect(std.mem.startsWith(u8, out.buffered()[0..doc_len], "<nnnn"));
        var src: Io.Reader = .fixed(out.buffered());
        var rd = @import("reader.zig").Reader.init(testing.allocator, &src, .{}, null);
        defer rd.deinit();
        while (try rd.next() != .end_of_document) {}
    }
    if (failed) |e| return e;
}

test "content that would not read back is refused" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = Writer.init(testing.allocator, &aw.writer, .{});
    defer w.deinit();
    try testing.expectError(error.InvalidContent, w.doctype("a [\r\n]"));
    for ([_][]const u8{ "", "a><evil/", "a><evil attr='1'/><!--", "a [ ] ><b", "a>", "a [", "a SYSTEM \"x" }) |raw|
        try testing.expectError(error.InvalidContent, w.doctype(raw));
    try testing.expectEqual(@as(usize, 0), aw.written().len);
    try w.start("a");
    const before = aw.written().len;
    for ([_][]const u8{ "a--b", "a-", "-", "a\rb" }) |s| try testing.expectError(error.InvalidContent, w.comment(s));
    for ([_][]const u8{ "x]]>y", "a\rb" }) |s| try testing.expectError(error.InvalidContent, w.cdata(s));
    for ([_][]const u8{ "a?>b", " x", "\tx", "\nx", "a\rb" }) |s| try testing.expectError(error.InvalidContent, w.processingInstruction("t", s));
    for ([_][]const u8{ "xml", "XmL", "1t", "a b", "" }) |t| try testing.expectError(error.InvalidName, w.processingInstruction(t, ""));
    for ([_][]const u8{ "\x00", "\x0B", "\xFF", "\xEF\xBF\xBF", "\xED\xA0\x80" }) |s| {
        try testing.expectError(error.InvalidCharacter, w.text(s));
        try testing.expectError(error.InvalidCharacter, w.cdata(s));
        try testing.expectError(error.InvalidCharacter, w.comment(s));
        try testing.expectError(error.InvalidCharacter, w.processingInstruction("t", s));
        try testing.expectError(error.InvalidCharacter, w.attribute("k", s));
    }
    // Nothing refused left a trace.
    try testing.expectEqual(before, aw.written().len);
    // A carriage return can be escaped in text and attribute values, and is.
    try w.attribute("k", "a\r\n\tb");
    try w.text("c\r\nd");
    try w.finish();
    try testing.expectEqualStrings("<a k=\"a&#13;&#10;&#9;b\">c&#13;\nd</a>", aw.written());
}

test "namespaces are held to what the reader accepts" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = Writer.init(testing.allocator, &aw.writer, .{});
    defer w.deinit();
    for ([_][]const u8{ "a:b:c", ":a", "a:", "a:1", "xmlns:a" }) |name| try testing.expectError(error.InvalidName, w.start(name));
    // A declaration may come after the name that needs it; until then the tag cannot be left,
    // and nothing is lost by trying.
    try w.start("p:a");
    try testing.expectError(error.UnboundPrefix, w.start("b"));
    try testing.expectError(error.UnboundPrefix, w.text("t"));
    try testing.expectError(error.UnboundPrefix, w.end());
    try testing.expectError(error.UnboundPrefix, w.finish());
    try testing.expectError(error.InvalidContent, w.attribute("xmlns:p", ""));
    try testing.expectError(error.InvalidName, w.attribute("xmlns:xmlns", "u"));
    try testing.expectError(error.InvalidContent, w.attribute("xmlns:xml", "u"));
    try testing.expectError(error.InvalidContent, w.attribute("xmlns:q", chars.xml_namespace));
    try testing.expectError(error.InvalidContent, w.attribute("xmlns", chars.xmlns_namespace));
    try testing.expectError(error.InvalidName, w.attribute("a:b:c", "u"));
    try w.attribute("xmlns:p", "urn:1");
    try w.attribute("xmlns:q", "urn:1");
    try w.attribute("xml:lang", "en");
    // The same expanded name through two prefixes.
    try w.start("b");
    try w.attribute("p:k", "1");
    try w.attribute("q:k", "2");
    try testing.expectError(error.DuplicateAttribute, w.end());
    try testing.expectError(error.InvalidName, w.processingInstruction("a:b", ""));

    // A declaration ends with its element.
    var other: Io.Writer.Allocating = .init(testing.allocator);
    defer other.deinit();
    var v = Writer.init(testing.allocator, &other.writer, .{});
    defer v.deinit();
    try v.start("r");
    try v.start("x:a");
    try v.attribute("xmlns:x", "urn:x");
    try v.start("x:b"); // inherited
    try v.end();
    try v.end();
    try v.start("x:c");
    try testing.expectError(error.UnboundPrefix, v.end());
}

test "namespace processing can be turned off" {
    const out = try render(.{ .namespaces = false }, struct {
        fn f(w: *Writer) Error!void {
            try w.start("w:p");
            try w.attribute("a:b:c", "1");
            try w.processingInstruction("x:y", "");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<w:p a:b:c=\"1\"><?x:y?></w:p>", out);
}

test "the prolog cannot be written out of order" {
    const Step = enum { declaration, comment, pi, doctype, line_break, root };
    const apply = struct {
        fn f(w: *Writer, s: Step) Error!void {
            switch (s) {
                .declaration => try w.declaration(),
                .comment => try w.comment("c"),
                .pi => try w.processingInstruction("p", ""),
                .doctype => try w.doctype("a"),
                .line_break => try w.lineBreak(),
                .root => try w.start("a"),
            }
        }
    }.f;
    const refused = [_][2]Step{
        .{ .declaration, .declaration }, .{ .comment, .declaration },    .{ .pi, .declaration },
        .{ .doctype, .declaration },     .{ .line_break, .declaration }, .{ .root, .declaration },
        .{ .doctype, .doctype },         .{ .root, .doctype },
    };
    for (refused) |pair| {
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var w = Writer.init(testing.allocator, &aw.writer, .{});
        defer w.deinit();
        try apply(&w, pair[0]);
        const before = aw.written().len;
        try testing.expectError(error.InvalidState, apply(&w, pair[1]));
        try testing.expectEqual(before, aw.written().len);
    }
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = Writer.init(testing.allocator, &aw.writer, .{});
    defer w.deinit();
    for ([_][]const u8{ "1.1", "2.0", "1.", "1.x", "" }) |version|
        try testing.expectError(error.InvalidContent, w.declarationWith(version, null, null));
    try w.declarationWith("1.7", "ISO-8859-1", false);
    try testing.expectEqualStrings("<?xml version=\"1.7\" encoding=\"UTF-8\" standalone=\"no\"?>\n", aw.written());
    for ([_]Step{ .comment, .line_break, .doctype, .pi, .root }) |s| try apply(&w, s);
}

test "the writer survives any failed allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, writeNested, .{});
}

test "misuse is an error, not bad output" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = Writer.init(testing.allocator, &aw.writer, .{});
    defer w.deinit();
    try testing.expectError(error.InvalidState, w.end());
    try testing.expectError(error.InvalidState, w.text("x"));
    try testing.expectError(error.InvalidName, w.start("1bad"));
    try w.start("a");
    try w.attribute("once", "1");
    try w.attribute("onc", "2");
    try testing.expectError(error.DuplicateAttribute, w.attribute("once", "3"));
    try testing.expectError(error.InvalidName, w.attribute("a b", "x"));
    try testing.expectError(error.InvalidCharacter, w.attribute("k", "a\x01"));
    try testing.expectError(error.InvalidContent, w.comment("a--b"));
    try testing.expectError(error.InvalidContent, w.cdata("x]]>y"));
    // A new tag starts with no attributes.
    try w.start("b");
    try w.attribute("once", "1");
    try w.end();
    try w.end();
    try testing.expectError(error.InvalidState, w.start("second_root"));
    try testing.expectEqualStrings("<a once=\"1\" onc=\"2\"><b once=\"1\"/></a>", aw.written());
}
