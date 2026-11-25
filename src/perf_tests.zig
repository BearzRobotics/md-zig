//! Inputs that once took quadratic time. Each is sized so that linear work
//! takes well under a second, even in a debug build, and quadratic work takes
//! far longer than the limit.

const std = @import("std");
const md = @import("root.zig");
const testing = std.testing;

const limit_ms = 10_000;

/// Parses `head ++ unit * n ++ tail` and renders it as HTML within the limit.
fn withinBudget(head: []const u8, unit: []const u8, n: usize, tail: []const u8, ext: md.Extensions) !void {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, head);
    for (0..n) |_| try src.appendSlice(gpa, unit);
    try src.appendSlice(gpa, tail);
    const start = std.Io.Timestamp.now(testing.io, .awake);
    var doc = try md.Document.parse(gpa, src.items, .{ .extensions = ext });
    defer doc.deinit();
    const out = try doc.toHtmlAlloc(gpa);
    defer gpa.free(out);
    const ms = start.untilNow(testing.io, .awake).toMilliseconds();
    if (ms > limit_ms) {
        std.debug.print("'{s}' x {d} took {d} ms\n", .{ unit, n, ms });
        return error.TooSlow;
    }
}

test "time: unterminated raw HTML openers" {
    for ([_][]const u8{ "<!--", "<?", "<![CDATA[", "<!A " }) |opener| {
        try withinBudget("a ", opener, 400_000, "\n", .{});
    }
}

test "time: repeated link openers with unbalanced parentheses" {
    try withinBudget("", "[a](", 400_000, "\n", .{});
    try withinBudget("", "[a](b", 400_000, "\n", .{});
}

test "time: many open brackets before many links" {
    for ([_][]const u8{ "[", "![" }) |opener| {
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(testing.allocator);
        for (0..100_000) |_| try head.appendSlice(testing.allocator, opener);
        try withinBudget(head.items, "[a](b)", 100_000, "\n", .{});
    }
}

test "time: autolink candidates" {
    try withinBudget("", "_www.", 200_000, "_a_b\n", md.Extensions.gfm);
    try withinBudget("www.a.com", ")", 400_000, "\n", md.Extensions.gfm);
}

test "time: a line of list markers" {
    for ([_][]const u8{ "- ", "* " }) |marker| try withinBudget("", marker, 200_000, "x\n", .{});
}
