//! Writes XML to any `std.Io.Writer`, escaping text and attribute values and
//! tracking open elements so `end` always matches `start`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const chars = @import("chars.zig");

pub const Error = error{
    /// A name that is not a valid XML name.
    InvalidName,
    /// Text with a character XML cannot carry (a control character, U+FFFE, bad UTF-8).
    InvalidCharacter,
    /// `end` with nothing open, an attribute outside a start tag, or the like.
    InvalidState,
    /// A comment containing `--`, or a CDATA section containing `]]>`.
    InvalidContent,
    WriteFailed,
    OutOfMemory,
};

pub const Options = struct {
    /// Spaces per level; 0 writes everything on one line. Indenting is only
    /// applied around elements that hold no text, so text content is never altered.
    indent: u8 = 0,
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
    /// A start tag is still open (`<a` written, `>` not yet).
    in_tag: bool = false,
    wrote_root: bool = false,

    pub fn init(gpa: Allocator, out: *Io.Writer, options: Options) Writer {
        return .{ .gpa = gpa, .out = out, .options = options };
    }

    pub fn deinit(self: *Writer) void {
        self.names.deinit(self.gpa);
        self.lens.deinit(self.gpa);
        self.only_elements.deinit(self.gpa);
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

    /// An XML declaration with the given pseudo-attributes, and a newline. Note the writer always
    /// writes UTF-8: an `encoding` other than UTF-8 would be a lie, so it is refused.
    pub fn declarationWith(self: *Writer, version: []const u8, encoding: ?[]const u8, standalone: ?bool) Error!void {
        if (self.wrote_root or self.lens.items.len > 0) return error.InvalidState;
        if (version.len < 3 or !std.mem.startsWith(u8, version, "1.")) return error.InvalidContent;
        for (version[2..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidContent;
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
        if (!chars.validText(data)) return error.InvalidCharacter;
        if (std.mem.indexOf(u8, data, "?>") != null) return error.InvalidContent;
        try self.closeTag();
        try self.indentMarkup();
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
        if (self.wrote_root or self.lens.items.len > 0) return error.InvalidState;
        if (!chars.validText(raw)) return error.InvalidCharacter;
        self.out.writeAll("<!DOCTYPE ") catch |e| return werr(e);
        self.out.writeAll(raw) catch |e| return werr(e);
        self.out.writeAll(">") catch |e| return werr(e);
    }

    /// A line break between items outside the root element (after the declaration, comments and so on).
    pub fn lineBreak(self: *Writer) Error!void {
        if (self.lens.items.len > 0) return error.InvalidState;
        self.out.writeByte('\n') catch |e| return werr(e);
    }

    fn closeTag(self: *Writer) Error!void {
        if (self.in_tag) {
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
        if (self.lens.items.len == 0 and self.wrote_root) return error.InvalidState;
        try self.closeTag();
        const depth = self.lens.items.len;
        if (depth > 0 and self.only_elements.items[depth - 1]) try self.newline(depth);
        self.out.writeByte('<') catch |e| return werr(e);
        self.out.writeAll(name) catch |e| return werr(e);
        try self.names.appendSlice(self.gpa, name);
        try self.lens.append(self.gpa, @intCast(name.len));
        try self.only_elements.append(self.gpa, true);
        self.in_tag = true;
        self.wrote_root = true;
    }

    pub fn attribute(self: *Writer, name: []const u8, value: []const u8) Error!void {
        if (!self.in_tag) return error.InvalidState;
        if (!chars.isName(name)) return error.InvalidName;
        if (!chars.validText(value)) return error.InvalidCharacter;
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
        if (std.mem.indexOf(u8, s, "]]>") != null) return error.InvalidContent;
        try self.closeTag();
        self.only_elements.items[self.only_elements.items.len - 1] = false;
        self.out.writeAll("<![CDATA[") catch |e| return werr(e);
        self.out.writeAll(s) catch |e| return werr(e);
        self.out.writeAll("]]>") catch |e| return werr(e);
    }

    pub fn comment(self: *Writer, s: []const u8) Error!void {
        if (!chars.validText(s)) return error.InvalidCharacter;
        if (std.mem.indexOf(u8, s, "--") != null or std.mem.endsWith(u8, s, "-")) return error.InvalidContent;
        try self.closeTag();
        try self.indentMarkup();
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
        const len = self.lens.pop() orelse return error.InvalidState;
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

test "misuse is an error, not bad output" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = Writer.init(testing.allocator, &aw.writer, .{});
    defer w.deinit();
    try testing.expectError(error.InvalidState, w.end());
    try testing.expectError(error.InvalidState, w.text("x"));
    try testing.expectError(error.InvalidName, w.start("1bad"));
    try w.start("a");
    try testing.expectError(error.InvalidName, w.attribute("a b", "x"));
    try testing.expectError(error.InvalidCharacter, w.attribute("k", "a\x01"));
    try testing.expectError(error.InvalidContent, w.comment("a--b"));
    try testing.expectError(error.InvalidContent, w.cdata("x]]>y"));
    try w.end();
    try testing.expectError(error.InvalidState, w.start("second_root"));
}
