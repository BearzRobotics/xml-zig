//! Character classes of XML 1.0 (Fifth Edition), https://www.w3.org/TR/xml/ :
//! `Char` (section 2.2) and `NameStartChar` / `NameChar` (section 2.3).

const std = @import("std");

/// Production [2] Char: the code points a document may contain.
pub fn isChar(cp: u21) bool {
    return switch (cp) {
        0x9, 0xA, 0xD => true,
        0x20...0xD7FF => true,
        0xE000...0xFFFD => true,
        0x10000...0x10FFFF => true,
        else => false,
    };
}

/// Production [4] NameStartChar.
pub fn isNameStart(cp: u21) bool {
    return switch (cp) {
        ':', 'A'...'Z', '_', 'a'...'z' => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF => true,
        0x370...0x37D, 0x37F...0x1FFF => true,
        0x200C...0x200D, 0x2070...0x218F, 0x2C00...0x2FEF => true,
        0x3001...0xD7FF, 0xF900...0xFDCF, 0xFDF0...0xFFFD => true,
        0x10000...0xEFFFF => true,
        else => false,
    };
}

/// Production [4a] NameChar.
pub fn isNameChar(cp: u21) bool {
    if (isNameStart(cp)) return true;
    return switch (cp) {
        '-', '.', '0'...'9', 0xB7, 0x300...0x36F, 0x203F...0x2040 => true,
        else => false,
    };
}

pub fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// True if `s` is valid UTF-8 made only of XML `Char`s.
pub fn validText(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (!isChar(b)) return false;
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch return false;
        if (i + n > s.len) return false;
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return false;
        if (!isChar(cp)) return false;
        i += n;
    }
    return true;
}

/// True if `s` is an XML `Name` (production [5]). Namespace prefixes with
/// a colon are allowed here; `splitQName` handles them.
pub fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        const b = s[i];
        var cp: u21 = b;
        var n: usize = 1;
        if (b >= 0x80) {
            n = std.unicode.utf8ByteSequenceLength(b) catch return false;
            if (i + n > s.len) return false;
            cp = std.unicode.utf8Decode(s[i .. i + n]) catch return false;
        }
        if (first) {
            if (!isNameStart(cp)) return false;
        } else if (!isNameChar(cp)) return false;
        first = false;
        i += n;
    }
    return true;
}

const testing = std.testing;

test "name characters" {
    try testing.expect(isName("a"));
    try testing.expect(isName("_x-1.2"));
    try testing.expect(isName("w:p"));
    try testing.expect(isName("é"));
    try testing.expect(isName("日本語"));
    try testing.expect(!isName(""));
    try testing.expect(!isName("1a"));
    try testing.expect(!isName("-a"));
    try testing.expect(!isName("a b"));
    try testing.expect(!isName("a<b"));
    try testing.expect(!isName("\xff"));
}

test "characters" {
    try testing.expect(validText("plain\ttext\n"));
    try testing.expect(validText("héllo 日本 \u{10000}"));
    try testing.expect(!validText("a\x01b"));
    try testing.expect(!validText("a\x00b"));
    try testing.expect(!validText("\xEF\xBF\xBE")); // U+FFFE
    try testing.expect(!validText("\xC0\x80")); // overlong
    try testing.expect(!validText("\xED\xA0\x80")); // surrogate
}
