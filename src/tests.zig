//! Tests: the CommonMark specification examples and the std.Io boundary.

const std = @import("std");
const md = @import("root.zig");

fn render(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var doc = try md.Document.parse(gpa, source, .{});
    defer doc.deinit();
    return doc.toHtmlAlloc(gpa);
}

test "a heading and emphasis" {
    const out = try render(std.testing.allocator, "# Hello *world*\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("<h1>Hello <em>world</em></h1>\n", out);
}

const Example = struct {
    markdown: []const u8,
    html: []const u8,
    example: u32,
    section: []const u8,
};

const spec_json = @embedFile("spec-0.31.2.json");

test "CommonMark 0.31.2 specification examples" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice([]Example, gpa, spec_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var failed: usize = 0;
    for (parsed.value) |ex| {
        const out = try render(gpa, ex.markdown);
        defer gpa.free(out);
        if (!std.mem.eql(u8, out, ex.html)) {
            failed += 1;
            if (failed <= 40) std.debug.print("example {d} ({s}) fails\n--- markdown\n{s}--- expected\n{s}--- got\n{s}\n", .{ ex.example, ex.section, ex.markdown, ex.html, out });
        }
    }
    std.debug.print("spec: {d} of {d} examples pass\n", .{ parsed.value.len - failed, parsed.value.len });
    try std.testing.expectEqual(@as(usize, 0), failed);
}

const gfm_json = @embedFile("gfm-extensions.json");

test "GFM and footnote examples (cmark-gfm test suite)" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice([]Example, gpa, gfm_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var failed: usize = 0;
    for (parsed.value) |ex| {
        var doc = try md.Document.parse(gpa, ex.markdown, .{ .extensions = md.Extensions.all });
        defer doc.deinit();
        const out = try doc.toHtmlAlloc(gpa);
        defer gpa.free(out);
        // One upstream example only checks that the parser does not crash.
        if (std.mem.eql(u8, ex.html, "<IGNORE>\n")) continue;
        if (!std.mem.eql(u8, out, ex.html)) {
            failed += 1;
            std.debug.print("gfm example {d} ({s}) fails\n--- markdown\n{s}--- expected\n{s}--- got\n{s}\n", .{ ex.example, ex.section, ex.markdown, ex.html, out });
        }
    }
    std.debug.print("gfm: {d} of {d} examples pass\n", .{ parsed.value.len - failed, parsed.value.len });
    try std.testing.expectEqual(@as(usize, 0), failed);
}

fn renderWith(gpa: std.mem.Allocator, source: []const u8, ext: md.Extensions) ![]u8 {
    var doc = try md.Document.parse(gpa, source, .{ .extensions = ext });
    defer doc.deinit();
    return doc.toHtmlAlloc(gpa);
}

test "front matter is kept apart and not rendered" {
    const gpa = std.testing.allocator;
    var doc = try md.Document.parse(gpa, "---\ntitle: x\n---\n# Hi\n", .{ .extensions = .{ .front_matter = true } });
    defer doc.deinit();
    const first = doc.root.first_child.?;
    try std.testing.expectEqual(md.Kind.front_matter, first.kind);
    try std.testing.expectEqualStrings("title: x\n", first.literal);
    const out = try doc.toHtmlAlloc(gpa);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<h1>Hi</h1>\n", out);
}

test "an unclosed front matter fence is ordinary Markdown" {
    const gpa = std.testing.allocator;
    const out = try renderWith(gpa, "---\nabc\n", .{ .front_matter = true });
    defer gpa.free(out);
    const plain = try renderWith(gpa, "---\nabc\n", .{});
    defer gpa.free(plain);
    try std.testing.expectEqualStrings(plain, out);
}

test "front matter only counts at the very start" {
    const gpa = std.testing.allocator;
    const out = try renderWith(gpa, "text\n\n---\na: b\n---\n", .{ .front_matter = true });
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "<hr />") != null);
}

test "without extensions tables and strikethrough stay plain text" {
    const gpa = std.testing.allocator;
    const out = try renderWith(gpa, "| a |\n| - |\n| b |\n\n~~x~~ www.example.com\n", .{});
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "<table>") == null);
    try std.testing.expect(std.mem.find(u8, out, "<del>") == null);
    try std.testing.expect(std.mem.find(u8, out, "<a ") == null);
}

test "extensions behave through a one-byte reader as well" {
    const gpa = std.testing.allocator;
    const src = "| a | b |\n| - | - |\n| 1 | ~~2~~ |\n\n- [x] done[^n]\n\n[^n]: note\n";
    const want = try renderWith(gpa, src, md.Extensions.all);
    defer gpa.free(want);
    var r: std.Io.Reader = .fixed(src);
    var doc = try md.Document.parseReader(gpa, &r, .{ .extensions = md.Extensions.all });
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(std.mem.find(u8, got, "<del>2</del>") != null);
    try std.testing.expect(std.mem.find(u8, got, "footnote-ref") != null);
}

