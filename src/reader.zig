//! A streaming ("pull") XML 1.0 parser.
//!
//! `Reader.next` returns one event at a time from any `std.Io.Reader`; the
//! document is never held in memory as a whole. Event data (names, text,
//! attribute values) is borrowed from the reader and stays valid until the next
//! call to `next`; copy what you need to keep.
//!
//! What is checked: well-formedness (matching tags, one root element, unique
//! attributes, legal names and characters, valid references), UTF-8, namespace
//! prefixes. What is deliberately not done (see docs/decisions/0002): entity
//! declarations are not expanded, external resources are never fetched, and
//! documents are not validated against a DTD.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const chars = @import("chars.zig");

pub const xml_namespace = "http://www.w3.org/XML/1998/namespace";
pub const xmlns_namespace = "http://www.w3.org/2000/xmlns/";

pub const Error = error{
    /// The input is not well-formed XML; see the `Diagnostic` for where and why.
    InvalidSyntax,
    InvalidName,
    /// A character outside the XML `Char` production, or invalid UTF-8.
    InvalidCharacter,
    UnexpectedEof,
    MismatchedTag,
    DuplicateAttribute,
    /// `&name;` for anything but the five predefined entities.
    UndefinedEntity,
    InvalidCharacterReference,
    UnboundPrefix,
    /// UTF-16, or a declared encoding other than UTF-8 / US-ASCII.
    UnsupportedEncoding,
    UnsupportedVersion,
    /// A `<!DOCTYPE` and `Options.doctype` is `.reject`.
    DoctypeNotAllowed,
    /// A configured limit was exceeded (depth, name, attributes, token, input size).
    LimitExceeded,
    ReadFailed,
    OutOfMemory,
};

pub const Diagnostic = struct {
    /// 1-based line; columns count bytes. 64 bits: a streamed document may put more than
    /// 4 GiB on one line.
    line: u64 = 0,
    column: u64 = 0,
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.line, self.column, self.message });
    }
};

pub const DoctypeMode = enum {
    /// A `<!DOCTYPE …>` is read and reported as an event; nothing in it is acted on.
    skip,
    /// A `<!DOCTYPE` is an error. The safest choice for formats that never have one.
    reject,
};

/// A named replacement for `&name;`, supplied by the caller (for example
/// `.{ .name = "nbsp", .value = "\u{a0}" }` for XHTML-style documents). The value is
/// inserted as plain text, never parsed, so it cannot contain markup or more references.
pub const Entity = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    /// Entities beyond the five predefined ones that the document may use.
    /// Declarations in the document's own DTD are never read (see docs/decisions/0001).
    entities: []const Entity = &.{},
    /// Resolve namespace prefixes (`Name.uri`); an unbound prefix is an error.
    namespaces: bool = true,
    doctype: DoctypeMode = .skip,
    /// Deepest element nesting.
    max_depth: u32 = 256,
    /// Longest element or attribute name, in bytes.
    max_name_bytes: u32 = 1024,
    max_attributes: u32 = 256,
    /// Largest single text run, attribute value, comment, CDATA section,
    /// processing instruction or DOCTYPE, in bytes.
    max_token_bytes: u32 = 16 * 1024 * 1024,
    /// Total input accepted, in bytes as read from the source, before any decoding (0 = unlimited).
    max_input_bytes: u64 = 0,
};

/// A name with its namespace resolved. All slices borrow from the reader.
pub const Name = struct {
    /// The name as written: `w:p`.
    qualified: []const u8,
    /// Before the colon; empty when there is none.
    prefix: []const u8,
    /// After the colon (the whole name when there is none).
    local: []const u8,
    /// The namespace URI; empty for no namespace (and always when `Options.namespaces` is off).
    uri: []const u8,

    /// True if the name is `local` in namespace `ns`.
    pub fn is(self: Name, ns: []const u8, local: []const u8) bool {
        return std.mem.eql(u8, self.local, local) and std.mem.eql(u8, self.uri, ns);
    }
};

pub const Attribute = struct {
    name: Name,
    /// With references expanded and whitespace normalized to spaces.
    value: []const u8,
};

pub const Decl = struct {
    version: []const u8,
    encoding: ?[]const u8,
    standalone: ?bool,
};

pub const Event = union(enum) {
    xml_decl: Decl,
    /// An element start. For `<a/>` an `end_element` follows immediately.
    start_element: struct { name: Name, attributes: []const Attribute, empty: bool },
    end_element: struct { name: Name },
    /// Character data with references expanded. One run of text may be reported
    /// as several consecutive events only around markup, never in the middle of a run.
    text: []const u8,
    cdata: []const u8,
    comment: []const u8,
    processing_instruction: struct { target: []const u8, data: []const u8 },
    /// The text between `<!DOCTYPE` and its closing `>`, including any internal subset.
    doctype: []const u8,
    end_of_document,
};

const State = enum { start, prolog, content, epilog, done };

const Encoding = enum { utf8, utf16le, utf16be, latin1 };

const Span = struct { off: u32, len: u32 };

