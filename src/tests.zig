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
