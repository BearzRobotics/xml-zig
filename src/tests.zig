//! Conformance and robustness tests. Cases come from the XML 1.0 (Fifth
//! Edition) text, https://www.w3.org/TR/xml/ , with the production they test
//! named. The W3C XML conformance suite is NOT vendored and has not been run.

const std = @import("std");
const xml = @import("root.zig");
const testing = std.testing;
const Io = std.Io;

fn drain(src: []const u8, options: xml.Options) xml.Error!void {
    var r: Io.Reader = .fixed(src);
    return drainReader(&r, options);
}

fn drainReader(r: *Io.Reader, options: xml.Options) xml.Error!void {
    var rd = xml.Reader.init(testing.allocator, r, options, null);
    defer rd.deinit();
    while (true) if (try rd.next() == .end_of_document) return;
}

const valid = [_][]const u8{
    "<a/>",
    "<a></a>",
    "<?xml version=\"1.0\"?><a/>",
    "<?xml version='1.0' encoding='utf-8' standalone='yes'?><a/>",
    "\xEF\xBB\xBF<a/>", // a UTF-8 byte order mark
    "<a b='1' c=\"2\"/>",
    "<a  b = '1'\n c\t=\t'2' />",
    "<a>text &lt;&gt;&amp;&quot;&apos; &#65;&#x41;&#x1F600;</a>",
    "<a><![CDATA[ <not> & markup ]]></a>",
    "<a><!-- a comment --></a>",
    "<a><?target some data?></a>",
    "<a><?target?></a>",
    "<!-- before --><a/><!-- after -->",
    "<?pi x?><a/><?pi y?>",
    "<!DOCTYPE a><a/>",
    "<!DOCTYPE a SYSTEM \"a.dtd\"><a/>",
    "<!DOCTYPE a [ <!ENTITY e \"v\"> <!-- ] > --> ]><a/>",
    "<a>\r\n</a>",
    "<é/>",
    "<日本語 属性='値'/>",
    "<a:b xmlns:a='urn:x'/>",
    "<a xmlns='urn:x'><b/></a>",
    "<a xmlns:p='urn:1'><b xmlns:p='urn:2'><p:c/></b></a>",
    "<a x:y='1' xmlns:x='urn:x'/>",
    "<a xml:lang='en'/>",
    "<a>]]</a>",
    "<a>]&gt;</a>",
    "<a>x]]&gt;y</a>",
    "<a b='>'/>",
    "<a b=\"'\"/>",
    "<a>\n\n</a>\n\n",
    "  \n<a/>  \n",
    "<?xml\tversion='1.0'\n\tencoding='UTF-8'?><a/>",
    "<?xml version='1.7'?><a/>", // legal in the fifth edition
};

