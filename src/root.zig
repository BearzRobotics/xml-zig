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

pub const Reader = reader.Reader;
pub const Event = reader.Event;
pub const Name = reader.Name;
pub const Attribute = reader.Attribute;
pub const Decl = reader.Decl;
pub const Options = reader.Options;
pub const DoctypeMode = reader.DoctypeMode;
pub const Diagnostic = reader.Diagnostic;
pub const Error = reader.Error;
pub const xml_namespace = reader.xml_namespace;
pub const xmlns_namespace = reader.xmlns_namespace;

test {
    _ = reader;
    _ = chars;
}
