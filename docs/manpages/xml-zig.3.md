% XML-ZIG(3) Version 0.1.0 | xml-zig Manual
% Dakota James Owen Keeler
% 2026-11-16

NAME
xml-zig - XML 1.0 parser and writer for Zig

SYNOPSIS
const xml = @import("xml");

DESCRIPTION
A streaming XML parser built on `std.Io`, a small tree (`Document`) built on top of it, and a writer. No dependencies. See `docs/api.md` for worked examples and `ai/SPEC.md` for the requirements and known deviations.

READER
`Reader.init(gpa, *std.Io.Reader, Options, ?*Diagnostic)`, `Reader.next() !Event`, `Reader.deinit()`, `Reader.depth()`.

Events: `xml_decl` (version, encoding, standalone), `start_element` (name, attributes, empty), `end_element` (name), `text`, `cdata`, `comment`, `processing_instruction` (target, data), `doctype`, `end_of_document`. Strings are borrowed until the next call to `next`.

Options: `namespaces` (true), `doctype` (`.skip` or `.reject`), `max_depth` (256), `max_name_bytes` (1024), `max_attributes` (256), `max_token_bytes` (16 MiB), `max_input_bytes` (0 = unlimited).

Errors: `InvalidSyntax`, `InvalidName`, `InvalidCharacter`, `UnexpectedEof`, `MismatchedTag`, `DuplicateAttribute`, `UndefinedEntity`, `InvalidCharacterReference`, `UnboundPrefix`, `UnsupportedEncoding`, `UnsupportedVersion`, `DoctypeNotAllowed`, `LimitExceeded`, `ReadFailed`, `OutOfMemory`. `Diagnostic` holds `line`, `column` and `message`.

DOCUMENT
`Document.parse(gpa, bytes, Options, ?*Diagnostic)`, `Document.parseReader(gpa, *std.Io.Reader, ...)`, `Document.deinit()`. `Document.root` is an `*Element` with `name`, `attributes`, `children` and the methods `attr`, `attrNs`, `child`, `childNs`, `elements`, `appendText`, `textContent`.

WRITER
`Writer.init(gpa, *std.Io.Writer, Options)`; `declaration`, `start`, `attribute`, `text`, `cdata`, `comment`, `end`, `finish`, `deinit`. `Options.indent` is spaces per level (0 = none).

CONFORMING TO
XML 1.0 (Fifth Edition) and Namespaces in XML 1.0 (Third Edition), with the deviations listed in `ai/SPEC.md`.

SEE ALSO
xml-parse(1)