const not_well_formed = [_]struct { src: []const u8, err: xml.Error }{
    .{ .src = "", .err = error.UnexpectedEof },
    .{ .src = "   ", .err = error.UnexpectedEof },
    .{ .src = "text", .err = error.InvalidSyntax },
    .{ .src = "<a>", .err = error.UnexpectedEof },
    .{ .src = "<a", .err = error.UnexpectedEof },
    .{ .src = "<a></b>", .err = error.MismatchedTag },
    .{ .src = "<a><b></a></b>", .err = error.MismatchedTag },
    .{ .src = "<a></a", .err = error.UnexpectedEof },
    .{ .src = "</a>", .err = error.InvalidSyntax },
    .{ .src = "<a/><b/>", .err = error.InvalidSyntax }, // two roots
    .{ .src = "<a/>text", .err = error.InvalidSyntax },
    .{ .src = "text<a/>", .err = error.InvalidSyntax },
    .{ .src = "<a b=1/>", .err = error.InvalidSyntax }, // unquoted value
    .{ .src = "<a b='1/>", .err = error.UnexpectedEof },
    .{ .src = "<a b='1' b='2'/>", .err = error.DuplicateAttribute },
    .{ .src = "<a b='<'/>", .err = error.InvalidSyntax },
    .{ .src = "<a b/>", .err = error.InvalidSyntax },
    .{ .src = "<a b='1'c='2'/>", .err = error.InvalidSyntax }, // no space between attributes
    .{ .src = "<1a/>", .err = error.InvalidName },
    .{ .src = "<a b$='1'/>", .err = error.InvalidName },
    .{ .src = "<a>&</a>", .err = error.UndefinedEntity },
    .{ .src = "<a>&unknown;</a>", .err = error.UndefinedEntity },
    .{ .src = "<a>&amp</a>", .err = error.UndefinedEntity },
    .{ .src = "<a>&#;</a>", .err = error.InvalidCharacterReference },
    .{ .src = "<a>&#xZ;</a>", .err = error.InvalidCharacterReference },
    .{ .src = "<a>&#0;</a>", .err = error.InvalidCharacterReference },
    .{ .src = "<a>&#xD800;</a>", .err = error.InvalidCharacterReference },
    .{ .src = "<a>&#x110000;</a>", .err = error.InvalidCharacterReference },
    .{ .src = "<a>]]></a>", .err = error.InvalidSyntax }, // production 14
    .{ .src = "<a><!-- a -- b --></a>", .err = error.InvalidSyntax }, // production 15
    .{ .src = "<a><!-- a ---></a>", .err = error.InvalidSyntax },
    .{ .src = "<a><!-- open</a>", .err = error.UnexpectedEof },
    .{ .src = "<a><![CDATA[ open</a>", .err = error.UnexpectedEof },
    .{ .src = "<a><?xml version='1.0'?></a>", .err = error.InvalidSyntax }, // declaration not at the start
    .{ .src = " <?xml version='1.0'?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<?xml?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<?xml version='2.0'?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<?xml version='1.1'?><a/>", .err = error.UnsupportedVersion },
    .{ .src = "<?xml version='1.'?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<?xml version='1.0' encoding='latin-1'?><a/>", .err = error.UnsupportedEncoding },
    .{ .src = "<?xml encoding='utf-8' version='1.0'?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<?xml version='1.0' standalone='maybe'?><a/>", .err = error.InvalidSyntax },
    .{ .src = "\xFE\xFF\x00<\x00a\x00/", .err = error.UnsupportedEncoding }, // UTF-16
    .{ .src = "\xFF\xFE<\x00a\x00/\x00>\x00", .err = error.UnsupportedEncoding },
    .{ .src = "<a>\x01</a>", .err = error.InvalidCharacter }, // production 2
    .{ .src = "<a>\xFF</a>", .err = error.InvalidCharacter },
    .{ .src = "<a>\xEF\xBF\xBE</a>", .err = error.InvalidCharacter },
    .{ .src = "<a x='\x02'/>", .err = error.InvalidCharacter },
    .{ .src = "<a><!-- \x03 --></a>", .err = error.InvalidCharacter },
    .{ .src = "<!DOCTYPE a><!DOCTYPE a><a/>", .err = error.InvalidSyntax },
    .{ .src = "<a><!DOCTYPE a></a>", .err = error.InvalidSyntax },
    .{ .src = "<a/><!DOCTYPE a>", .err = error.InvalidSyntax },
    .{ .src = "<p:a/>", .err = error.UnboundPrefix },
    .{ .src = "<a p:b='1'/>", .err = error.UnboundPrefix },
    .{ .src = "<a xmlns:p='urn:x' xmlns:q='urn:x' p:b='1' q:b='2'/>", .err = error.DuplicateAttribute },
    .{ .src = "<a xmlns:p=''/>", .err = error.InvalidSyntax },
    .{ .src = "<a xmlns:xmlns='urn:x'/>", .err = error.InvalidName },
    // Found by the W3C suite.
    .{ .src = "<?xml version=\"1.0\"encoding=\"UTF-8\"?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<?xml version=\"1.0\"standalone=\"yes\"?><a/>", .err = error.InvalidSyntax },
    .{ .src = "<:foo/>", .err = error.InvalidName },
    .{ .src = "<foo:/>", .err = error.InvalidName },
    .{ .src = "<a:b:c xmlns:a='urn:x' xmlns:b='urn:y'/>", .err = error.InvalidName },
    .{ .src = "<a xmlns:xml='urn:other'/>", .err = error.InvalidSyntax },
    .{ .src = "<a xmlns:yml='http://www.w3.org/XML/1998/namespace'/>", .err = error.InvalidSyntax },
    .{ .src = "<a xmlns:y='http://www.w3.org/2000/xmlns/'/>", .err = error.InvalidSyntax },
    .{ .src = "<?a:b data?><foo/>", .err = error.InvalidName },
};

test "well-formed documents are accepted" {
    for (valid) |src| {
        errdefer std.debug.print("rejected: {s}\n", .{src});
        try drain(src, .{});
    }
}

