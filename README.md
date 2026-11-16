# xml-zig

XML 1.0 parser and writer for Zig 0.17, with no dependencies. It reads from any `std.Io.Reader` one event at a time and never needs the whole input in memory; a small in-memory tree is built on top for documents that fit (office-document parts, configuration). It writes to any `std.Io.Writer`. See `ai/SPEC.md` for requirements and known deviations (entities are not expanded, only UTF-8 input).

```zig
// build.zig.zon: .xml = .{ .path = "../xml-zig" }
// build.zig:     exe.root_module.addImport("xml", b.dependency("xml", .{}).module("xml"));

// Streaming: events borrow their data until the next call.
var diag: xml.Diagnostic = .{};
var rd = xml.Reader.init(gpa, &reader.interface, .{}, &diag);
defer rd.deinit();
while (true) switch (try rd.next()) {
    .start_element => |e| std.debug.print("<{s}> in {s}\n", .{ e.name.local, e.name.uri }),
    .text => |t| _ = t,
    .end_of_document => break,
    else => {},
};

// A tree, for documents that fit in memory:
var doc = try xml.Document.parse(gpa, bytes, .{}, &diag);
defer doc.deinit();
const body = doc.root.childNs(ns, "body");
```

- Checks well-formedness (matching tags, one root, unique attributes, legal names and characters, valid references), UTF-8, and namespace prefixes; errors carry a 1-based line and column.
- Safe on untrusted input: nesting depth, name length, attribute count, token size and total input are bounded (`Options`); external entities and DTDs are never fetched or expanded, so entity-expansion attacks do not apply; `.doctype = .reject` refuses a DOCTYPE outright.
- `docs/api.md` — a tutorial for reading, building trees and writing.
- `docs/manpages/` — `xml-zig(3)` (library reference) and `xml-parse(1)`. Render with `pandoc -s -t man FILE.md -o FILE`.
- `docs/decisions/` — design decisions.
- `zig build cli` — builds `zig-out/bin/xml-parse` (`check`, `events`, `text`).

`zig build test` runs the tests. License: MIT.
