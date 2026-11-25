# xml-zig — Specification

**Status:** 0.1.0, implemented and tested against cases drawn from the XML 1.0 (Fifth Edition) text and Namespaces in XML 1.0 (Third Edition); see "Known deviations".

## Purpose

A small, dependency-free XML parser and writer for Zig 0.17, written first for dksearch (reading `docx`/`odt` parts and other XML sources) but usable by any project. References: Extensible Markup Language (XML) 1.0 (Fifth Edition), https://www.w3.org/TR/xml/ ; Namespaces in XML 1.0 (Third Edition), https://www.w3.org/TR/xml-names/ .

## Requirements

- **XML-1 (MUST):** Accept every well-formed XML 1.0 document that is UTF-8, US-ASCII, UTF-16 (with or without a byte order mark) or ISO-8859-1, and whose only entities are the five predefined ones, character references and any the caller supplies in `Options.entities`: elements, attributes, text, CDATA sections, comments, processing instructions, the XML declaration, and a DOCTYPE (read and reported, not acted on).
- **XML-2 (MUST):** Refuse documents that are not well-formed, with a specific error and the 1-based line and column (in bytes) of the fault: mismatched or unclosed tags, no or several root elements, text outside the root, duplicate attributes, unquoted or `<`-containing attribute values, illegal names, characters outside `Char` (production 2), invalid UTF-8, `]]>` in text, `--` in comments, bad references, a misplaced XML declaration.
- **XML-3 (MUST):** Namespaces: resolve prefixes through nested scopes (`xmlns`, `xmlns:p`, `xmlns=""`), the reserved `xml` prefix, per-element and per-attribute URIs; an undeclared prefix, a duplicate expanded attribute name, or an empty prefix binding is an error. `Options.namespaces = false` treats prefixes as ordinary name characters.
- **XML-4 (MUST):** Treat input as untrusted: bounded depth (`max_depth`, default 256), name length, attribute count, namespace declarations in scope, token size (default 16 MiB), the bytes of one start tag and of the namespace names in scope and total input (`max_input_bytes`); no recursion in the parser; no undefined behaviour on malformed bytes. Random and mutated inputs are tested.
- **XML-5 (MUST):** No entity expansion, no external resources: declared entities are skipped and a reference to one is `error.UndefinedEntity`. `Options.doctype = .reject` refuses any DOCTYPE.
- **XML-6 (MUST):** Use `std.Io` for all input and output: pull events from a `*std.Io.Reader` with one byte of lookahead, write to a `*std.Io.Writer`; no file-system or OS calls in the library. Tested with one-byte and failing readers and a one-byte buffer.
- **XML-7 (MUST):** Line ends (`\r\n`, `\r`) are normalized to `\n`; attribute values are whitespace-normalized as for CDATA attributes; a BOM is accepted; UTF-16 and ISO-8859-1 are converted to UTF-8 on the way in; a declared encoding that contradicts the detected one is refused.
- **XML-8 (MUST):** One owner: a `Document` owns an arena and `deinit` frees it; event data is borrowed until the next call. No leaks on error or allocation failure (tested with `FailingAllocator`).
- **XML-11 (MUST):** Comments survive: the tree keeps comments and processing instructions inside the root and before and after it, the DOCTYPE and the XML declaration, CDATA sections and empty-element form; `Document.write` writes them back, and `write(parse(x))` parses back to the same tree (tested; a document in the writer's own style is identical byte for byte). `Options.keep_comments = false` drops comments and processing instructions; the DOCTYPE and declaration are always kept.
- **XML-9 (MUST):** A writer that escapes text and attribute values, rejects invalid names, characters and content, tracks open elements so `end` always matches, and produces output that parses back to the same tree.
- **XML-10 (SHOULD):** No dependencies beyond the Zig standard library. Met.

## API summary

```zig
const xml = @import("xml");
var rd = xml.Reader.init(gpa, &src, options, &diag); defer rd.deinit();
const ev = try rd.next();          // .start_element / .end_element / .text / .cdata / .comment /
                                   // .processing_instruction / .doctype / .xml_decl / .end_of_document
var doc = try xml.Document.parse(gpa, bytes, .{}, &diag); defer doc.deinit();
try doc.write(gpa, &out, .{});       // the whole tree back, comments included
doc.root.child("name"), .childNs(ns, local), .attr("a"), .attrNs(ns, local), .textContent(gpa), .elements()
var w = xml.Writer.init(gpa, &out, .{ .indent = 2 }); defer w.deinit();
try w.declaration(); try w.start("a"); try w.attribute("k", "v"); try w.text("t"); try w.end(); try w.finish();
```

## Known deviations and limits

- UTF-16 with neither a byte order mark nor an encoding declaration is read (it is recognised by its first bytes). XML 1.0 section 4.3.3 makes this a fatal error; accepting it is a deliberate leniency (XML-1).
- Input encodings: UTF-8, US-ASCII, UTF-16 and ISO-8859-1. Any other (Shift_JIS, EUC-JP, UTF-32, windows-1252 and so on) is `error.UnsupportedEncoding`.
- Only XML 1.0 (any `1.n` except `1.1` is read with 1.0 rules, as the fifth edition allows); a declaration of version 1.1 is `error.UnsupportedVersion`.
- DTDs are not interpreted: no declared entities (use `Options.entities` to supply names yourself), no default attribute values, no attribute-type normalization (tokenized attributes are not trimmed), no validation. A document that depends on them is refused (undefined entity) or read without those effects.
- The Namespaces constraints that depend on URI syntax are not checked (a namespace name is any non-empty string).
- The tree is read-only: there are no setters yet (the arena holds an immutable tree). Editing means building a new tree or writing with `Writer`.
- A text run or attribute value is held in memory whole (bounded by `max_token_bytes`); the tree keeps the whole document.
- Conformance: the W3C XML Conformance Test Suite (xmlts20130923, fetched by `scripts/fetch-conformance.sh`, not vendored) is run by `zig build conformance -Dsuite=DIR/xmlconf`. Result: 1487 pass, 0 fail; 83 valid documents use entities they declare or import and 404 not-well-formed ones are faulty only inside a DTD (both follow from "DTDs are not interpreted"); 338 are XML 1.1 or fifth-edition-excluded cases and are skipped. The cases in `src/tests.zig` come from the specification text and from failures the suite found.
- Parsing is single-threaded; documents are not safe for concurrent mutation.

## Measurements

`xml-parse check` (ReleaseFast, 12-core machine) reads a 100 MB sample of a Wikipedia dump in about 0.3 s CPU, 1.1x the time Python's expat binding took on the same file with no callbacks. The streaming reader holds only the current token.

## Testing

`zig build test`: well-formed and not-well-formed cases by production, namespace scoping, limits, line ends and positions, short and failing reads, tiny buffers, random and mutated input, allocation-failure injection, writer round trips, and the examples in `docs/api.md`.
