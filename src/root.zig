//! xml-zig: an XML 1.0 parser and writer for Zig, built on `std.Io`.
//!
//! ```zig
//! // Streaming: one event at a time, bounded memory.
//! var rd = xml.Reader.init(gpa, &file_reader.interface, .{}, &diag);
//! defer rd.deinit();
//! while (true) switch (try rd.next()) {
//!     .start_element => |e| std.debug.print("<{s}>\n", .{e.name.local}),
//!     .end_of_document => break,
//!     else => {},
//! };
//! ```

pub const reader = @import("reader.zig");
pub const chars = @import("chars.zig");
pub const dom = @import("dom.zig");
pub const writer = @import("writer.zig");

pub const Reader = reader.Reader;
pub const Event = reader.Event;
pub const Name = reader.Name;
pub const Attribute = reader.Attribute;
pub const Decl = reader.Decl;
pub const Options = reader.Options;
pub const DoctypeMode = reader.DoctypeMode;
pub const Entity = reader.Entity;
pub const Diagnostic = reader.Diagnostic;
pub const Error = reader.Error;
pub const Writer = writer.Writer;
pub const WriterOptions = writer.Options;
pub const WriteError = writer.Error;
pub const Document = dom.Document;
pub const Element = dom.Element;
pub const Node = dom.Node;
pub const xml_namespace = reader.xml_namespace;
pub const xmlns_namespace = reader.xmlns_namespace;

test {
    _ = reader;
    _ = chars;
    _ = @import("doctype.zig");
    _ = dom;
    _ = writer;
    _ = @import("tests.zig");
    _ = @import("property_tests.zig");
    _ = @import("api_examples.zig");
}
