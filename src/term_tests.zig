//! Tests of the terminal renderer.

const std = @import("std");
const md = @import("root.zig");
const testing = std.testing;
const max_depth = md.term.max_depth;

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
    try src.appendSlice(gpa, " hidden\n\nafter\n");
    const out = try text(gpa, src.items, .{}, .{ .unicode = false });
    defer gpa.free(out);
    // `max_depth` quote bars, then an ellipsis in place of the rest.
    try testing.expectEqual(@as(usize, max_depth), std.mem.count(u8, out, ">"));
    try testing.expect(std.mem.find(u8, out, "\u{2026}") != null);
    try testing.expect(std.mem.find(u8, out, "hidden") == null);
    try testing.expect(std.mem.endsWith(u8, out, "\nafter\n"));
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
    var doc = try md.Document.parse(gpa, "aaaaaaaaaaaaaaaaaaa `cc`) dd\n", .{});
    defer doc.deinit();
    // Width 24: "aaaaaaaaaaaaaaaaaaa `cc`" would fit, but the closing parenthesis
    // touches the code span, so the whole "`cc`)" moves to the next line.
    const out = try doc.toTextAlloc(gpa, .{ .width = 24 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaa\n`cc`) dd\n", out);
}

fn hintedDeflist(gpa: std.mem.Allocator, padding: usize) !md.Document {
    var doc = try md.Document.parse(gpa, "term\n: definition text that is long enough to wrap around the line end\n\nlongterm-over\n: second\n", .{ .extensions = .{ .definition_lists = true } });
    errdefer doc.deinit();
    var n = doc.root.first_child;
    while (n) |x| : (n = x.next) {
        if (x.kind != .deflist) continue;
        var c = x.first_child;
        while (c) |y| : (c = y.next) if (y.kind == .deflist_def) {
            y.indent = @intCast(padding);
        };
    }
    return doc;
}

