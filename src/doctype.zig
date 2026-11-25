//! The syntax of a DOCTYPE declaration itself: production [28] of XML 1.0 (Fifth Edition),
//! https://www.w3.org/TR/xml/#NT-doctypedecl . The declarations inside the internal subset are
//! not interpreted: only as much of them is read as it takes to find where the subset ends.
//! The reader uses this to check what it read, and the writer to check what it is given.

const std = @import("std");
const chars = @import("chars.zig");

pub const Fault = struct {
    /// Byte offset into the text that was checked.
    at: usize,
    message: []const u8,
};

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn space(c: *Cursor) bool {
        const from = c.i;
        while (c.i < c.s.len and chars.isSpace(c.s[c.i])) c.i += 1;
        return c.i > from;
    }

    fn eat(c: *Cursor, want: []const u8) bool {
        if (!std.mem.startsWith(u8, c.s[c.i..], want)) return false;
        c.i += want.len;
        return true;
    }

    /// Everything up to the next space, `[` or quote.
    fn word(c: *Cursor) []const u8 {
        const from = c.i;
        while (c.i < c.s.len and !chars.isSpace(c.s[c.i])) : (c.i += 1) switch (c.s[c.i]) {
            '[', ']', '"', '\'', '<', '>' => break,
            else => {},
        };
        return c.s[from..c.i];
    }

    /// A quoted literal; returns what is between the quotes.
    fn literal(c: *Cursor) ?[]const u8 {
        if (c.i >= c.s.len or (c.s[c.i] != '"' and c.s[c.i] != '\'')) return null;
        const end = std.mem.indexOfScalarPos(u8, c.s, c.i + 1, c.s[c.i]) orelse return null;
        defer c.i = end + 1;
        return c.s[c.i + 1 .. end];
    }
};

/// Production [13] PubidChar.
fn isPubidChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, " \r\n-'()+,./:=?;!*#@$_%", b) != null;
}

/// Checks `s`, the text between `<!DOCTYPE` plus its whitespace and the closing `>`:
/// `Name (S ExternalID)? S? ('[' intSubset ']' S?)?`. Leading whitespace is allowed.
/// Returns null when it is well formed. Characters are not checked here (`chars.validText`).
pub fn check(s: []const u8) ?Fault {
    var c: Cursor = .{ .s = s };
    _ = c.space();
    const name_at = c.i;
    if (!chars.isName(c.word())) return .{ .at = name_at, .message = "a DOCTYPE needs the name of the root element" };

    var spaced = c.space();
    const keyword_at = c.i;
    const public = c.eat("PUBLIC");
    if (public or c.eat("SYSTEM")) {
        if (!spaced) return .{ .at = keyword_at, .message = "whitespace is needed before the external identifier" };
        if (!c.space()) return .{ .at = c.i, .message = "whitespace is needed after SYSTEM or PUBLIC" };
        if (public) {
            const at = c.i;
            const id = c.literal() orelse return .{ .at = at, .message = "PUBLIC needs a quoted public identifier" };
            for (id) |b| if (!isPubidChar(b)) return .{ .at = at, .message = "a character that a public identifier cannot hold" };
            if (!c.space()) return .{ .at = c.i, .message = "whitespace is needed after the public identifier" };
        }
        if (c.literal() == null) return .{ .at = c.i, .message = "the external identifier needs a quoted system literal" };
        spaced = c.space();
    }

    if (c.eat("[")) {
        if (subset(&c)) |fault| return fault;
        _ = c.space();
    }
    if (c.i < c.s.len) return .{ .at = c.i, .message = "unexpected text in the DOCTYPE" };
    return null;
}

/// Moves past the internal subset and the `]` that closes it.
fn subset(c: *Cursor) ?Fault {
    var brackets: usize = 0;
    var in_declaration = false;
    while (c.i < c.s.len) {
        const at = c.i;
        if (c.eat("<!--")) {
            // `--` may only be the start of `-->` (production [15]).
            const end = std.mem.indexOfPos(u8, c.s, c.i, "--") orelse return .{ .at = at, .message = "an unclosed comment in the DOCTYPE" };
            c.i = end + 2;
            if (!c.eat(">")) return .{ .at = end, .message = "-- is not allowed inside a comment" };
        } else if (c.eat("<?")) {
            const end = std.mem.indexOfPos(u8, c.s, c.i, "?>") orelse return .{ .at = at, .message = "an unclosed processing instruction in the DOCTYPE" };
            c.i = end + 2;
        } else if (c.s[c.i] == '"' or c.s[c.i] == '\'') {
            if (c.literal() == null) return .{ .at = at, .message = "an unclosed quoted string in the DOCTYPE" };
        } else {
            c.i += 1;
            switch (c.s[at]) {
                '<' => in_declaration = true,
                '>' => {
                    if (!in_declaration) return .{ .at = at, .message = "unexpected > in the internal subset" };
                    in_declaration = false;
                },
                '[' => brackets += 1,
                ']' => {
                    if (brackets == 0) return null;
                    brackets -= 1;
                },
                else => {},
            }
        }
    }
    return .{ .at = c.i, .message = "the internal subset is not closed" };
}

const testing = std.testing;

test "well-formed DOCTYPE declarations" {
    for ([_][]const u8{
        "a",
        "  a  ",
        "a:b",
        "a SYSTEM \"a.dtd\"",
        "a SYSTEM 'it\"s.dtd' ",
        "a PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"x.dtd\"",
        "a[]",
        "a []",
        "a SYSTEM 'x'[ <!ELEMENT a ANY> ] ",
        "a [ <!ENTITY % p \"]>\"> %p; <!-- ]> ' --> <?pi ]> ' ?> ]",
    }) |s| {
        errdefer std.debug.print("rejected: {s}\n", .{s});
        try testing.expectEqual(@as(?Fault, null), check(s));
    }
}

test "malformed DOCTYPE declarations" {
    for ([_][]const u8{
        "",
        "   ",
        "1a",
        "\"a\"",
        "[ ]",
        "a b",
        "a -- comment -- []",
        "a SYSTEM",
        "a SYSTEM x",
        "a SYSTEM\"x\"",
        "a SYSTEM \"x",
        "a SYSTEM \"x\" \"y\"",
        "a PUBLIC \"x\"",
        "a PUBLIC \"x\"\"y\"",
        "a PUBLIC \"[x]\" \"y\"",
        "SYSTEM \"x.dtd\"",
        "SYSTEM \"x.dtd\" a [ ]",
        "a [",
        "a ] ",
        "a [ ] junk",
        "a [ ] []",
        "a [ ] %e; ",
        "a [ <!-- a -- b --> ]",
        "a [ <!-- a ---> ]",
        "a [ <!-- ]",
        "a [ <? ]",
        "a [ \" ]",
        "a [ > ]",
        "a><evil/",
        "a><evil attr='1'/><!--",
        "a>",
    }) |s| {
        errdefer std.debug.print("accepted: {s}\n", .{s});
        try testing.expect(check(s) != null);
    }
}