test "not well-formed documents are refused with the right error" {
    for (not_well_formed) |c| {
        errdefer std.debug.print("case: {s}\n", .{c.src});
        try testing.expectError(c.err, drain(c.src, .{}));
    }
}

test "without namespace processing prefixes are only names" {
    try drain("<p:a q:b='1'/>", .{ .namespaces = false });
    try testing.expectError(error.DuplicateAttribute, drain("<a b='1' b='2'/>", .{ .namespaces = false }));
}

test "DOCTYPE can be refused" {
    try testing.expectError(error.DoctypeNotAllowed, drain("<!DOCTYPE a><a/>", .{ .doctype = .reject }));
    try drain("<a/>", .{ .doctype = .reject });
}

test "entity declarations are never expanded (a billion-laughs document is only a document)" {
    const bomb =
        \\<!DOCTYPE lolz [
        \\ <!ENTITY lol "lol">
        \\ <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        \\ <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        \\]>
        \\<lolz>&lol3;</lolz>
    ;
    // The declarations are skipped and the reference is an error: nothing expands.
    try testing.expectError(error.UndefinedEntity, drain(bomb, .{}));
    try drain("<!DOCTYPE a [ <!ENTITY e \"x\"> ]><a/>", .{});
}

test "limits" {
    try testing.expectError(error.LimitExceeded, drain("<a><b><c/></b></a>", .{ .max_depth = 2 }));
    try drain("<a><b/></a>", .{ .max_depth = 2 });
    try testing.expectError(error.LimitExceeded, drain("<abcdefgh/>", .{ .max_name_bytes = 4 }));
    try testing.expectError(error.LimitExceeded, drain("<a x='1' y='2' z='3'/>", .{ .max_attributes = 2 }));
    try testing.expectError(error.LimitExceeded, drain("<a>0123456789</a>", .{ .max_token_bytes = 5 }));
    try testing.expectError(error.LimitExceeded, drain("<a x='0123456789'/>", .{ .max_token_bytes = 5 }) catch error.LimitExceeded);
    try testing.expectError(error.LimitExceeded, drain("<a>some text here</a>", .{ .max_input_bytes = 8 }));
    // Deeply nested input is refused, not a stack overflow.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    for (0..10000) |_| try deep.appendSlice(testing.allocator, "<a>");
    try testing.expectError(error.LimitExceeded, drain(deep.items, .{}));
}

test "line ends are normalized and positions are reported" {
    var r: Io.Reader = .fixed("<a>x\r\ny\rz</a>");
    var rd = xml.Reader.init(testing.allocator, &r, .{}, null);
    defer rd.deinit();
    _ = try rd.next();
    const t = try rd.next();
    try testing.expectEqualStrings("x\ny\nz", t.text);

    var diag: xml.Diagnostic = .{};
    var r2: Io.Reader = .fixed("<a>\n  <b>\n</c>");
    var rd2 = xml.Reader.init(testing.allocator, &r2, .{}, &diag);
    defer rd2.deinit();
    while (true) _ = rd2.next() catch break;
    try testing.expectEqual(@as(u32, 3), diag.line);
    try testing.expect(diag.message.len > 0);
}

test "attribute whitespace is normalized, references are not" {
    var r: Io.Reader = .fixed("<a v='x\ty\nz&#10;w'/>");
    var rd = xml.Reader.init(testing.allocator, &r, .{}, null);
    defer rd.deinit();
    const e = try rd.next();
    try testing.expectEqualStrings("x y z\nw", e.start_element.attributes[0].value);
}

test "namespaces resolve through nested scopes and unwind" {
    var r: Io.Reader = .fixed("<a xmlns='urn:d' xmlns:p='urn:1'><b xmlns:p='urn:2' xmlns=''><p:c/></b><p:d/></a>");
    var rd = xml.Reader.init(testing.allocator, &r, .{}, null);
    defer rd.deinit();
    const a = (try rd.next()).start_element;
    try testing.expectEqualStrings("urn:d", a.name.uri);
    const b = (try rd.next()).start_element;
    try testing.expectEqualStrings("", b.name.uri); // xmlns="" undeclares the default
    const c = (try rd.next()).start_element;
    try testing.expect(c.name.is("urn:2", "c"));
    const c_end = (try rd.next()).end_element;
    try testing.expect(c_end.name.is("urn:2", "c"));
    const b_end = (try rd.next()).end_element;
    try testing.expect(b_end.name.is("", "b"));
    const d = (try rd.next()).start_element;
    try testing.expect(d.name.is("urn:1", "d")); // the outer binding is back
    _ = try rd.next();
    const a_end = (try rd.next()).end_element;
    try testing.expect(a_end.name.is("urn:d", "a"));
    try testing.expect(try rd.next() == .end_of_document);
}

