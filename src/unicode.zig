//! The Unicode classes CommonMark's emphasis rules need, case folding for link
//! labels, and UTF-8 helpers. The classes and folds are those of CommonMark
//! 0.31.2, from tables generated out of the Unicode Character Database
//! (`unicode_tables.zig`).

const std = @import("std");
const widths = @import("widths.zig");
const tables = @import("unicode_tables.zig");

pub fn isAsciiPunct(c: u8) bool {
    return (c >= 0x21 and c <= 0x2f) or (c >= 0x3a and c <= 0x40) or (c >= 0x5b and c <= 0x60) or (c >= 0x7b and c <= 0x7e);
}

/// "Unicode whitespace": category Zs, tab, line feed, form feed and carriage
/// return. (Line tabulation is not one of them.)
pub fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', 0x0c, '\r' => true,
        else => cp >= 0x80 and inRuns(&tables.space_separators, cp),
    };
}

/// "Unicode punctuation": general categories P and S.
pub fn isUnicodePunct(cp: u21) bool {
    if (cp < 0x80) return isAsciiPunct(@intCast(cp));
    return inRuns(&tables.punctuation, cp);
}

/// Whether `cp` lies in one of the ordered, separate runs of `runs`.
fn inRuns(runs: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = runs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < runs[mid][0]) {
            hi = mid;
        } else if (cp > runs[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// What the non-ASCII `cp` folds to (UTF-8, up to three code points), or null
/// when it folds to itself.
pub fn caseFold(cp: u21) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = tables.case_folds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const f = tables.case_folds[mid];
        if (cp < f.from) {
            hi = mid;
        } else if (cp > f.from) {
            lo = mid + 1;
        } else return f.to;
    }
    return null;
}

/// Decodes the code point that starts at `s[i]`. Invalid bytes decode as U+FFFD
/// of length 1.
pub fn decodeAt(s: []const u8, i: usize) struct { cp: u21, len: u3 } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + n > s.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = @intCast(n) };
}

/// The code point that ends just before `s[end]`.
pub fn decodeBefore(s: []const u8, end: usize) u21 {
    var start = end - 1;
    var back: usize = 0;
    while (start > 0 and back < 3 and (s[start] & 0xc0) == 0x80) : (back += 1) start -= 1;
    const d = decodeAt(s, start);
    if (start + d.len != end) return 0xfffd;
    return d.cp;
}

/// How many terminal columns a code point takes: 0 for combining marks and
/// zero-width characters (an approximation by ranges; there is no Unicode
/// database in the standard library), 2 for the wide and fullwidth characters
/// of Unicode's East Asian Width property (`widths.zig`), else 1.
pub fn displayWidth(cp: u21) usize {
    switch (cp) {
        0x0300...0x036f, 0x200b...0x200f, 0x2060...0x2064, 0xfe00...0xfe0f, 0x20d0...0x20ff => return 0,
        else => {},
    }
    return if (inRuns(&widths.wide, cp)) 2 else 1;
}

/// The columns a UTF-8 string takes in a terminal.
pub fn stringWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        w += displayWidth(d.cp);
        i += d.len;
    }
    return w;
}

test "display widths follow East Asian Width" {
    for ([_]u21{ 0x1100, 0x3042, 0x4e00, 0xff21, 0x1f600, 0x1f680, 0x2705, 0x2b50, 0x1f7e2, 0x1fa90, 0x20000 }) |cp| {
        try std.testing.expectEqual(@as(usize, 2), displayWidth(cp));
    }
    for ([_]u21{ 'a', 0xe9, 0x2192, 0x303f, 0xff61, 0x1f321, 0x10ffff }) |cp| {
        try std.testing.expectEqual(@as(usize, 1), displayWidth(cp));
    }
    try std.testing.expectEqual(@as(usize, 0), displayWidth(0x301));
    for (widths.wide[1..], widths.wide[0 .. widths.wide.len - 1]) |run, before| try std.testing.expect(run[0] > before[1] + 1);
}

test "punctuation and white space are the CommonMark classes" {
    for ([_]u21{ '!', 0xa1, 0xb6, 0x20ac, 0x2014, 0x2116, 0x1f600, 0x10100 }) |cp| try std.testing.expect(isUnicodePunct(cp));
    for ([_]u21{ 'a', 0xe9, 0xaa, 0x2070, 0x4e00 }) |cp| try std.testing.expect(!isUnicodePunct(cp));
    for ([_]u21{ ' ', '\t', '\n', 0x0c, '\r', 0xa0, 0x2000, 0x3000 }) |cp| try std.testing.expect(isUnicodeWhitespace(cp));
    for ([_]u21{ 0x0b, 0x200b, 0x2028, 0x85, 'a' }) |cp| try std.testing.expect(!isUnicodeWhitespace(cp));
}
