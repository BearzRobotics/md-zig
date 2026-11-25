//! The Markdown writer: parse -> write -> parse must give the same HTML, for
//! every CommonMark and GFM example; plus checks on what is kept verbatim.

const std = @import("std");
const md = @import("root.zig");

const Example = struct { markdown: []const u8, html: []const u8, example: u32, section: []const u8 };

/// Parses `src`, writes it as Markdown, and returns the HTML of both trees.
fn roundTrip(gpa: std.mem.Allocator, src: []const u8, ext: md.Extensions) !struct { before: []u8, after: []u8, text: []u8 } {
    var doc = try md.Document.parse(gpa, src, .{ .extensions = ext });
    defer doc.deinit();
    const before = try doc.toHtmlAlloc(gpa);
    errdefer gpa.free(before);
    const text = try doc.toMarkdownAlloc(gpa);
    errdefer gpa.free(text);
    var doc2 = try md.Document.parse(gpa, text, .{ .extensions = ext });
    defer doc2.deinit();
    const after = try doc2.toHtmlAlloc(gpa);
    return .{ .before = before, .after = after, .text = text };
}

fn run(comptime json: []const u8, ext: md.Extensions, name: []const u8) !void {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice([]Example, gpa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var failed: usize = 0;
    for (parsed.value) |ex| {
        if (std.mem.eql(u8, ex.html, "<IGNORE>\n")) continue;
        const r = try roundTrip(gpa, ex.markdown, ext);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        if (!std.mem.eql(u8, r.before, r.after)) {
            failed += 1;
            std.debug.print("{s} example {d} ({s}) changes\n--- markdown\n{s}--- written\n{s}--- html before\n{s}--- html after\n{s}\n", .{ name, ex.example, ex.section, ex.markdown, r.text, r.before, r.after });
        }
    }
    std.debug.print("{s}: {d} of {d} examples round-trip\n", .{ name, parsed.value.len - failed, parsed.value.len });
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "writer round trip: CommonMark 0.31.2 examples" {
    try run(@embedFile("spec-0.31.2.json"), .{}, "spec");
}

test "writer round trip: GFM and footnote examples" {
    try run(@embedFile("gfm-extensions.json"), md.Extensions.all, "gfm");
}

fn written(src: []const u8, ext: md.Extensions) ![]u8 {
    var doc = try md.Document.parse(std.testing.allocator, src, .{ .extensions = ext });
    defer doc.deinit();
    return doc.toMarkdownAlloc(std.testing.allocator);
}

test "HTML comments are written back exactly" {
    const src =
        \\# Title
        \\
        \\<!-- a block comment
        \\     spanning lines -->
        \\
        \\Some *text* <!-- inline note --> after.
        \\
    ;
    const out = try written(src, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<!-- a block comment\n     spanning lines -->\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<!-- inline note -->") != null);
}

test "front matter is written back unchanged" {
    const out = try written("---\ntitle: x\n# yaml comment\n---\n# Hi\n", .{ .front_matter = true });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("---\ntitle: x\n# yaml comment\n---\n\n# Hi\n", out);
}

test "definition lists round trip" {
    const gpa = std.testing.allocator;
    const srcs = [_][]const u8{
        "Term\n: Definition\n",
        "Term\n: One\n: Two\n\nOther\n: Three\n",
        "Term\n: One\n\n: Two\n",
    };
    for (srcs) |src| {
        const r = try roundTrip(gpa, src, md.Extensions.all);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        if (!std.mem.eql(u8, r.before, r.after)) std.debug.print("deflist changes\n{s}--- written\n{s}--- {s}--- {s}\n", .{ src, r.text, r.before, r.after });
        try std.testing.expectEqualStrings(r.before, r.after);
    }
}

test "text that looks like markup is escaped" {
    const gpa = std.testing.allocator;
    const srcs = [_][]const u8{
        "\\# not a heading\n",
        "1\\. not a list\n",
        "\\- not a bullet\n",
        "a \\*star\\* and snake_case and \\_under\\_\n",
        "\\[not a link\\](x) and &amp;amp; and \\<b>\n",
        "x\n\\> not a quote\n",
        "| a | b |\n| - | - |\n| \\| | 2 |\n",
    };
    for (srcs) |src| {
        const r = try roundTrip(gpa, src, md.Extensions.gfm);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        if (!std.mem.eql(u8, r.before, r.after)) std.debug.print("changes\n{s}--- written\n{s}--- {s}--- {s}\n", .{ src, r.text, r.before, r.after });
        try std.testing.expectEqualStrings(r.before, r.after);
    }
}

test "nesting that is too deep fails cleanly" {
    const gpa = std.testing.allocator;
    const src = try gpa.alloc(u8, 2000);
    defer gpa.free(src);
    @memset(src, '>');
    src[src.len - 1] = 'x';
    var doc = try md.Document.parse(gpa, src, .{});
    defer doc.deinit();
    try std.testing.expectError(error.TooDeep, doc.toMarkdownAlloc(gpa));
}

fn expectSameHtml(srcs: []const []const u8, ext: md.Extensions) !void {
    const gpa = std.testing.allocator;
    for (srcs) |src| {
        const r = try roundTrip(gpa, src, ext);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        std.testing.expectEqualStrings(r.before, r.after) catch |e| {
            std.debug.print("source:\n{s}\nwritten:\n{s}\n", .{ src, r.text });
            return e;
        };
    }
}

test "emphasis next to letters outside ASCII" {
    try expectSameHtml(&.{ "*x*\u{e9}\n", "\u{e9}*x*\n", "\u{41f}\u{440}\u{438}*x*\n", "caf\u{e9}*s* and *n\u{e9}*e\n", "\u{65e5}**\u{672c}**\u{8a9e}\n" }, .{});
}

test "nested and adjacent emphasis keeps its meaning" {
    try expectSameHtml(&.{
        "*a*_-_\n",                "_#_*h*\n",   "***m*>*>*\n", "**%*~*-*\n",   "**>*o**)*\n",                         "*# *=***<*\n",
        "*****!**.**\n",           "a*www.a*\n", "u*a@b.r*\n",  "b~~a@b.c~~\n", "| a*www.a* \\| |\n|-|\n| _#_*h* |\n", "# _#_*h*\n",
        "*a*_-_[^1]\n\n[^1]: n\n",
    }, md.Extensions.all);
}

test "ordinary emphasis keeps its usual spelling" {
    const out = try written("*a* **b** ~~c~~ d*e*f\n", md.Extensions.all);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("_a_ **b** ~~c~~ d*e*f\n", out);
}

test "pipes anywhere in a table cell stay in the cell" {
    try expectSameHtml(&.{
        "| a |\n|-|\n| [x](u \"p\\|q\") |\n",
        "| a |\n|-|\n| <i title=\"\\|\"> |\n",
        "| a |\n|-|\n| ![\\|](u '\\|') |\n",
        "| a |\n|-|\n| `x \\| y` \\| z \\\\\\| |\n",
        "| a |\n|-|\n| *x\\|* [^\\|] |\n\n[^\\|]: n\n",
    }, md.Extensions.all);
}

test "code block info strings are escaped again" {
    try expectSameHtml(&.{
        "``` a\\\\*b\nc\n```\n",
        "``` &amp;lt;\nc\n```\n",
        "~~~&#10;x\ny\n~~~\n",
        "~~~ ~x`\nc\n~~~\n",
        "``` &#32;a&#9;\nc\n```\n",
        "``` x&#32;y a&b\nc\n```\n",
    }, .{});
    const out = try written("```zig title=\"a & b\"\nc\n```\n", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("```zig title=\"a & b\"\nc\n```\n", out);
}

test "block structures survive writing" {
    try expectSameHtml(&.{
        "* ---\n",                             "- - ___\n",              "- a\n- ***\n",
        "a\n: \n",                             "a\n: \n: b\n",           "a[^1]\n\n[^1]:\n",
        "+ [ ] [1]:;\n",                       "- [x] [1]: /u\n  - b\n", "c\n\t<div>\n",
        "a\n    <!-- c -->\n",                 "> c\n    <div>\n",       "[r]:u\n<b>\n",
        "[r]: u\n    <div>\n",                 "<a\nb>\n-\n",            "<a\nb> x\n===\n",
        "[x](u \"a&#10;&#10;b &amp;amp;\")\n",
    }, md.Extensions.all);
}

test "white space that is text survives at the ends of lines and blocks" {
    try expectSameHtml(&.{
        "a&#32;\n",      "a&#32;&#32;\n", "a&#9;\n",           "a&#12;\n",      "&#12;a\n", "&#11;\n", "a&#32;\nb\n",
        "a&#32;\\\nb\n", "# a&#32;\n",    "| a&#32; |\n|-|\n", "a&#32;\n: d\n", "&#32;\n",
    }, md.Extensions.all);
}

test "list numbers stay within nine digits" {
    try expectSameHtml(&.{"999999999. a\n999999999. b\n999999998) c\n999999999) d\n"}, .{});
}

test "front matter fences are written as they were typed" {
    for ([_][]const u8{ "--- \na: 1\n...\n\n# Hi\n", "---\n--- \t\n", "---\na\n---\n" }) |src| {
        const out = try written(src, .{ .front_matter = true });
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(src, out);
    }
}

test "tags spanning lines, indented blocks in items and tags in later terms" {
    try expectSameHtml(&.{
        "<y\n    >\n",  "a <y\n    - >\n",     "*\n\t<div\n", "-\n\t<script\n", "1.\n\t<script\n", "-\n   <c>\n",
        "&\n<b>\n: \n", "a\n    <div>\n: d\n",
    }, md.Extensions.all);
    try expectSameHtml(&.{ "<y\n    >\n", "-\n\t<script\n", "-\n   <c>\n" }, .{});
}

test "a footnote reference inside link text survives writing" {
    try expectSameHtml(&.{"[see [^1] here](/url)\n\n[^1]: n\n"}, md.Extensions.all);
}

/// Pieces of Markdown syntax; strung together at random they reach
/// combinations nobody writes a test for.
const fragments = [_][]const u8{
    "a",     "b",       " ",        "  ",  "\n",  "\n",        "\n\n",       "\t",     "    ", "*",    "**",     "_",
    "~",     "~~",      "`",        "```", "~~~", "#",         "# ",         "> ",     "- ",   "* ",   "+ ",     "1. ",
    "2) ",   "0. ",     "[",        "]",   "(",   ")",         "<",          ">",      "!",    "\\",   "&",      ";",
    "&amp;", "&#10;",   "&#32;",    "|",   "---", "===",       "***",        ":",      ": ",   "[^1]", "[^1]: ", "[x] ",
    "[ ] ",  "[r]: /u", "[r]",      "\"",  "'",   "www.a.com", "http://x.y", "a@b.co", "<!--", "-->",  "<div>",  "</div>",
    "<a>",   "<br/>",   "<script>", ".",   "=",   "-",         "%",          "\u{e9}", "{",
};

test "random input: every renderer finishes, and the writer round trip holds" {
    const gpa = std.testing.allocator;
    // A fixed seed: the same inputs on every run.
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    const extensions = [_]md.Extensions{ .{}, md.Extensions.gfm, md.Extensions.all };
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..4000) |i| {
        src.clearRetainingCapacity();
        for (0..random.intRangeAtMost(usize, 1, 14)) |_| try src.appendSlice(gpa, fragments[random.uintLessThan(usize, fragments.len)]);
        const ext = extensions[i % extensions.len];
        var doc = try md.Document.parse(gpa, src.items, .{ .extensions = ext });
        defer doc.deinit();
        const shown = try doc.toTextAlloc(gpa, .{ .width = random.uintLessThan(usize, 40), .color = random.boolean(), .justify = random.boolean() });
        gpa.free(shown);
        try expectSameHtml(&.{src.items}, ext);
    }
}