fn expectDl(src: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const out = try renderWith(gpa, src, .{ .definition_lists = true });
    defer gpa.free(out);
    try std.testing.expectEqualStrings(want, out);
}

test "definition lists" {
    try expectDl("Apple\n: A fruit\n: Also a company\n", "<dl>\n<dt>Apple</dt>\n<dd>A fruit</dd>\n<dd>Also a company</dd>\n</dl>\n");
    // Every line of the paragraph is a term; inlines work in terms and definitions.
    try expectDl("a\n*b*\n: x `y`\n", "<dl>\n<dt>a</dt>\n<dt><em>b</em></dt>\n<dd>x <code>y</code></dd>\n</dl>\n");
    // Without a blank line, the next line continues the definition lazily.
    try expectDl("A\n: 1\nB\n: 2\n", "<dl>\n<dt>A</dt>\n<dd>1\nB</dd>\n<dd>2</dd>\n</dl>\n");
    // Terms after a blank line stay in the same list.
    try expectDl("A\n: 1\n\nB\n: 2\n", "<dl>\n<dt>A</dt>\n<dd>\n<p>1</p>\n</dd>\n<dt>B</dt>\n<dd>\n<p>2</p>\n</dd>\n</dl>\n");
    // Indented continuation makes more blocks in a definition.
    try expectDl("T\n: one\n\n    two\n", "<dl>\n<dt>T</dt>\n<dd>\n<p>one</p>\n<p>two</p>\n</dd>\n</dl>\n");
    // A colon without a space, or without a term, is text.
    try expectDl("a\n:b\n", "<p>a\n:b</p>\n");
    try expectDl(": x\n", "<p>: x</p>\n");
    // Text after the list is a paragraph again.
    try expectDl("T\n: d\n\nafter\n", "<dl>\n<dt>T</dt>\n<dd>d</dd>\n</dl>\n<p>after</p>\n");
}

test "definition lists are off by default" {
    const gpa = std.testing.allocator;
    const out = try renderWith(gpa, "T\n: d\n", .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<p>T\n: d</p>\n", out);
}

test "definition lists nest, mix with other blocks and do not leak" {
    const gpa = std.testing.allocator;
    const srcs = [_][]const u8{
        "A\n: B\n  C\n  : nested def\n",
        "- T\n  : in an item\n",
        "> T\n> : in a quote\n",
        "T\n:\ttab\n: \n:  \n",
        "T\n: d\n\n\n\nU\n: e\n\n: f\n",
        "[x]: /u\n: d\n",
        "T\n: ```\n  code\n  ```\n",
        "T\n:     indented code?\n",
        ": : :\n:\n",
    };
    for (srcs) |src| {
        const out = try renderWith(gpa, src, md.Extensions.all);
        gpa.free(out);
        var doc = try md.Document.parse(gpa, src, .{ .extensions = md.Extensions.all });
        defer doc.deinit();
        const t = try doc.toTextAlloc(gpa, .{ .width = 40 });
        gpa.free(t);
    }
}

test "parentheses in a link destination are limited to 32 levels" {
    const gpa = std.testing.allocator;
    inline for (.{ .{ 32, true }, .{ 33, false } }) |case| {
        const src = "[a](u" ++ @as([case[0]]u8, @splat('(')) ++ @as([case[0]]u8, @splat(')')) ++ ")\n";
        const out = try render(gpa, src);
        defer gpa.free(out);
        try std.testing.expectEqual(case[1], std.mem.find(u8, out, "<a ") != null);
    }
}

test "a thematic break is still found after list markers and failed attempts" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "- * - - -\n- - x\n* * *\n");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<ul>\n<li>\n<ul>\n<li>\n<hr />\n</li>\n</ul>\n</li>\n<li>\n<ul>\n<li>x</li>\n</ul>\n</li>\n</ul>\n<hr />\n", out);
}

fn renderSafe(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var doc = try md.Document.parse(gpa, source, .{ .extensions = md.Extensions.all });
    defer doc.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try doc.writeHtmlOptions(gpa, &out.writer, .{ .safe = true });
    return out.toOwnedSlice();
}

