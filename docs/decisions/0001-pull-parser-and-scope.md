# 0001: A pull parser, no DTD processing

Status: implemented in 0.1.0.

## Problem

dksearch reads XML from several places: Wikipedia dumps (tens of gigabytes, one
long document), office documents (`docx` and `odt` are zip files of small XML
parts), feeds. It uses the C library Expat for the Wikipedia dump today. A
Zig library of our own removes the C dependency and lets the same code read
all of them, as `toml-zig` and `regex-zig` do for their formats.

## Decision

1. **A pull parser over `std.Io.Reader`.** `Reader.next()` returns one event
   at a time and holds only the current token, so a 30 GB dump needs no more
   memory than a 1 KB file. A push (callback) parser was the alternative: it
   would not need the borrowed-until-next-call rule but forces the caller into
   inverted control. A tree builder (`Document`) is layered on the reader for
   documents that fit in memory.
2. **One byte of lookahead.** The parser never peeks more than one byte, so it
   works with any `std.Io.Reader`, including one with a one-byte buffer.
3. **No DTD processing.** Declared entities are skipped and a reference to one is an error (unless the caller
   supplies it in `Options.entities`, which is safe: the caller chooses the text, nothing recurses), external
   subsets are never fetched, and nothing is validated. This removes the whole family of
   entity-expansion ("billion laughs") and external-entity attacks instead of limiting them, and
   it costs the documents that rely on declared entities. Wikipedia dumps, `docx`, `odt`, RSS and Atom do not.
4. **UTF-8 inside, UTF-8, UTF-16 and ISO-8859-1 outside.** The parser works on UTF-8 bytes. UTF-16 and
   ISO-8859-1 documents are converted as they are read (a small decoder behind `peek`/`take`, detected from the
   byte order mark, the first bytes, or the declaration), so the parser itself does not change. Other
   encodings are refused with a clear error rather than mishandled.
5. **Namespaces by default.** Office formats are defined by namespace URIs, not prefixes, so the reader
   resolves them (and `Options.namespaces = false` turns it off).

## Consequences

- The reader is a single file and has no state beyond the current token and the open elements (their names and namespace declarations).
- Speed is close to Expat's on a 100 MB sample (see `ai/SPEC.md`), measured, not assumed.
- Conformance is checked against cases written from the specification and, since 0.1.0, the W3C suite (see `ai/SPEC.md`).

## References

- XML 1.0 (Fifth Edition), https://www.w3.org/TR/xml/ — sections 2.2 (Char), 2.3 (Names), 2.4–2.7, 2.8 (prolog), 3 (logical structures), 4.1 (references).
- Namespaces in XML 1.0 (Third Edition), https://www.w3.org/TR/xml-names/ .
