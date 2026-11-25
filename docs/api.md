# Using xml-zig

The examples here are compiled and run by `zig build test` (`src/api_examples.zig`).

## Read events

```zig
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
```

Every event borrows its strings from the reader; copy what you keep. A start tag `<a/>` is followed by its end event, so you never have to handle empty elements separately. `Name` has `qualified` (`w:p`), `prefix`, `local` and `uri`; `name.is(uri, local)` compares the resolved name.

## Build a tree

```zig
var doc = try xml.Document.parse(gpa, bytes, .{ .trim_blank_text = true }, null);
defer doc.deinit();
const p = doc.root.childNs(ns, "body").?.childNs(ns, "p").?;
const text = try p.textContent(gpa); // you own the result
defer gpa.free(text);
```

`Options` (for `Document`): `keep_comments` (default true: comments and processing instructions are kept, inside the root and in `doc.prolog` / `doc.epilog`; CDATA sections stay CDATA nodes), `trim_blank_text` (drop whitespace-only text, except under `xml:space="preserve"`; a run is judged whole, and whitespace written as `&#32;` counts as whitespace), and `reader` for the reader's options.

## Write a tree back, with its comments

```zig
var doc = try xml.Document.parse(gpa, bytes, .{}, null);
defer doc.deinit();
// ... read or look things up ...
try doc.write(gpa, &out, .{});   // comments, processing instructions, CDATA, DOCTYPE and the declaration survive
```

What is normalized: quote style and spaces inside tags, how a character was written (`&#65;` comes back as `A`), and `<a></a>` versus `<a/>` is kept. Whitespace between elements is kept as text unless `trim_blank_text` was set; `WriteOptions.indent` re-indents elements that hold no text. A document already in the writer's own style comes back byte for byte.

## Errors

A failure returns an error and fills the `Diagnostic` you passed:

```zig
const result = xml.Document.parse(gpa, "<a>\n  <b>\n</a>", .{}, &diag);
// error.MismatchedTag, diag.line == 3, diag.message says why
```

## Limits for untrusted input

`Options` bounds `max_depth` (256), `max_name_bytes` (1024), `max_attributes` (256), `max_token_bytes` (16 MiB) and `max_input_bytes` (unlimited). Set `doctype = .reject` for formats that never have a DOCTYPE. Declared entities are never expanded.

## Write

```zig
var w = xml.Writer.init(gpa, &out, .{ .indent = 2 });
defer w.deinit();
try w.declaration();
try w.start("catalog");
try w.start("book");
try w.attribute("id", "b1");
try w.text("Fish & Chips");
try w.end();
try w.finish();
```

The writer escapes everything, rejects invalid names and characters, and indents only around elements that hold no text.