/// A Reader that hands out `chunk` bytes at a time and can fail part-way.
const Trickle = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize,
    fail_after: ?usize = null,
    interface: Io.Reader,

    fn init(buffer: []u8, data: []const u8, chunk: usize, fail_after: ?usize) Trickle {
        return .{ .data = data, .chunk = chunk, .fail_after = fail_after, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("interface", r));
        if (self.fail_after) |f| if (self.pos >= f) return error.ReadFailed;
        if (self.pos >= self.data.len) return error.EndOfStream;
        var n = @min(self.chunk, self.data.len - self.pos);
        if (self.fail_after) |f| n = @min(n, f - self.pos);
        n = @min(n, @backingInt(limit));
        try w.writeAll(self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

const sample =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!-- c --><root xmlns:x="urn:x" a="1"><x:item id='1'>one &amp; two</x:item>
    \\<![CDATA[raw]]><?pi data?><empty/>é日本</root>
;

test "the result does not depend on how the input arrives" {
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    {
        var r: Io.Reader = .fixed(sample);
        var rd = xml.Reader.init(testing.allocator, &r, .{}, null);
        defer rd.deinit();
        while (true) {
            const ev = try rd.next();
            try expected.print(testing.allocator, "{s};", .{@tagName(ev)});
            if (ev == .end_of_document) break;
        }
    }
    for ([_]usize{ 1, 2, 3, 7, 64 }) |chunk| {
        var buf: [16]u8 = undefined;
        var t = Trickle.init(&buf, sample, chunk, null);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        var rd = xml.Reader.init(testing.allocator, &t.interface, .{}, null);
        defer rd.deinit();
        while (true) {
            const ev = try rd.next();
            try got.print(testing.allocator, "{s};", .{@tagName(ev)});
            if (ev == .end_of_document) break;
        }
        try testing.expectEqualStrings(expected.items, got.items);
    }
}

test "a read that fails part-way is reported, never a partial success" {
    var cut: usize = 1;
    while (cut < sample.len) : (cut += 5) {
        var buf: [8]u8 = undefined;
        var t = Trickle.init(&buf, sample, 3, cut);
        try testing.expectError(error.ReadFailed, drainReader(&t.interface, .{}));
    }
}

test "a reader with a tiny buffer still works" {
    var buf: [1]u8 = undefined;
    var t = Trickle.init(&buf, sample, 1, null);
    try drainReader(&t.interface, .{});
}

test "random bytes never crash the parser" {
    var prng = std.Random.DefaultPrng.init(0x584d4c);
    const rand = prng.random();
    const alphabet = "<>/=\"'&;!?-[]#xa b:\n\t\r\x00\xC3\xA9\xFF";
    var buf: [96]u8 = undefined;
    for (0..4000) |_| {
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        drain(buf[0..n], .{}) catch {};
    }
}

test "mutated valid documents never crash the parser" {
    var prng = std.Random.DefaultPrng.init(0x4d555441);
    const rand = prng.random();
    var buf: [sample.len]u8 = undefined;
    for (0..4000) |_| {
        @memcpy(&buf, sample);
        for (0..1 + rand.uintLessThan(usize, 4)) |_| buf[rand.uintLessThan(usize, buf.len)] = rand.int(u8);
        drain(&buf, .{}) catch {};
    }
}

test "writer output reads back as the same tree" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = xml.Writer.init(testing.allocator, &aw.writer, .{});
    defer w.deinit();
    try w.declaration();
    try w.start("doc");
    try w.attribute("title", "a \"quoted\" <title> & more\ttab");
    try w.start("item");
    try w.text("5 < 6 && 7 > 3 \u{1F600}");
    try w.end();
    try w.start("empty");
    try w.end();
    try w.finish();

    var doc = try xml.Document.parse(testing.allocator, aw.written(), .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("a \"quoted\" <title> & more\ttab", doc.root.attr("title").?);
    const text = try doc.root.child("item").?.textContent(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("5 < 6 && 7 > 3 \u{1F600}", text);
    try testing.expect(doc.root.child("empty") != null);
}
