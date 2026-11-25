//! The examples in docs/api.md, compiled and run so they cannot go stale.

const std = @import("std");
const xml = @import("root.zig");
const testing = std.testing;
const Io = std.Io;

test "stream events and pick out text" {
    const gpa = testing.allocator;
    var src: Io.Reader = .fixed("<doc><p>Hello</p><p>wor<b>ld</b></p></doc>");
    var diag: xml.Diagnostic = .{};
    var rd = xml.Reader.init(gpa, &src, .{}, &diag);
    defer rd.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    while (true) switch (try rd.next()) {
        .text => |t| try text.appendSlice(gpa, t), // borrowed: valid until the next call
        .end_element => |e| if (std.mem.eql(u8, e.name.local, "p")) try text.append(gpa, '\n'),
        .end_of_document => break,
        else => {},
    };
    try testing.expectEqualStrings("Hello\nworld\n", text.items);
}

test "build a tree and look things up by namespace" {
    const gpa = testing.allocator;
    const ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    var doc = try xml.Document.parse(gpa,
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body>
        \\</w:document>
    , .{ .trim_blank_text = true }, null);
    defer doc.deinit();

    const p = doc.root.childNs(ns, "body").?.childNs(ns, "p").?;
    const text = try p.textContent(gpa); // the caller owns the result
    defer gpa.free(text);
    try testing.expectEqualStrings("Hello", text);
}

test "write a tree back, with its comments" {
    const gpa = testing.allocator;
    const bytes = "<?xml version=\"1.0\"?>\n<!--top-->\n<!DOCTYPE a>\n<a><!--c--><?p d?><![CDATA[<x>]]><b></b><c/></a>\n";
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const out = &aw.writer;

    var doc = try xml.Document.parse(gpa, bytes, .{}, null);
    defer doc.deinit();
    // ... read or look things up ...
    try doc.write(gpa, out, .{}); // comments, processing instructions, CDATA, DOCTYPE and the declaration survive
    try testing.expectEqualStrings(bytes, aw.written());
}

test "report where a document is broken" {
    var diag: xml.Diagnostic = .{};
    const result = xml.Document.parse(testing.allocator, "<a>\n  <b>\n</a>", .{}, &diag);
    try testing.expectError(error.MismatchedTag, result);
    try testing.expectEqual(@as(u32, 3), diag.line); // diag.message says why
}

test "write a document" {
    const gpa = testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w = xml.Writer.init(gpa, &aw.writer, .{ .indent = 2 });
    defer w.deinit();
    try w.declaration();
    try w.start("catalog");
    try w.start("book");
    try w.attribute("id", "b1");
    try w.text("Fish & Chips");
    try w.end();
    try w.finish();
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<catalog>\n  <book id=\"b1\">Fish &amp; Chips</book>\n</catalog>\n",
        aw.written(),
    );
}