pub const Reader = struct {
    gpa: Allocator,
    src: *Io.Reader,
    options: Options,
    diag: ?*Diagnostic,

    state: State = .start,
    line: u64 = 1,
    col: u64 = 1,
    consumed: u64 = 0,

    /// Scratch for the current event's text.
    buf: std.ArrayList(u8) = .empty,
    /// Names and values of the current tag's attributes, back to back.
    tag_buf: std.ArrayList(u8) = .empty,
    attrs: std.ArrayList(Attribute) = .empty,
    raw_attrs: std.ArrayList(struct { name: Span, value: Span }) = .empty,
    /// Names of the open elements, back to back, with their lengths.
    names: std.ArrayList(u8) = .empty,
    name_lens: std.ArrayList(u32) = .empty,
    /// In-scope namespace bindings (prefix and uri back to back) and how many each element added.
    ns_bytes: std.ArrayList(u8) = .empty,
    ns_binds: std.ArrayList(struct { prefix: Span, uri: Span }) = .empty,
    ns_marks: std.ArrayList(u32) = .empty,

    /// How the input's bytes are read: UTF-8 as is, or decoded to UTF-8 on the way in.
    enc: Encoding = .utf8,
    /// Bytes of one decoded character waiting to be handed out (non-UTF-8 input).
    pend: [4]u8 = undefined,
    pend_len: u8 = 0,
    pend_pos: u8 = 0,
    /// Raw bytes read ahead while detecting the encoding, to be read again.
    push: [2]u8 = undefined,
    push_len: u8 = 0,
    had_utf8_bom: bool = false,
    /// An end event owed for an empty element (`<a/>`).
    pending_end: bool = false,
    /// The name of the element that just ended, kept until the next call so the event can borrow it.
    last_name: std.ArrayList(u8) = .empty,
    root_seen: bool = false,
    doctype_seen: bool = false,
    /// No event has been produced yet and no whitespace consumed: an XML declaration is still allowed.
    first_token: bool = true,
    /// The error that stopped the reader. A failed reader stays failed: its stacks may be
    /// half-updated, so carrying on would give wrong events or worse.
    failure: ?Error = null,
    /// Whether the diagnostic has been filled for this reader's error.
    diagnosed: bool = false,

    pub fn init(gpa: Allocator, src: *Io.Reader, options: Options, diag: ?*Diagnostic) Reader {
        return .{ .gpa = gpa, .src = src, .options = options, .diag = diag };
    }

    pub fn deinit(self: *Reader) void {
        self.buf.deinit(self.gpa);
        self.tag_buf.deinit(self.gpa);
        self.attrs.deinit(self.gpa);
        self.raw_attrs.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.name_lens.deinit(self.gpa);
        self.ns_bytes.deinit(self.gpa);
        self.ns_binds.deinit(self.gpa);
        self.ns_marks.deinit(self.gpa);
        self.last_name.deinit(self.gpa);
        self.* = undefined;
    }

    /// Open elements right now (0 outside the root element).
    pub fn depth(self: *const Reader) usize {
        return self.name_lens.items.len;
    }

    // ------------------------------------------------------------ errors

    fn fail(self: *Reader, err: Error, message: []const u8) Error {
        self.diagnose(message);
        return err;
    }

    /// Fills the caller's diagnostic with the current position and `message`.
    pub fn diagnose(self: *Reader, message: []const u8) void {
        self.diagnosed = true;
        if (self.diag) |d| d.* = .{ .line = self.line, .column = self.col, .message = message };
    }

    // ------------------------------------------------------- byte access

    /// The next byte of input, or null at the end. Every input byte passes through here and
    /// `tossRaw`, which is what makes `max_input_bytes` exact for every encoding.
    fn peekRaw(self: *Reader) Error!?u8 {
        const b = if (self.push_len > 0) self.push[0] else if (self.src.buffer.len == 0) blk: {
            // An unbuffered source cannot be peeked: read one byte and hold it here.
            var one: [1]u8 = undefined;
            if (try self.src.readSliceShort(&one) == 0) return null;
            self.push[0] = one[0];
            self.push_len = 1;
            break :blk one[0];
        } else blk: {
            const s = self.src.peek(1) catch |e| switch (e) {
                error.EndOfStream => return null,
                error.ReadFailed => return error.ReadFailed,
            };
            break :blk s[0];
        };
        if (self.options.max_input_bytes != 0 and self.consumed >= self.options.max_input_bytes)
            return self.fail(error.LimitExceeded, "the input is larger than the configured limit");
        return b;
    }

    fn tossRaw(self: *Reader) void {
        self.consumed += 1;
        if (self.push_len > 0) {
            self.push_len -= 1;
            self.push[0] = self.push[1];
        } else self.src.toss(1);
    }

    /// Puts back the byte just taken, to be read again.
    fn unreadRaw(self: *Reader, b: u8) void {
        if (self.push_len > 0) self.push[1] = self.push[0];
        self.push[0] = b;
        self.push_len += 1;
        self.consumed -= 1;
    }

    fn takeRaw(self: *Reader) Error!?u8 {
        const b = (try self.peekRaw()) orelse return null;
        self.tossRaw();
        return b;
    }

    /// Decodes the next character of a UTF-16 or Latin-1 document into `pend`; false at the end.
    fn decodeNext(self: *Reader) Error!bool {
        var cp: u21 = undefined;
        if (self.enc == .latin1) {
            cp = (try self.takeRaw()) orelse return false;
        } else {
            const unit = (try self.takeUnit()) orelse return false;
            if (unit >= 0xDC00 and unit <= 0xDFFF) return self.fail(error.InvalidCharacter, "a lone low surrogate in UTF-16");
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                const low = (try self.takeUnit()) orelse return self.fail(error.UnexpectedEof, "the document ends inside a UTF-16 surrogate pair");
                if (low < 0xDC00 or low > 0xDFFF) return self.fail(error.InvalidCharacter, "a high surrogate without its low surrogate in UTF-16");
                cp = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low - 0xDC00);
            } else cp = unit;
        }
        const n = std.unicode.utf8Encode(cp, &self.pend) catch return self.fail(error.InvalidCharacter, "a character that cannot be represented");
        self.pend_len = @intCast(n);
        self.pend_pos = 0;
        return true;
    }

    fn takeUnit(self: *Reader) Error!?u16 {
        const b0 = (try self.takeRaw()) orelse return null;
        const b1 = (try self.takeRaw()) orelse return self.fail(error.UnexpectedEof, "the document ends inside a UTF-16 character");
        return if (self.enc == .utf16le) @as(u16, b1) << 8 | b0 else @as(u16, b0) << 8 | b1;
    }

    fn peekByte(self: *Reader) Error!?u8 {
        if (self.enc == .utf8) return self.peekRaw();
        if (self.pend_pos >= self.pend_len) {
            if (!try self.decodeNext()) return null;
        }
        return self.pend[self.pend_pos];
    }

    fn tossByte(self: *Reader) void {
        if (self.enc == .utf8) self.tossRaw() else self.pend_pos += 1;
    }

    /// The next byte with line ends normalized (`\r\n` and `\r` become `\n`), or null at the end.
    fn takeByte(self: *Reader) Error!?u8 {
        var b = (try self.peekByte()) orelse return null;
        self.tossByte();
        if (b == '\r') {
            if ((try self.peekByte()) == @as(u8, '\n')) self.tossByte();
            b = '\n';
        }
        if (b == '\n') {
            self.line += 1;
            self.col = 1;
        } else self.col += 1;
        return b;
    }

    fn mustTake(self: *Reader) Error!u8 {
        return (try self.takeByte()) orelse self.fail(error.UnexpectedEof, "the document ends inside markup");
    }

    fn expect(self: *Reader, literal: []const u8) Error!void {
        for (literal) |want| {
            const b = try self.mustTake();
            if (b != want) return self.fail(error.InvalidSyntax, "unexpected character in markup");
        }
    }

    fn skipSpace(self: *Reader) Error!bool {
        var any = false;
        while (try self.peekByte()) |b| {
            if (!chars.isSpace(b)) break;
            _ = try self.takeByte();
            any = true;
        }
        return any;
    }

    fn append(self: *Reader, list: *std.ArrayList(u8), b: u8) Error!void {
        if (list.items.len >= self.options.max_token_bytes) return self.fail(error.LimitExceeded, "a token is longer than the configured limit");
        try list.append(self.gpa, b);
    }

    // ------------------------------------------------------------ events

    /// The next event. After an error, every further call returns that same error.
    pub fn next(self: *Reader) Error!Event {
        if (self.failure) |e| return e;
        const ev = self.nextEvent() catch |e| {
            self.failure = e;
            // Parse errors describe themselves where they are found; these two come from below.
            if (!self.diagnosed) switch (e) {
                error.ReadFailed => self.diagnose("the input could not be read"),
                error.OutOfMemory => self.diagnose("out of memory"),
                else => self.diagnose(@errorName(e)),
            };
            return e;
        };
        self.first_token = false;
        return ev;
    }

    fn nextEvent(self: *Reader) Error!Event {
        if (self.pending_end) {
            self.pending_end = false;
            const ev = try self.endCurrent();
            return ev;
        }
        switch (self.state) {
            .start => return self.readStart(),
            .prolog, .epilog => return self.readMisc(),
            .content => return self.readContent(),
            .done => return .end_of_document,
        }
    }

    fn readStart(self: *Reader) Error!Event {
        // Byte order mark, or the first bytes of `<?` in UTF-16 (XML 1.0, appendix F).
        const head = (try self.peekRaw()) orelse return self.fail(error.UnexpectedEof, "the document is empty");
        switch (head) {
            0xEF => {
                for ("\xEF\xBB\xBF") |want| {
                    const b = (try self.takeRaw()) orelse return self.fail(error.InvalidSyntax, "the document does not start with XML");
                    if (b != want) return self.fail(error.InvalidSyntax, "the document does not start with XML");
                }
                self.had_utf8_bom = true;
            },
            0xFE, 0xFF => {
                _ = try self.takeRaw();
                const second = (try self.takeRaw()) orelse return self.fail(error.InvalidSyntax, "the document does not start with XML");
                if (head == 0xFE and second == 0xFF) {
                    self.enc = .utf16be;
                } else if (head == 0xFF and second == 0xFE) {
                    self.enc = .utf16le;
                } else return self.fail(error.UnsupportedEncoding, "the byte order mark is not UTF-8 or UTF-16");
            },
            0x00, '<' => {
                // UTF-16 without a mark starts `\0<` (big endian) or `<\0` (little endian).
                self.tossRaw();
                const second = try self.peekRaw();
                self.unreadRaw(head);
                if (head == 0x00) {
                    if (second != @as(u8, '<')) return self.fail(error.UnsupportedEncoding, "this encoding is not supported (UTF-8, UTF-16 and ISO-8859-1 are)");
                    self.enc = .utf16be;
                } else if (second == @as(u8, 0x00)) self.enc = .utf16le;
            },
            else => {},
        }
        self.state = .prolog;
        return self.readMisc();
    }

    /// The pseudo-attributes of an XML declaration; `self.buf` holds the text after `<?xml`.
    fn readXmlDecl(self: *Reader) Error!Event {
        if (!chars.validText(self.buf.items)) return self.fail(error.InvalidCharacter, "invalid character in the XML declaration");
        const text = self.buf.items;
        var version: ?[]const u8 = null;
        var encoding: ?[]const u8 = null;
        var standalone: ?bool = null;
        var i: usize = 0;
        var seen: u8 = 0; // order check: version, encoding, standalone
        var first_attr = true;
        while (true) {
            const before = i;
            while (i < text.len and chars.isSpace(text[i])) i += 1;
            if (i >= text.len) break;
            // Each pseudo-attribute is set off by whitespace (production 23 and following).
            if (i == before and !first_attr) return self.fail(error.InvalidSyntax, "pseudo-attributes of the XML declaration must be separated by whitespace");
            first_attr = false;
            const ns = i;
            while (i < text.len and text[i] != '=' and !chars.isSpace(text[i])) i += 1;
            const key = text[ns..i];
            while (i < text.len and chars.isSpace(text[i])) i += 1;
            if (i >= text.len or text[i] != '=') return self.fail(error.InvalidSyntax, "malformed XML declaration");
            i += 1;
            while (i < text.len and chars.isSpace(text[i])) i += 1;
            if (i >= text.len or (text[i] != '"' and text[i] != '\'')) return self.fail(error.InvalidSyntax, "malformed XML declaration");
            const q = text[i];
            i += 1;
            const vs = i;
            while (i < text.len and text[i] != q) i += 1;
            if (i >= text.len) return self.fail(error.InvalidSyntax, "malformed XML declaration");
            const val = text[vs..i];
            i += 1;
            if (std.mem.eql(u8, key, "version")) {
                if (seen != 0) return self.fail(error.InvalidSyntax, "version must come first in the XML declaration");
                version = val;
                seen = 1;
            } else if (std.mem.eql(u8, key, "encoding")) {
                if (seen != 1) return self.fail(error.InvalidSyntax, "encoding must follow version in the XML declaration");
                encoding = val;
                seen = 2;
            } else if (std.mem.eql(u8, key, "standalone")) {
                if (seen == 0 or seen == 3) return self.fail(error.InvalidSyntax, "standalone is misplaced in the XML declaration");
                if (std.mem.eql(u8, val, "yes")) standalone = true else if (std.mem.eql(u8, val, "no")) standalone = false else return self.fail(error.InvalidSyntax, "standalone must be yes or no");
                seen = 3;
            } else return self.fail(error.InvalidSyntax, "unknown pseudo-attribute in the XML declaration");
        }
        const v = version orelse return self.fail(error.InvalidSyntax, "the XML declaration needs a version");
        // VersionNum is `1.` and digits (production 26, fifth edition). 1.1 has different rules
        // (line ends, name characters) that are not implemented, so it is refused rather than misread.
        if (v.len < 3 or !std.mem.startsWith(u8, v, "1.")) return self.fail(error.InvalidSyntax, "a version number is 1. followed by digits");
        for (v[2..]) |d| if (!std.ascii.isDigit(d)) return self.fail(error.InvalidSyntax, "a version number is 1. followed by digits");
        if (std.mem.eql(u8, v, "1.1")) return self.fail(error.UnsupportedVersion, "XML 1.1 is not supported");
        if (encoding) |enc| try self.applyDeclaredEncoding(enc);
        return .{ .xml_decl = .{ .version = v, .encoding = encoding, .standalone = standalone } };
    }

    /// Checks the encoding named in the declaration against how the document was detected, and
    /// switches to ISO-8859-1 decoding if that is what it says.
    fn applyDeclaredEncoding(self: *Reader, enc: []const u8) Error!void {
        const eql = std.ascii.eqlIgnoreCase;
        const is_utf16 = eql(enc, "utf-16") or eql(enc, "utf-16le") or eql(enc, "utf-16be");
        const is_latin1 = eql(enc, "iso-8859-1") or eql(enc, "iso_8859-1") or eql(enc, "latin1") or eql(enc, "latin-1") or eql(enc, "l1");
        switch (self.enc) {
            .utf16le, .utf16be => {
                if (!is_utf16) return self.fail(error.UnsupportedEncoding, "the declared encoding does not match the UTF-16 document");
            },
            .utf8 => {
                if (eql(enc, "utf-8") or eql(enc, "us-ascii")) return;
                if (is_latin1 and !self.had_utf8_bom and self.pend_len == 0) {
                    self.enc = .latin1;
                    return;
                }
                return self.fail(error.UnsupportedEncoding, "unsupported or conflicting encoding (UTF-8, US-ASCII, UTF-16 and ISO-8859-1 are supported)");
            },
            .latin1 => {},
        }
    }

    /// Prolog and epilog: whitespace, comments, processing instructions, the
    /// DOCTYPE (prolog only) and, in the prolog, the root element.
    fn readMisc(self: *Reader) Error!Event {
        while (true) {
            if (try self.skipSpace()) self.first_token = false;
            const b = (try self.peekByte()) orelse {
                if (self.state == .prolog) return self.fail(error.UnexpectedEof, "the document has no root element");
                self.state = .done;
                return .end_of_document;
            };
            if (b != '<') return self.fail(error.InvalidSyntax, if (self.state == .prolog) "text before the root element" else "text after the root element");
            _ = try self.takeByte();
            const c = try self.mustTake();
            switch (c) {
                '?' => return self.readPi(),
                '!' => {
                    const d = try self.mustTake();
                    if (d == '-') return self.readComment();
                    if (d == 'D' and self.state == .prolog and !self.root_seen and !self.doctype_seen) return self.readDoctype();
                    return self.fail(error.InvalidSyntax, "unexpected markup outside the root element");
                },
                '/' => return self.fail(error.InvalidSyntax, "an end tag with no open element"),
                else => {
                    if (self.state == .epilog) return self.fail(error.InvalidSyntax, "a second root element");
                    return self.readStartTag(c);
                },
            }
        }
    }

    fn readContent(self: *Reader) Error!Event {
        const b = (try self.peekByte()) orelse return self.fail(error.UnexpectedEof, "the document ends inside an element");
        if (b != '<') return self.readText();
        _ = try self.takeByte();
        const c = try self.mustTake();
        switch (c) {
            '/' => return self.readEndTag(),
            '?' => return self.readPi(),
            '!' => {
                const d = try self.mustTake();
                if (d == '-') return self.readComment();
                if (d == '[') return self.readCdata();
                return self.fail(error.InvalidSyntax, "unexpected markup in element content");
            },
            else => return self.readStartTag(c),
        }
    }

    // -------------------------------------------------------------- text

    /// Reads `&…;` after the `&` was taken, appending the replacement to `out`.
    fn readReference(self: *Reader, out: *std.ArrayList(u8)) Error!void {
        const first = try self.mustTake();
        if (first == '#') {
            var hex = false;
            var c = try self.mustTake();
            if (c == 'x') {
                hex = true;
                c = try self.mustTake();
            }
            var value: u32 = 0;
            var digits: u64 = 0;
            while (c != ';') : (c = try self.mustTake()) {
                const d: u32 = if (hex) (std.fmt.charToDigit(c, 16) catch return self.fail(error.InvalidCharacterReference, "bad digit in a character reference")) else (std.fmt.charToDigit(c, 10) catch return self.fail(error.InvalidCharacterReference, "bad digit in a character reference"));
                value = value * @as(u32, if (hex) 16 else 10) + d;
                digits += 1;
                // Leading zeros never reach the range check, so bound the reference like any token.
                if (digits > self.options.max_token_bytes) return self.fail(error.LimitExceeded, "a token is longer than the configured limit");
                if (value > 0x10FFFF) return self.fail(error.InvalidCharacterReference, "a character reference is out of range");
            }
            if (digits == 0) return self.fail(error.InvalidCharacterReference, "an empty character reference");
            const cp: u21 = @intCast(value);
            if (!chars.isChar(cp)) return self.fail(error.InvalidCharacterReference, "a character reference names a character XML does not allow");
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch return self.fail(error.InvalidCharacterReference, "invalid character reference");
            for (tmp[0..n]) |x| try self.append(out, x);
            return;
        }
        // A name, then `;`.
        var name: [64]u8 = undefined;
        var n: usize = 0;
        var c = first;
        while (c != ';') : (c = try self.mustTake()) {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':')) return self.fail(error.UndefinedEntity, "a & that does not start a reference (write &amp;)");
            if (n >= name.len) return self.fail(error.UndefinedEntity, "an entity name that is too long");
            name[n] = c;
            n += 1;
        }
        const s = name[0..n];
        for (self.options.entities) |e| if (std.mem.eql(u8, e.name, s)) {
            for (e.value) |x| try self.append(out, x);
            return;
        };
        const rep: u8 = if (std.mem.eql(u8, s, "lt")) '<' else if (std.mem.eql(u8, s, "gt")) '>' else if (std.mem.eql(u8, s, "amp")) '&' else if (std.mem.eql(u8, s, "quot")) '"' else if (std.mem.eql(u8, s, "apos")) '\'' else return self.fail(error.UndefinedEntity, "an entity other than lt, gt, amp, quot, apos");
        try self.append(out, rep);
    }

    fn readText(self: *Reader) Error!Event {
        self.buf.clearRetainingCapacity();
        var brackets: u32 = 0; // raw `]` just seen, for the `]]>` rule
        while (try self.peekByte()) |b| {
            if (b == '<') break;
            _ = try self.takeByte();
            if (b == '&') {
                brackets = 0;
                try self.readReference(&self.buf);
                continue;
            }
            if (b == '>' and brackets >= 2) return self.fail(error.InvalidSyntax, "]]> is not allowed in text");
            brackets = if (b == ']') brackets + 1 else 0;
            try self.append(&self.buf, if (b == '\r') '\n' else b);
        }
        if (!chars.validText(self.buf.items)) return self.fail(error.InvalidCharacter, "invalid UTF-8 or a character XML does not allow");
        return .{ .text = self.buf.items };
    }

    fn readCdata(self: *Reader) Error!Event {
        try self.expect("CDATA[");
        self.buf.clearRetainingCapacity();
        while (true) {
            const b = try self.mustTake();
            if (b == '>' and self.buf.items.len >= 2 and self.buf.items[self.buf.items.len - 1] == ']' and self.buf.items[self.buf.items.len - 2] == ']') {
                self.buf.items.len -= 2;
                break;
            }
            try self.append(&self.buf, b);
        }
        if (!chars.validText(self.buf.items)) return self.fail(error.InvalidCharacter, "invalid UTF-8 or a character XML does not allow");
        return .{ .cdata = self.buf.items };
    }

    fn readComment(self: *Reader) Error!Event {
        // `<!-` was taken.
        try self.expect("-");
        self.buf.clearRetainingCapacity();
        while (true) {
            const b = try self.mustTake();
            if (b == '-' and self.buf.items.len >= 1 and self.buf.items[self.buf.items.len - 1] == '-') {
                const c = try self.mustTake();
                if (c != '>') return self.fail(error.InvalidSyntax, "-- is not allowed inside a comment");
                self.buf.items.len -= 1;
                break;
            }
            try self.append(&self.buf, b);
        }
        if (!chars.validText(self.buf.items)) return self.fail(error.InvalidCharacter, "invalid UTF-8 or a character XML does not allow");
        return .{ .comment = self.buf.items };
    }

    fn readPi(self: *Reader) Error!Event {
        // `<?` was taken: target, then optional whitespace and data, up to `?>`.
        self.buf.clearRetainingCapacity();
        var c = try self.mustTake();
        while (!chars.isSpace(c) and c != '?') : (c = try self.mustTake()) try self.append(&self.buf, c);
        const target_len = self.buf.items.len;
        if (!chars.isName(self.buf.items)) return self.fail(error.InvalidName, "bad processing instruction target");
        if (self.options.namespaces and std.mem.indexOfScalar(u8, self.buf.items, ':') != null) return self.fail(error.InvalidName, "a processing instruction target cannot contain a colon");
        const is_decl_target = std.mem.eql(u8, self.buf.items, "xml");
        if (std.ascii.eqlIgnoreCase(self.buf.items, "xml") and !(is_decl_target and self.first_token and chars.isSpace(c)))
            return self.fail(error.InvalidSyntax, "an XML declaration is only allowed at the very start");
        if (is_decl_target and self.first_token) {
            self.buf.clearRetainingCapacity();
            while (true) {
                const b = try self.mustTake();
                if (b == '?' and (try self.peekByte()) == @as(u8, '>')) {
                    _ = try self.takeByte();
                    break;
                }
                try self.append(&self.buf, b);
            }
            return self.readXmlDecl();
        }
        if (c == '?') {
            if ((try self.mustTake()) != '>') return self.fail(error.InvalidSyntax, "malformed processing instruction");
            return .{ .processing_instruction = .{ .target = self.buf.items[0..target_len], .data = "" } };
        }
        _ = try self.skipSpace();
        while (true) {
            const b = try self.mustTake();
            if (b == '?' and (try self.peekByte()) == @as(u8, '>')) {
                _ = try self.takeByte();
                break;
            }
            try self.append(&self.buf, b);
        }
        if (!chars.validText(self.buf.items)) return self.fail(error.InvalidCharacter, "invalid UTF-8 or a character XML does not allow");
        return .{ .processing_instruction = .{ .target = self.buf.items[0..target_len], .data = self.buf.items[target_len..] } };
    }

    fn readDoctype(self: *Reader) Error!Event {
        if (self.options.doctype == .reject) return self.fail(error.DoctypeNotAllowed, "this document type does not allow a DOCTYPE");
        // `<!D` was taken. The declaration may hold an internal subset in
        // brackets, with quoted strings and comments that can hide `>`.
        try self.expect("OCTYPE");
        self.buf.clearRetainingCapacity();
        var bracket_depth: u32 = 0;
        var quote: u8 = 0;
        var skipping: enum { no, comment, pi } = .no;
        while (true) {
            const b = try self.mustTake();
            const so_far = self.buf.items;
            if (skipping == .comment) {
                if (b == '>' and std.mem.endsWith(u8, so_far, "--")) skipping = .no;
            } else if (skipping == .pi) {
                if (b == '>' and std.mem.endsWith(u8, so_far, "?")) skipping = .no;
            } else if (quote != 0) {
                if (b == quote) quote = 0;
            } else if (bracket_depth > 0 and b == '-' and std.mem.endsWith(u8, so_far, "<!-")) {
                skipping = .comment;
            } else if (bracket_depth > 0 and b == '?' and std.mem.endsWith(u8, so_far, "<")) {
                skipping = .pi;
            } else switch (b) {
                '"', '\'' => quote = b,
                '[' => bracket_depth += 1,
                ']' => {
                    if (bracket_depth == 0) return self.fail(error.InvalidSyntax, "unbalanced ] in the DOCTYPE");
                    bracket_depth -= 1;
                },
                '>' => if (bracket_depth == 0) break,
                else => {},
            }
            try self.append(&self.buf, b);
        }
        if (!chars.validText(self.buf.items)) return self.fail(error.InvalidCharacter, "invalid UTF-8 or a character XML does not allow");
        self.doctype_seen = true;
        return .{ .doctype = std.mem.trim(u8, self.buf.items, " \t\n") };
    }

    // -------------------------------------------------------------- tags

    /// Reads a name starting with `first` (already taken) into `tag_buf`; returns its span.
    fn readName(self: *Reader, first: u8) Error!Span {
        const start: u32 = @intCast(self.tag_buf.items.len);
        var c = first;
        while (true) {
            if (chars.isSpace(c) or c == '/' or c == '>' or c == '=') break;
            if (self.tag_buf.items.len - start >= self.options.max_name_bytes) return self.fail(error.LimitExceeded, "a name is longer than the configured limit");
            try self.tag_buf.append(self.gpa, c);
            c = (try self.peekByte()) orelse break;
            if (chars.isSpace(c) or c == '/' or c == '>' or c == '=') break;
            _ = try self.takeByte();
        }
        const len: u32 = @intCast(self.tag_buf.items.len - start);
        if (!chars.isName(self.tag_buf.items[start..])) return self.fail(error.InvalidName, "not a valid XML name");
        return .{ .off = start, .len = len };
    }

    fn readAttrValue(self: *Reader) Error!Span {
        const q = try self.mustTake();
        if (q != '"' and q != '\'') return self.fail(error.InvalidSyntax, "an attribute value must be quoted");
        const start: u32 = @intCast(self.tag_buf.items.len);
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(self.gpa);
        while (true) {
            const b = try self.mustTake();
            if (b == q) break;
            switch (b) {
                '<' => return self.fail(error.InvalidSyntax, "< is not allowed in an attribute value"),
                '&' => try self.readReference(&tmp),
                '\n', '\t' => try self.append(&tmp, ' '),
                else => try self.append(&tmp, b),
            }
        }
        if (!chars.validText(tmp.items)) return self.fail(error.InvalidCharacter, "invalid UTF-8 or a character XML does not allow");
        try self.tag_buf.appendSlice(self.gpa, tmp.items);
        return .{ .off = start, .len = @intCast(tmp.items.len) };
    }

    /// A QName has at most one colon, with something on both sides (Namespaces production 7-10).
    fn validQName(q: []const u8) bool {
        const c = std.mem.indexOfScalar(u8, q, ':') orelse return true;
        if (c == 0 or c == q.len - 1) return false;
        return std.mem.indexOfScalarPos(u8, q, c + 1, ':') == null;
    }

    fn splitName(q: []const u8) struct { prefix: []const u8, local: []const u8 } {
        if (std.mem.indexOfScalar(u8, q, ':')) |i| return .{ .prefix = q[0..i], .local = q[i + 1 ..] };
        return .{ .prefix = "", .local = q };
    }

    fn lookupPrefix(self: *const Reader, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return xml_namespace;
        if (std.mem.eql(u8, prefix, "xmlns")) return xmlns_namespace;
        var i = self.ns_binds.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.ns_binds.items[i];
            if (std.mem.eql(u8, self.ns_bytes.items[b.prefix.off..][0..b.prefix.len], prefix)) return self.ns_bytes.items[b.uri.off..][0..b.uri.len];
        }
        return null;
    }

    fn readStartTag(self: *Reader, first: u8) Error!Event {
        if (self.name_lens.items.len >= self.options.max_depth) return self.fail(error.LimitExceeded, "elements are nested deeper than the configured limit");
        self.tag_buf.clearRetainingCapacity();
        self.raw_attrs.clearRetainingCapacity();
        const elem = try self.readName(first);
        var empty = false;
        var had_space = false;
        while (true) {
            had_space = (try self.skipSpace()) or had_space;
            const b = try self.mustTake();
            if (b == '>') break;
            if (b == '/') {
                if ((try self.mustTake()) != '>') return self.fail(error.InvalidSyntax, "/ must be followed by > in a tag");
                empty = true;
                break;
            }
            if (!had_space) return self.fail(error.InvalidSyntax, "attributes must be separated by whitespace");
            if (self.raw_attrs.items.len >= self.options.max_attributes) return self.fail(error.LimitExceeded, "more attributes than the configured limit");
            const an = try self.readName(b);
            _ = try self.skipSpace();
            if ((try self.mustTake()) != '=') return self.fail(error.InvalidSyntax, "an attribute needs =");
            _ = try self.skipSpace();
            const av = try self.readAttrValue();
            try self.raw_attrs.append(self.gpa, .{ .name = an, .value = av });
            had_space = false;
        }
        const tag = self.tag_buf.items;
        if (self.options.namespaces) {
            if (!validQName(tag[elem.off..][0..elem.len])) return self.fail(error.InvalidName, "not a valid qualified name (one colon, with a name on each side)");
            for (self.raw_attrs.items) |ra| {
                if (!validQName(tag[ra.name.off..][0..ra.name.len])) return self.fail(error.InvalidName, "not a valid qualified name (one colon, with a name on each side)");
            }
        }

        // Push the element name (needed to match its end tag).
        const ename = tag[elem.off..][0..elem.len];
        try self.names.appendSlice(self.gpa, ename);
        try self.name_lens.append(self.gpa, elem.len);

        // Namespace declarations first: they apply to this element's own name.
        const mark = self.ns_binds.items.len;
        if (self.options.namespaces) for (self.raw_attrs.items) |ra| {
            const qn = tag[ra.name.off..][0..ra.name.len];
            const sp = splitName(qn);
            const is_default = std.mem.eql(u8, qn, "xmlns");
            if (!is_default and !std.mem.eql(u8, sp.prefix, "xmlns")) continue;
            const pfx: []const u8 = if (is_default) "" else sp.local;
            const uri = tag[ra.value.off..][0..ra.value.len];
            if (!is_default and (pfx.len == 0 or std.mem.eql(u8, pfx, "xmlns"))) return self.fail(error.InvalidName, "bad namespace declaration");
            if (!is_default and uri.len == 0) return self.fail(error.InvalidSyntax, "a prefix cannot be bound to an empty namespace");
            // The `xml` prefix only to its own namespace, and no other prefix to it or to the xmlns namespace.
            if (std.mem.eql(u8, pfx, "xml") and !std.mem.eql(u8, uri, xml_namespace)) return self.fail(error.InvalidSyntax, "the xml prefix can only be bound to the XML namespace");
            if (std.mem.eql(u8, uri, xml_namespace) and !std.mem.eql(u8, pfx, "xml")) return self.fail(error.InvalidSyntax, "the XML namespace can only be bound to the xml prefix");
            if (std.mem.eql(u8, uri, xmlns_namespace)) return self.fail(error.InvalidSyntax, "the xmlns namespace cannot be bound");
            const po: u32 = @intCast(self.ns_bytes.items.len);
            try self.ns_bytes.appendSlice(self.gpa, pfx);
            const uo: u32 = @intCast(self.ns_bytes.items.len);
            try self.ns_bytes.appendSlice(self.gpa, uri);
            try self.ns_binds.append(self.gpa, .{ .prefix = .{ .off = po, .len = @intCast(pfx.len) }, .uri = .{ .off = uo, .len = @intCast(uri.len) } });
        };
        try self.ns_marks.append(self.gpa, @intCast(self.ns_binds.items.len - mark));

        // Build the resolved names.
        self.attrs.clearRetainingCapacity();
        const e_sp = splitName(ename);
        const e_uri: []const u8 = if (!self.options.namespaces) "" else blk: {
            if (e_sp.prefix.len == 0) break :blk self.lookupPrefix("") orelse "";
            if (std.mem.eql(u8, e_sp.prefix, "xmlns")) return self.fail(error.InvalidName, "an element name cannot use the prefix xmlns");
            break :blk self.lookupPrefix(e_sp.prefix) orelse return self.fail(error.UnboundPrefix, "an element uses a namespace prefix that is not declared");
        };
        for (self.raw_attrs.items) |ra| {
            const qn = tag[ra.name.off..][0..ra.name.len];
            const sp = splitName(qn);
            var uri: []const u8 = "";
            if (self.options.namespaces) {
                if (std.mem.eql(u8, qn, "xmlns")) uri = xmlns_namespace else if (sp.prefix.len > 0) uri = self.lookupPrefix(sp.prefix) orelse return self.fail(error.UnboundPrefix, "an attribute uses a namespace prefix that is not declared");
            }
            // Unique by qualified name, and (with namespaces) by expanded name.
            for (self.attrs.items) |prev| {
                if (std.mem.eql(u8, prev.name.qualified, qn)) return self.fail(error.DuplicateAttribute, "an attribute appears twice");
                if (self.options.namespaces and uri.len > 0 and std.mem.eql(u8, prev.name.uri, uri) and std.mem.eql(u8, prev.name.local, sp.local))
                    return self.fail(error.DuplicateAttribute, "two attributes have the same expanded name");
            }
            try self.attrs.append(self.gpa, .{ .name = .{ .qualified = qn, .prefix = sp.prefix, .local = sp.local, .uri = uri }, .value = tag[ra.value.off..][0..ra.value.len] });
        }

        if (!self.root_seen) self.root_seen = true;
        self.state = .content;
        self.pending_end = empty;
        const names_now = self.names.items;
        const cur = names_now[names_now.len - elem.len ..];
        return .{ .start_element = .{ .name = .{ .qualified = cur, .prefix = e_sp.prefix, .local = e_sp.local, .uri = e_uri }, .attributes = self.attrs.items, .empty = empty } };
    }

    /// Pops the innermost element and returns its end event.
    fn endCurrent(self: *Reader) Error!Event {
        const len = self.name_lens.pop().?;
        const mark = self.ns_marks.pop().?;
        const name_start = self.names.items.len - len;
        // Keep the name for the event (the stack bytes are about to be released).
        self.last_name.clearRetainingCapacity();
        try self.last_name.appendSlice(self.gpa, self.names.items[name_start..]);
        // The uri must be resolved before the bindings go away.
        const q = self.last_name.items;
        const sp = splitName(q);
        var uri: []const u8 = "";
        if (self.options.namespaces) uri = if (sp.prefix.len == 0) (self.lookupPrefix("") orelse "") else (self.lookupPrefix(sp.prefix) orelse "");
        // The uri slice points into ns_bytes; copy it behind the name so it survives the pop.
        const uri_off = self.last_name.items.len;
        try self.last_name.appendSlice(self.gpa, uri);
        self.names.items.len = name_start;
        const keep = self.ns_binds.items.len - mark;
        if (mark > 0) {
            const first = self.ns_binds.items[keep];
            self.ns_bytes.items.len = first.prefix.off;
            self.ns_binds.items.len = keep;
        }
        if (self.name_lens.items.len == 0) self.state = .epilog;
        const full = self.last_name.items;
        const qn = full[0..uri_off];
        const sp2 = splitName(qn);
        return .{ .end_element = .{ .name = .{ .qualified = qn, .prefix = sp2.prefix, .local = sp2.local, .uri = full[uri_off..] } } };
    }

    fn readEndTag(self: *Reader) Error!Event {
        // `</` was taken.
        if (self.name_lens.items.len == 0) return self.fail(error.InvalidSyntax, "an end tag with no open element");
        const open_len = self.name_lens.items[self.name_lens.items.len - 1];
        const open = self.names.items[self.names.items.len - open_len ..];
        for (open) |want| {
            const b = try self.mustTake();
            if (b != want) return self.fail(error.MismatchedTag, "an end tag does not match its start tag");
        }
        _ = try self.skipSpace();
        if ((try self.mustTake()) != '>') return self.fail(error.MismatchedTag, "an end tag does not match its start tag");
        return self.endCurrent();
    }
};

