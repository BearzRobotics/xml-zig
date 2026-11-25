# xml-zig — Specification

**Status:** 0.2.0, implemented and tested against cases drawn from the XML 1.0 (Fifth Edition) text and Namespaces in XML 1.0 (Third Edition) and against the W3C conformance suite; see "Known deviations".

## Purpose

A small, dependency-free XML parser and writer for Zig 0.17, written first for dksearch (reading `docx`/`odt` parts and other XML sources) but usable by any project. References: Extensible Markup Language (XML) 1.0 (Fifth Edition), https://www.w3.org/TR/xml/ ; Namespaces in XML 1.0 (Third Edition), https://www.w3.org/TR/xml-names/ .

## Requirements

- **XML-1 (MUST):** Accept every well-formed XML 1.0 document that is UTF-8, US-ASCII, UTF-16 (with or without a byte order mark) or ISO-8859-1, and whose only entities are the five predefined ones, character references and any the caller supplies in `Options.entities`: elements, attributes, text, CDATA sections, comments, processing instructions, the XML declaration, and a DOCTYPE (read and reported, not acted on).
- **XML-2 (MUST):** Refuse documents that are not well-formed, with a specific error and the 1-based line and column (in bytes) of the fault: mismatched or unclosed tags, no or several root elements, text outside the root, duplicate attributes, unquoted or `<`-containing attribute values, illegal names, characters outside `Char` (production 2), invalid UTF-8, `]]>` in text, `--` in comments, bad references, a misplaced XML declaration.
- **XML-3 (MUST):** Namespaces: resolve prefixes through nested scopes (`xmlns`, `xmlns:p`, `xmlns=""`), the reserved `xml` prefix, per-element and per-attribute URIs; an undeclared prefix, a duplicate expanded attribute name, an empty prefix binding, an element name with the prefix `xmlns`, or a name that is not a QName is an error. `Options.namespaces = false` treats prefixes as ordinary name characters (`local` is the whole name, `prefix` is empty).
- **XML-4 (MUST):** Treat input as untrusted: bounded depth (`max_depth`, default 256), name length, attribute count, namespace declarations in scope, token size (default 16 MiB), the bytes of one start tag, the bytes of the namespace names in scope, and total input counted on the source bytes (`max_input_bytes`); no recursion in the parser or in the tree walks; no undefined behaviour on malformed bytes, on input of any length, or on calls after an error (errors are sticky). Generated, damaged and random inputs are tested.
- **XML-5 (MUST):** No entity expansion, no external resources: declared entities are skipped and a reference to one is `error.UndefinedEntity`. `Options.doctype = .reject` refuses any DOCTYPE.
- **XML-6 (MUST):** Use `std.Io` for all input and output: pull events from a `*std.Io.Reader` with one byte of lookahead, write to a `*std.Io.Writer`; no file-system or OS calls in the library. Tested by comparing every event across chunk sizes, buffer sizes from none upwards and every encoding, and with failing readers.
- **XML-7 (MUST):** Line ends (`\r\n`, `\r`) are normalized to `\n`; attribute values are whitespace-normalized as for CDATA attributes; a BOM is accepted; UTF-16 and ISO-8859-1 are converted to UTF-8 on the way in; a declared encoding that contradicts the detected one is refused.
- **XML-8 (MUST):** One owner: a `Document` owns an arena and `deinit` frees it; event data is borrowed until the next call. No leaks on error or allocation failure, and a writer stays usable after one (every allocation of the reader, the tree's parse and write, and the writer is made to fail in turn).
- **XML-11 (MUST):** Comments survive: the tree keeps comments and processing instructions inside the root and before and after it, the DOCTYPE and the XML declaration, CDATA sections and empty-element form; `Document.write` writes them back, and `write(parse(x))` parses back to the same tree (tested; a document in the writer's own style is identical byte for byte). `Options.keep_comments = false` drops comments and processing instructions; the DOCTYPE and declaration are always kept.
- **XML-9 (MUST):** A writer that escapes text and attribute values, rejects invalid names, characters and content (including what would silently change on reading, repeated attributes, a malformed DOCTYPE or an out-of-order prolog), holds names to the namespace rules unless `namespaces = false`, never adds indentation to text content, tracks open elements so `end` always matches, and produces output that a reader with the same `namespaces` setting parses back to the same tree. Not checked: the writer applies no size limits, so output can exceed a reader's.
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

- `Document` `trim_blank_text` treats whitespace written as a reference (`&#32;`) like any other whitespace.
- UTF-16 with neither a byte order mark nor an encoding declaration is read (it is recognised by its first bytes). XML 1.0 section 4.3.3 makes this a fatal error; accepting it is a deliberate leniency (XML-1).
- Input encodings: UTF-8, US-ASCII, UTF-16 and ISO-8859-1. Any other (Shift_JIS, EUC-JP, UTF-32, windows-1252 and so on) is `error.UnsupportedEncoding`.
- Only XML 1.0 (any `1.n` except `1.1` is read with 1.0 rules, as the fifth edition allows); a declaration of version 1.1 is `error.UnsupportedVersion`.
- DTDs are not interpreted: no declared entities (use `Options.entities` to supply names yourself), no default attribute values, no attribute-type normalization (tokenized attributes are not trimmed), no validation. A document that depends on them is refused (undefined entity) or read without those effects.
- The Namespaces constraints that depend on URI syntax are not checked (a namespace name is any non-empty string).
- The tree is read-only: there are no setters yet (the arena holds an immutable tree). Editing means building a new tree or writing with `Writer`.
- A text run or attribute value is held in memory whole (bounded by `max_token_bytes`); the tree keeps the whole document.
- Conformance: the W3C XML Conformance Test Suite (xmlts20130923, fetched by `scripts/fetch-conformance.sh`, not vendored) is run by `zig build conformance -Dsuite=DIR/xmlconf`. For each valid document it checks acceptance, the suite's canonical output where there is one, and that `Document.write` preserves the document; each not-well-formed one must be refused (for any reason: 99 are refused for an unknown entity or an encoding, which may not be the fault under test, and the runner pins that number). Result: 1445 pass, 0 fail, 338 skipped (XML 1.1 and fifth-edition-excluded cases). 529 more fall short because DTDs are not interpreted, and are listed one by one in `bench/conformance_excused.txt`, whose header says how they were checked: 83 valid documents use entities they declare or import, 58 valid documents give other output than a DTD-processing parser would, and 388 not-well-formed ones are accepted because their fault is in, or depends on, the DTD. The cases in `src/tests.zig` come from the specification text and from failures the suite found.
- Parsing is single-threaded; documents are not safe for concurrent mutation.

## Measurements

`xml-parse check`, ReleaseFast, on a generated 106 MB document of small elements with mostly ASCII text, best of 7 on one 12-core machine (2026-11-24): 0.47 s (0.62 s for 0.1.0). The streaming reader holds only the current token and the open elements' names and namespace declarations. For 0.1.0, a 100 MB sample of a Wikipedia dump took about 0.3 s CPU, 1.1x the time of Python's expat binding with no callbacks; that comparison has not been repeated.

## Testing

`zig build test`: well-formed and not-well-formed cases by production, exact error positions, namespace scoping, limits, whole events compared across chunk sizes, buffer sizes and encodings, failing reads, allocation-failure injection, generated, damaged and random documents (everything accepted must write back as the same tree, plain and indented), writer refusals and round trips, the examples in `docs/api.md`, and the `xml-parse` command line (`tests/cli.sh`, needs a POSIX shell). It also compiles the conformance runner; `zig build conformance` runs it.