test "safe HTML leaves out raw HTML and empties dangerous addresses" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "<script>x</script>\n", "<!-- raw HTML omitted -->\n" },
        .{ "a <img src=x onerror=y> b\n", "<p>a <!-- raw HTML omitted --> b</p>\n" },
        .{ "[x](javascript:alert(1))\n", "<p><a href=\"\">x</a></p>\n" },
        .{ "[x](JaVaScRiPt&#58;a)\n", "<p><a href=\"\">x</a></p>\n" },
        .{ "<vbscript:a>\n", "<p><a href=\"\">vbscript:a</a></p>\n" },
        .{ "[x](file:///etc/passwd \"t\")\n", "<p><a href=\"\" title=\"t\">x</a></p>\n" },
        .{ "![i](data:text/html,x)\n", "<p><img src=\"\" alt=\"i\" /></p>\n" },
        .{ "![i](data:image/png;base64,AA)\n", "<p><img src=\"data:image/png;base64,AA\" alt=\"i\" /></p>\n" },
        .{ "[x](https://a.b/javascript:)\n", "<p><a href=\"https://a.b/javascript:\">x</a></p>\n" },
    }) |case| {
        const out = try renderSafe(gpa, case[0]);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(case[1], out);
    }
}

test "dangerous addresses are recognised in trees built by other readers" {
    for ([_][]const u8{ " javascript:a", "\x01\njavascript:a", "java\tscr\nipt:a", "DATA:image/svg+xml,x" }) |url| {
        try std.testing.expect(md.html.isDangerousUrl(url));
    }
    for ([_][]const u8{ "", "a", "/javascript:", "https://x", "mailto:a@b.c" }) |url| {
        try std.testing.expect(!md.html.isDangerousUrl(url));
    }
}

fn expectLabelLink(unit: []const u8, count: usize, extra: []const u8, shortcut: bool, linked: bool) !void {
    const gpa = std.testing.allocator;
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(gpa);
    for (0..count) |_| try label.appendSlice(gpa, unit);
    try label.appendSlice(gpa, extra);
    const use = if (shortcut) "" else "[x]";
    const src = try std.fmt.allocPrint(gpa, "{s}[{s}]\n\n[{s}]: /u\n", .{ use, label.items, label.items });
    defer gpa.free(src);
    const out = try render(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqual(linked, std.mem.find(u8, out, "<a ") != null);
}

test "link labels hold at most 999 characters" {
    for ([_]bool{ false, true }) |shortcut| {
        try expectLabelLink("a", 999, "", shortcut, true);
        try expectLabelLink("a", 1000, "", shortcut, false);
        // Characters are counted, not bytes.
        try expectLabelLink("\u{20ac}", 999, "", shortcut, true);
        try expectLabelLink("\u{20ac}", 999, "a", shortcut, false);
    }
}

test "a long run of spaces does not make an over-long shortcut label match" {
    const gpa = std.testing.allocator;
    const src = "[a" ++ @as([1000]u8, @splat(' ')) ++ "b]\n\n[a b]: /u\n";
    const out = try render(gpa, src);
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "<a ") == null);
}

test "tabs are accepted around link destinations and titles" {
    const gpa = std.testing.allocator;
    const plain = "<p><a href=\"/u\">a</a></p>\n";
    const titled = "<p><a href=\"/u\" title=\"t\">a</a></p>\n";
    for ([_][2][]const u8{
        .{ "[a]: /u\t\n\n[a]\n", plain },
        .{ "[a]:\t/u\n\n[a]\n", plain },
        .{ "[a]:\t\n\t/u \t\n\n[a]\n", plain },
        .{ "[a]: /u\t\"t\"\t\n\n[a]\n", titled },
        .{ "[a](\t/u\t)\n", plain },
        .{ "[a](\t/u\t\"t\"\t)\n", titled },
    }) |case| {
        const out = try render(gpa, case[0]);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(case[1], out);
    }
}

test "a table ends where another block starts" {
    const gpa = std.testing.allocator;
    const table = "| a |\n| - |\n| 1 |\n";
    const alone = try renderWith(gpa, table, md.Extensions.gfm);
    defer gpa.free(alone);
    // As cmark-gfm does.
    for ([_][]const u8{ "- x", "-", "* x", "+ x", "1. x", "2. x", "10) x", "***", "___", "---", "<div>", "</div>", "<!-- c -->", "<span>", "<?p", "    code", "> q", "# h", "```" }) |next| {
        const src = try std.mem.concat(gpa, u8, &.{ table, next, "\n" });
        defer gpa.free(src);
        const out = try renderWith(gpa, src, md.Extensions.gfm);
        defer gpa.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, alone));
        try std.testing.expect(out.len > alone.len);
    }
    for ([_][]const u8{ "plain", "===", "-x", "1.x", "#x", "<span>t", ": d", "[a]: /u" }) |next| {
        const src = try std.mem.concat(gpa, u8, &.{ table, next, "\n" });
        defer gpa.free(src);
        const out = try renderWith(gpa, src, md.Extensions.gfm);
        defer gpa.free(out);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "<tr>"));
    }
}