const testing = std.testing;

fn collect(arena: Allocator, src: []const u8, options: Options) ![]const u8 {
    var r: Io.Reader = .fixed(src);
    var rd = Reader.init(testing.allocator, &r, options, null);
    defer rd.deinit();
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const ev = try rd.next();
        switch (ev) {
            .xml_decl => |d| try out.print(arena, "[decl {s}]", .{d.version}),
            .start_element => |s| {
                try out.print(arena, "<{s}", .{s.name.qualified});
                for (s.attributes) |a| try out.print(arena, " {s}={s}", .{ a.name.qualified, a.value });
                try out.append(arena, '>');
            },
            .end_element => |e| try out.print(arena, "</{s}>", .{e.name.qualified}),
            .text => |t| try out.print(arena, "T({s})", .{t}),
            .cdata => |t| try out.print(arena, "C({s})", .{t}),
            .comment => |t| try out.print(arena, "#({s})", .{t}),
            .processing_instruction => |p| try out.print(arena, "?({s}|{s})", .{ p.target, p.data }),
            .doctype => |t| try out.print(arena, "D({s})", .{t}),
            .end_of_document => break,
        }
    }
    return out.items;
}

test "events of a small document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try collect(arena.allocator(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a x='1' y=\"2\">hi <b/>&amp;&#65;&#x42;<![CDATA[<raw>]]><!--c--><?pi data?></a>\n", .{});
    try testing.expectEqualStrings("[decl 1.0]<a x=1 y=2>T(hi )<b></b>T(&AB)C(<raw>)#(c)?(pi|data)</a>", out);
}
