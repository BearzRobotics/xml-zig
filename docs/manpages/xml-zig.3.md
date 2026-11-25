# NAME

xml-zig - XML 1.0 parser and writer for Zig

# SYNOPSIS

    const xml = @import("xml");

# DESCRIPTION

A streaming XML parser built on `std.Io`, a small tree (`Document`) built on top of it, and a writer. No dependencies. See `docs/api.md` for worked examples and `ai/SPEC.md` for the requirements and known deviations.

# READER

`Reader.init(gpa, *std.Io.Reader, Options, ?*Diagnostic)`, `Reader.next() !Event`, `Reader.deinit()`, `Reader.depth()`.

Events: `xml_decl` (version, encoding, standalone), `start_element` (name, attributes, empty), `end_element` (name), `text`, `cdata`, `comment`, `processing_instruction` (target, data), `doctype`, `end_of_document`. Strings are borrowed until the next call to `next`. After an error, `next` keeps returning that error.

Options: `entities` (extra `&name;` replacements supplied by the caller), `namespaces` (true), `doctype` (`.skip` or `.reject`), `max_depth` (256), `max_name_bytes` (1024), `max_attributes` (256), `max_namespace_bindings` (512), `max_token_bytes` (16 MiB), `max_tag_bytes` (32 MiB), `max_namespace_bytes` (1 MiB), `max_input_bytes` (0 = unlimited).

Errors: `InvalidSyntax`, `InvalidName`, `InvalidCharacter`, `UnexpectedEof`, `MismatchedTag`, `DuplicateAttribute`, `UndefinedEntity`, `InvalidCharacterReference`, `UnboundPrefix`, `UnsupportedEncoding` (anything but UTF-8, US-ASCII, UTF-16, ISO-8859-1), `UnsupportedVersion` (1.1), `DoctypeNotAllowed`, `LimitExceeded`, `ReadFailed`, `OutOfMemory`. `Diagnostic` holds `line` and `column` (`u64`, from 1, columns in bytes) of the fault, and `message`.

# DOCUMENT

`Document.parse(gpa, bytes, Options, ?*Diagnostic)`, `Document.parseReader(gpa, *std.Io.Reader, ...)`, `Document.write(gpa, *std.Io.Writer, WriteOptions)` (writes the tree back with its comments, processing instructions, CDATA, DOCTYPE and declaration), `Document.deinit()`. `Document.prolog` and `Document.epilog` hold what is outside the root; `Document.declaration` is the XML declaration. Options: `keep_comments` (true), `trim_blank_text` (honours `xml:space="preserve"`), `reader`. `Document.root` is an `*Element` with `name`, `attributes`, `children` and the methods `attr`, `attrNs`, `child`, `childNs`, `elements`, `appendText`, `textContent`.

# WRITER

`Writer.init(gpa, *std.Io.Writer, Options)`; `declaration`, `declarationWith`, `processingInstruction`, `doctype`, `lineBreak`, `mixedContent`, `start`, `attribute`, `text`, `cdata`, `comment`, `end`, `endExpanded`, `finish`, `deinit`. `Options.indent` is spaces per level (0 = none). `Options.namespaces` (true) holds names and `xmlns` declarations to Namespaces in XML; set it to false to write without namespace processing. `Document.write` follows the setting the document was read with (`Document.namespaces`).

Errors: `InvalidName`, `InvalidCharacter`, `InvalidState`, `InvalidContent`, `DuplicateAttribute`, `UnboundPrefix`, `WriteFailed`, `OutOfMemory`. A refused call writes nothing, so after `UnboundPrefix` the missing declaration can still be added.

# CONFORMING TO

XML 1.0 (Fifth Edition) and Namespaces in XML 1.0 (Third Edition), with the deviations listed in `ai/SPEC.md`.

# SEE ALSO

xml-parse(1)