test "indent hint: a short term shares the line with its definition" {
    const gpa = std.testing.allocator;
    var doc = try hintedDeflist(gpa, 8);
    defer doc.deinit();
    const out = try doc.toTextAlloc(gpa, .{ .width = 30 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        "term    definition text that\n" ++
            "        is long enough to wrap\n" ++
            "        around the line end\n" ++
            "\n" ++
            "longterm-over\n" ++
            "        second\n",
        out,
    );
}

test "indent hint: without it the layout is the Markdown one" {
    const gpa = std.testing.allocator;
    var doc = try md.Document.parse(gpa, "term\n: def\n", .{ .extensions = .{ .definition_lists = true } });
    defer doc.deinit();
    const out = try doc.toTextAlloc(gpa, .{ .width = 30 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("term\n    def\n", out);
}

test "a quote with an indent hint is plain indentation" {
    const gpa = std.testing.allocator;
    var doc = try md.Document.parse(gpa, "> quoted\n", .{});
    defer doc.deinit();
    doc.root.first_child.?.indent = 4;
    const out = try doc.toTextAlloc(gpa, .{ .width = 30 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("    quoted\n", out);
}

test "code block indent hint: default, custom, flush" {
    const gpa = std.testing.allocator;
    var doc = try md.Document.parse(gpa, "```\nx\n```\n", .{});
    defer doc.deinit();
    const code = doc.root.first_child.?;
    const a = try doc.toTextAlloc(gpa, .{ .width = 30 });
    defer gpa.free(a);
    try std.testing.expectEqualStrings("    x\n", a);
    code.indent = 2;
    const b = try doc.toTextAlloc(gpa, .{ .width = 30 });
    defer gpa.free(b);
    try std.testing.expectEqualStrings("  x\n", b);
    code.indent = md.Node.flush;
    const c = try doc.toTextAlloc(gpa, .{ .width = 30 });
    defer gpa.free(c);
    try std.testing.expectEqualStrings("x\n", c);
}

test "justify pads wrapped lines to the width and alternates the ends" {
    const gpa = testing.allocator;
    const src = "one two three four five six seven eight nine ten eleven twelve thirteen\n";
    const out = try text(gpa, src, .{}, .{ .width = 26, .unicode = false, .justify = true });
    defer gpa.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    var n: usize = 0;
    var last: []const u8 = "";
    var prev_double_at: ?usize = null;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        last = l;
        n += 1;
        if (lines.peek() != null and lines.peek().?.len > 0) {
            // Every line but the last is exactly as wide as the margin.
            try testing.expectEqual(@as(usize, 26), l.len);
            const at = std.mem.find(u8, l, "  ");
            if (at != null and prev_double_at != null) {
                // The extra space moved to the other end of the line.
                try testing.expect((at.? < 13) != (prev_double_at.? < 13));
            }
            prev_double_at = at;
        }
    }
    try testing.expect(n >= 3);
    // The last line keeps single spaces.
    try testing.expect(std.mem.find(u8, last, "  ") == null);
}

test "justify leaves hard breaks and code alone, and is off by default" {
    const gpa = testing.allocator;
    const plain = try text(gpa, "aaa bbb ccc ddd eee fff ggg hhh\n", .{}, .{ .width = 24, .unicode = false });
    defer gpa.free(plain);
    try testing.expectEqualStrings("aaa bbb ccc ddd eee fff\nggg hhh\n", plain);
    const hard = try text(gpa, "aa bb\\\ncc dd\n", .{}, .{ .width = 24, .unicode = false, .justify = true });
    defer gpa.free(hard);
    try testing.expectEqualStrings("aa bb\ncc dd\n", hard);
    const code = try text(gpa, "    a  b  c\n", .{}, .{ .width = 24, .unicode = false, .justify = true });
    defer gpa.free(code);
    try testing.expectEqualStrings("    a  b  c\n", code);
}

test "justify keeps styles in the right place" {
    const gpa = testing.allocator;
    const src = "aaa **bold** ccc dddd eeeee\n";
    const out = try text(gpa, src, .{}, .{ .width = 20, .color = true, .unicode = false, .justify = true });
    defer gpa.free(out);
    // Strip escapes: the first line is 16 columns wide.
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(gpa);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == 0x1b) {
            while (out[i] != 'm') i += 1;
            continue;
        }
        try visible.append(gpa, out[i]);
    }
    const first = visible.items[0..std.mem.findScalar(u8, visible.items, '\n').?];
    try testing.expectEqual(@as(usize, 20), first.len);
    try testing.expect(std.mem.find(u8, out, "\x1b[1m") != null);
    try testing.expect(std.mem.find(u8, out, "bold\x1b[0m") != null);
}

test "tight headings put the text directly under a section heading" {
    const gpa = testing.allocator;
    const src = "# Title\n\n## NAME\n\ntext\n\n## MORE\n\nother\n";
    const out = try text(gpa, src, .{}, .{ .unicode = false, .tight_headings = true });
    defer gpa.free(out);
    try testing.expectEqualStrings("# Title\n\n## NAME\ntext\n\n## MORE\nother\n", out);
    const normal = try text(gpa, src, .{}, .{ .unicode = false });
    defer gpa.free(normal);
    try testing.expectEqualStrings("# Title\n\n## NAME\n\ntext\n\n## MORE\n\nother\n", normal);
}

test "control characters from the document never reach the terminal" {
    const gpa = testing.allocator;
    // Raw bytes, character references, C1, invalid UTF-8, code, HTML, tables,
    // image text and definition terms.
    const src = "a \x1b]52;c;eA==\x07 &#x1b;[2J &#27;&#7;&#x9b;&#127; \x9b b\n\n" ++
        "`\x1b[1m` ![\x1b](u)\n\n```\n\x1b[2J\r\n```\n\n<div>\x1b[3J</div>\n\n" ++
        "| \x1b |\n| - |\n| \x07 |\n\nT\x1b\n: d\x08\n";
    const out = try text(gpa, src, md.Extensions.all, .{ .unicode = false });
    defer gpa.free(out);
    for (out) |c| try testing.expect((c >= 0x20 and c != 0x7f) or c == '\n' or c == '\t');
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    var i: usize = 0;
    while (i + 1 < out.len) : (i += 1) try testing.expect(!(out[i] == 0xc2 and out[i + 1] < 0xa0));
    try testing.expect(std.mem.find(u8, out, "\u{fffd}[2J") != null);
}

test "a link destination built into the tree is cleaned too" {
    const gpa = testing.allocator;
    var doc = try md.Document.parse(gpa, "[x](u)\n", .{});
    defer doc.deinit();
    doc.root.first_child.?.first_child.?.literal = "\x1b[2J";
    const out = try doc.toTextAlloc(gpa, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("x <\u{fffd}[2J>\n", out);
}

test "colour output holds only the renderer's own escape sequences" {
    const gpa = testing.allocator;
    const out = try text(gpa, "**&#27;]0;t&#7;** `&#27;`\n", .{}, .{ .color = true });
    defer gpa.free(out);
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, out, i, 0x1b)) |at| : (i = at + 1) try testing.expectEqual(@as(u8, '['), out[at + 1]);
    try testing.expect(std.mem.findScalar(u8, out, 0x07) == null);
}

test "deeply nested inlines are flattened, not a stack overflow" {
    const gpa = testing.allocator;
    const n = 200_000;
    const src = try gpa.alloc(u8, 2 * n + 2);
    defer gpa.free(src);
    @memset(src[0..n], '*');
    src[n] = 'a';
    @memset(src[n + 1 .. 2 * n + 1], '*');
    src[src.len - 1] = '\n';
    const out = try text(gpa, src, .{}, .{ .width = 0 });
    defer gpa.free(out);
    // Only max_depth levels keep their markers; the text survives.
    try testing.expectEqual(@as(usize, max_depth * 2 * 2 + 2), out.len);
    try testing.expect(std.mem.find(u8, out, "a") != null);
}

/// Every line of a drawn table is as wide as its frame.
fn expectFrame(out: []const u8, max_width: ?usize) !void {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    const frame = lines.peek().?.len;
    if (max_width) |m| try testing.expect(frame <= m);
    while (lines.next()) |l| try testing.expectEqual(frame, l.len);
}

test "words too long for their column are split and the frame stays whole" {
    const gpa = testing.allocator;
    const url = "https://example.com/" ++ @as([100]u8, @splat('a'));
    const out = try text(gpa, "| key | url |\n|-|-|\n| a | " ++ url ++ " |\n| b | x `y`" ++ url ++ ") z |\n", md.Extensions.gfm, .{ .width = 60, .unicode = false });
    defer gpa.free(out);
    try expectFrame(out, 60);
    // Nothing is lost: each URL has 100 `a`s and one in "example", and one key is `a`.
    var a: usize = 0;
    for (out) |c| a += @intFromBool(c == 'a');
    try testing.expectEqual(@as(usize, 2 * 101 + 1), a);
}

test "a table with too many columns for the width still has a whole frame" {
    const gpa = testing.allocator;
    const out = try text(gpa, "|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|abcdefgh|\n|-|-|-|-|-|-|-|-|-|-|-|-|\n", md.Extensions.gfm, .{ .width = 60, .unicode = false });
    defer gpa.free(out);
    try expectFrame(out, null);
}

test "table headers are bold in colour, also after styles inside them end" {
    const gpa = testing.allocator;
    const out = try text(gpa, "| a *b* c |\n|-|\n| body |\n", md.Extensions.gfm, .{ .color = true, .unicode = false });
    defer gpa.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    const header = lines.next().?;
    // The last style set before each of the words includes bold.
    for ([_][]const u8{ "a", "b", "c" }) |word| {
        const at = std.mem.findScalar(u8, header, word[0]).?;
        const reset = std.mem.findLast(u8, header[0..at], "\x1b[0m").?;
        try testing.expect(std.mem.find(u8, header[reset..at], "\x1b[1m") != null);
    }
    _ = lines.next();
    try testing.expect(std.mem.find(u8, lines.next().?, "\x1b[1m") == null);
}

test "white space inside code spans is kept" {
    const gpa = testing.allocator;
    const out = try text(gpa, "run `a    b c` and `` ` x `` or `  y  ` now\n", .{}, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("run `a    b c` and `` x` or ` y ` now\n", out);
    const wrapped = try text(gpa, "`aaaaaaaaaa bbbb  cccc dddd` end\n", .{}, .{ .width = 20 });
    defer gpa.free(wrapped);
    try testing.expectEqualStrings("`aaaaaaaaaa\nbbbb  cccc dddd` end\n", wrapped);
}

test "widths below the minimum are honoured" {
    const gpa = testing.allocator;
    const out = try text(gpa, "one two three four five six seven eight\n", .{}, .{ .width = 10 });
    defer gpa.free(out);
    try testing.expectEqualStrings("one two\nthree four\nfive six\nseven\neight\n", out);
    const quoted = try text(gpa, "> > > one two three\n", .{}, .{ .width = 10, .unicode = false });
    defer gpa.free(quoted);
    try testing.expectEqualStrings("> > > one two\n> > > three\n", quoted);
}

fn expectText(src: []const u8, o: md.TextOptions, want: []const u8) !void {
    const gpa = testing.allocator;
    const out = try text(gpa, src, md.Extensions.all, o);
    defer gpa.free(out);
    try testing.expectEqualStrings(want, out);
}

test "ordered lists count up and line up" {
    try expectText("9. a\n10. b\n11. c\n", .{}, " 9. a\n10. b\n11. c\n");
    try expectText("3) a\n3) b\n", .{}, "3) a\n4) b\n");
}

test "task boxes, rules, HTML blocks and images are drawn" {
    try expectText("- [x] a\n- [ ] b\n", .{ .unicode = false }, "- [x] a\n- [ ] b\n");
    try expectText("a\n\n***\n\nb\n", .{ .width = 8, .unicode = false }, "a\n\n--------\n\nb\n");
    try expectText("<div>\nkept\n</div>\n", .{}, "<div>\nkept\n</div>\n");
    try expectText("![a *cat*](c.png)\n", .{}, "[image: a cat]\n");
}

test "link addresses can be left out" {
    try expectText("[docs](https://x.org/d)\n", .{ .show_urls = false }, "docs\n");
    try expectText("[docs](https://x.org/d)\n", .{}, "docs <https://x.org/d>\n");
}

test "unicode drawing characters" {
    try expectText("| a | b |\n|-|-|\n| c | d |\n", .{},
        \\┌───┬───┐
        \\│ a │ b │
        \\├───┼───┤
        \\│ c │ d │
        \\└───┴───┘
        \\
    );
    try expectText("- a\n\n> q\n\n***\n", .{ .width = 4 }, "\u{2022} a\n\n\u{2502} q\n\n────\n");
}

test "table columns align left, centre and right" {
    try expectText("| aaaaa | bbbbb | ccccc |\n|:-|:-:|-:|\n| x | y | z |\n", .{ .unicode = false },
        \\+-------+-------+-------+
        \\| aaaaa | bbbbb | ccccc |
        \\+-------+-------+-------+
        \\| x     |   y   |     z |
        \\+-------+-------+-------+
        \\
    );
}

test "each style has its own escape sequence in colour" {
    const gpa = testing.allocator;
    for ([_][2][]const u8{
        .{ "*w*\n", "\x1b[3mw" },
        .{ "**w**\n", "\x1b[1mw" },
        .{ "~~w~~\n", "\x1b[9mw" },
        .{ "`w`\n", "\x1b[36mw" },
        .{ "[w](u)\n", "\x1b[4m\x1b[34mw" },
    }) |case| {
        const out = try text(gpa, case[0], md.Extensions.gfm, .{ .color = true });
        defer gpa.free(out);
        try testing.expect(std.mem.find(u8, out, case[1]) != null);
    }
}

test "justify does not pad the lines of a table cell" {
    const gpa = testing.allocator;
    const src = "| k | v |\n|-|-|\n| a | one two three four five six seven eight |\n";
    const plain = try text(gpa, src, md.Extensions.gfm, .{ .width = 24, .unicode = false });
    defer gpa.free(plain);
    const justified = try text(gpa, src, md.Extensions.gfm, .{ .width = 24, .unicode = false, .justify = true });
    defer gpa.free(justified);
    try testing.expectEqualStrings(plain, justified);
}
