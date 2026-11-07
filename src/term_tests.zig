//! Tests of the terminal renderer.

const std = @import("std");
const md = @import("root.zig");
const testing = std.testing;

fn text(gpa: std.mem.Allocator, src: []const u8, ext: md.Extensions, o: md.TextOptions) ![]u8 {
    var doc = try md.Document.parse(gpa, src, .{ .extensions = ext });
    defer doc.deinit();
    return doc.toTextAlloc(gpa, o);
}

test "paragraphs wrap at the width and keep markers without colour" {
    const gpa = testing.allocator;
    const out = try text(gpa, "A *quick* brown **fox** jumps over the lazy dog.\n", .{}, .{ .width = 24, .unicode = false });
    defer gpa.free(out);
    try testing.expectEqualStrings("A _quick_ brown **fox**\njumps over the lazy dog.\n", out);
}

test "lists, quotes and code are indented" {
    const gpa = testing.allocator;
    const src = "# Title\n\n- one\n- two\n  1. nested\n\n> quoted\n\n    code\n";
    const out = try text(gpa, src, .{}, .{ .unicode = false });
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "# Title\n\n- one\n- two\n  1. nested\n\n> quoted\n\n    code\n",
        out,
    );
}

test "tables are aligned and wide characters count as two columns" {
    const gpa = testing.allocator;
    const out = try text(gpa, "| a | 日本 |\n|:-:|--:|\n| bb | x |\n", md.Extensions.gfm, .{ .unicode = false });
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "+----+------+\n" ++
            "| a  | 日本 |\n" ++
            "+----+------+\n" ++
            "| bb |    x |\n" ++
            "+----+------+\n",
        out,
    );
}

test "colour output is reset at the end of every line" {
    const gpa = testing.allocator;
    const out = try text(gpa, "**bold** text\n", .{}, .{ .color = true });
    defer gpa.free(out);
    try testing.expectEqualStrings("\x1b[0m\x1b[1mbold\x1b[0m text\x1b[0m\n", out);
}

test "links show their address; footnotes are numbered at the end" {
    const gpa = testing.allocator;
    const out = try text(gpa, "See [docs](https://x.org/d) and a note[^a].\n\n[^a]: The note.\n", md.Extensions.all, .{ .unicode = false });
    defer gpa.free(out);
    try testing.expectEqualStrings("See docs <https://x.org/d> and a note[1].\n\n--------------------\n[1] The note.\n", out);
}

test "very deep nesting is cut off, not a stack overflow" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..5000) |_| try src.append(gpa, '>');
    try src.appendSlice(gpa, " x\n");
    const out = try text(gpa, src.items, .{}, .{});
    defer gpa.free(out);
    try testing.expect(out.len > 0);
}

test "a table wider than the terminal wraps inside its cells" {
    const gpa = testing.allocator;
    const out = try text(gpa, "| Key | Meaning |\n|---|---|\n| a | one two three four five six seven eight |\n", md.Extensions.gfm, .{ .width = 24, .unicode = false });
    defer gpa.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| try testing.expect(line.len <= 24);
    try testing.expect(std.mem.find(u8, out, "one two") != null);
    try testing.expect(std.mem.find(u8, out, "eight") != null);
}

test "words that touch are not split across lines" {
    const gpa = std.testing.allocator;
    var doc = try md.Document.parse(gpa, "aaaa bbbb (`cc`) dd\n", .{});
    defer doc.deinit();
    // Width 12: "aaaa bbbb" fits, "(`cc`)" does not fit on the same line, and
    // the closing parenthesis must stay with `cc`.
    const out = try doc.toTextAlloc(gpa, .{ .width = 12 });
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\n)") == null);
    try std.testing.expect(std.mem.find(u8, out, "(`cc`)") != null);
}
