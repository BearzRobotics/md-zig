//! Tests of the std.Io.Reader / std.Io.Writer boundary: short reads, readers
//! that fail part-way, tiny reader buffers, and writers that fail part-way.

const std = @import("std");
const md = @import("root.zig");
const testing = std.testing;
const Io = std.Io;

const sample =
    \\# Title
    \\
    \\Some *emphasis*, **strong** text and a [link][ref] with `code`.
    \\
    \\> quote
    \\> more
    \\
    \\- one
    \\- two
    \\  1. nested
    \\
    \\```zig
    \\const x = 1;
    \\```
    \\
    \\[ref]: /url "Title"
    \\
;

/// A Reader over `data` with a buffer of `buf.len` bytes that hands out at most
/// `chunk` bytes per `stream` call, and fails once `fail_after` bytes were given.
const TrickleReader = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize,
    fail_after: ?usize,
    buf: [64]u8 = undefined,
    interface: Io.Reader,

    fn setup(self: *TrickleReader, data: []const u8, buffer_len: usize, chunk: usize, fail_after: ?usize) void {
        self.* = .{ .data = data, .chunk = chunk, .fail_after = fail_after, .interface = undefined };
        self.interface = .{ .vtable = &.{ .stream = stream }, .buffer = self.buf[0..buffer_len], .seek = 0, .end = 0 };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *TrickleReader = @fieldParentPtr("interface", r);
        if (self.fail_after) |n| if (self.pos >= n) return error.ReadFailed;
        if (self.pos >= self.data.len) return error.EndOfStream;
        var n = @min(self.chunk, self.data.len - self.pos);
        if (self.fail_after) |f| n = @min(n, f - self.pos);
        const give = @min(n, @backingInt(limit));
        try w.writeAll(self.data[self.pos..][0..give]);
        self.pos += give;
        return give;
    }
};

/// A Writer that accepts `limit` bytes in total, then fails. Its small buffer
/// exercises both the buffered and the `drain` paths.
const LimitedWriter = struct {
    out: std.ArrayList(u8) = .empty,
    limit: usize,
    buf: [8]u8 = undefined,
    interface: Io.Writer,

    fn setup(self: *LimitedWriter, limit: usize) void {
        self.* = .{ .limit = limit, .interface = undefined };
        self.interface = .{ .vtable = &.{ .drain = drain }, .buffer = &self.buf };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *LimitedWriter = @fieldParentPtr("interface", w);
        try self.accept(w.buffered());
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.accept(d);
            consumed += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.accept(last);
        return consumed + last.len * splat;
    }

    fn accept(self: *LimitedWriter, bytes: []const u8) Io.Writer.Error!void {
        if (self.out.items.len + bytes.len > self.limit) return error.WriteFailed;
        self.out.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
    }
};

fn reference(gpa: std.mem.Allocator) ![]u8 {
    var doc = try md.Document.parse(gpa, sample, .{});
    defer doc.deinit();
    return doc.toHtmlAlloc(gpa);
}

test "parseReader gives the same result for every buffer and chunk size" {
    const gpa = testing.allocator;
    const want = try reference(gpa);
    defer gpa.free(want);

    for ([_]usize{ 1, 2, 3, 7, 64 }) |buffer_len| {
        for ([_]usize{ 1, 2, 5, 64 }) |chunk| {
            var tr: TrickleReader = undefined;
            tr.setup(sample, buffer_len, chunk, null);
            var doc = try md.Document.parseReader(gpa, &tr.interface, .{});
            defer doc.deinit();
            const got = try doc.toHtmlAlloc(gpa);
            defer gpa.free(got);
            try testing.expectEqualStrings(want, got);
        }
    }
}

test "a line longer than the reader's buffer is read whole" {
    const gpa = testing.allocator;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..100) |_| try long.appendSlice(gpa, "word ");
    try long.append(gpa, '\n');
    var tr: TrickleReader = undefined;
    tr.setup(long.items, 4, 3, null);
    var doc = try md.Document.parseReader(gpa, &tr.interface, .{});
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("<p>", got[0..3]);
    try testing.expectEqual(@as(usize, 3 + 499 + 5), got.len);
}

test "parseReader reports ReadFailed wherever the reader dies, without leaking" {
    for (0..sample.len) |n| {
        var tr: TrickleReader = undefined;
        tr.setup(sample, 3, 3, n);
        try testing.expectError(error.ReadFailed, md.Document.parseReader(testing.allocator, &tr.interface, .{}));
    }
}

test "limits on size and line length" {
    var tr: TrickleReader = undefined;
    tr.setup(sample, 8, 1, null);
    try testing.expectError(error.InputTooLarge, md.Document.parseReader(testing.allocator, &tr.interface, .{ .max_bytes = 10 }));
    tr.setup(sample, 8, 1, null);
    try testing.expectError(error.LineTooLong, md.Document.parseReader(testing.allocator, &tr.interface, .{ .max_line_bytes = 10 }));
}

test "writeHtml is identical through a small-buffer writer" {
    const gpa = testing.allocator;
    const want = try reference(gpa);
    defer gpa.free(want);
    var doc = try md.Document.parse(gpa, sample, .{});
    defer doc.deinit();

    var lw: LimitedWriter = undefined;
    lw.setup(std.math.maxInt(usize));
    defer lw.out.deinit(gpa);
    try doc.writeHtml(gpa, &lw.interface);
    try lw.interface.flush();
    try testing.expectEqualStrings(want, lw.out.items);
}

test "writeHtml reports WriteFailed wherever the writer dies" {
    const gpa = testing.allocator;
    const full = try reference(gpa);
    defer gpa.free(full);
    var doc = try md.Document.parse(gpa, sample, .{});
    defer doc.deinit();

    for (0..full.len) |limit| {
        var lw: LimitedWriter = undefined;
        lw.setup(limit);
        defer lw.out.deinit(gpa);
        const result = doc.writeHtml(gpa, &lw.interface);
        const flushed = lw.interface.flush();
        try testing.expect(std.meta.isError(result) or std.meta.isError(flushed));
    }
}

test "line endings: CRLF, lone CR and a missing final newline" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "a\r\nb\r\n", "a\rb\r", "a\nb", "a\r\nb" }) |src| {
        var doc = try md.Document.parse(gpa, src, .{});
        defer doc.deinit();
        const got = try doc.toHtmlAlloc(gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings("<p>a\nb</p>\n", got);
    }
}

test "NUL becomes the replacement character" {
    const gpa = testing.allocator;
    var doc = try md.Document.parse(gpa, "a\x00b\n", .{});
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("<p>a\u{fffd}b</p>\n", got);
}

test "deeply nested input does not overflow the stack" {
    const gpa = testing.allocator;
    const depth = 20000;
    const src = try gpa.alloc(u8, depth + 2);
    defer gpa.free(src);
    @memset(src[0..depth], '>');
    src[depth] = 'x';
    src[depth + 1] = '\n';
    var doc = try md.Document.parse(gpa, src, .{});
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try testing.expect(got.len > depth);
}

fn countKind(root: *md.Node, kind: md.Kind) usize {
    var n: usize = 0;
    var walker = md.Walker.init(root);
    while (walker.next()) |ev| {
        if (ev.entering and ev.node.kind == kind) n += 1;
    }
    return n;
}

test "padding short table rows is limited for the whole document" {
    const gpa = testing.allocator;
    // Two tables of four columns; each short row is padded with three cells.
    const table = "|a|b|c|d|\n|-|-|-|-|\n1\n2\n3\n";
    const src = table ++ "\n" ++ table;
    for ([_]struct { usize, usize }{ .{ 18, 8 }, .{ 17, 7 }, .{ 9, 5 }, .{ 0, 2 } }) |case| {
        var doc = try md.Document.parse(gpa, src, .{ .extensions = md.Extensions.gfm, .max_padded_cells = case[0] });
        defer doc.deinit();
        try testing.expectEqual(@as(usize, 2), countKind(doc.root, .table));
        try testing.expectEqual(case[1], countKind(doc.root, .table_row));
    }
    // Full rows use none of the budget.
    var doc = try md.Document.parse(gpa, "|a|b|\n|-|-|\n|1|2|\n|3|4|\n", .{ .extensions = md.Extensions.gfm, .max_padded_cells = 0 });
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), countKind(doc.root, .table_row));
}

test "a wide table with many short rows stays within the default budget" {
    const gpa = testing.allocator;
    const n = 4000;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '|');
    for (0..n) |_| try out.appendSlice(gpa, "a|");
    try out.appendSlice(gpa, "\n|");
    for (0..n) |_| try out.appendSlice(gpa, "-|");
    try out.append(gpa, '\n');
    for (0..n) |_| try out.appendSlice(gpa, "b\n");
    const src = out.items;
    var doc = try md.Document.parse(gpa, src, .{ .extensions = md.Extensions.gfm });
    defer doc.deinit();
    try testing.expect(countKind(doc.root, .table_cell) <= (md.Options{}).max_padded_cells + 2 * n + (512 * 1024 / n + 1));
}

test "reference expansion is limited" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "[a]: /");
    try src.appendNTimes(gpa, 'u', 40_000);
    try src.appendSlice(gpa, "\n\n");
    for (0..2000) |_| try src.appendSlice(gpa, "[a] ");
    var doc = try md.Document.parse(gpa, src.items, .{});
    defer doc.deinit();
    // Budget: 100,000 bytes, so two uses of a 40,001 byte destination.
    try testing.expectEqual(@as(usize, 2), countKind(doc.root, .link));
}

test "ordinary use of references stays within the budget" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "[a]: https://example.com/a/page \"Title\"\n\n");
    for (0..2000) |_| try src.appendSlice(gpa, "[a] ");
    var doc = try md.Document.parse(gpa, src.items, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2000), countKind(doc.root, .link));
}

test "the number of nodes is limited" {
    const gpa = testing.allocator;
    // One node of each way of making them: blocks, inlines, cells, autolinks.
    const src = "- *a* www.b.com\n\n| c |\n| - |\n| d |\n\nT\n: e\n";
    var doc = try md.Document.parse(gpa, src, .{ .extensions = md.Extensions.all });
    var count: usize = 0;
    var walker = md.Walker.init(doc.root);
    while (walker.next()) |ev| {
        if (ev.entering) count += 1;
    }
    doc.deinit();
    // The parser also makes nodes that it removes again, so the exact
    // threshold lies at or above the size of the finished tree.
    var needed: usize = 1;
    while (needed < 10 * count) : (needed += 1) {
        var d = md.Document.parse(gpa, src, .{ .extensions = md.Extensions.all, .max_nodes = needed }) catch |e| {
            try testing.expectEqual(error.InputTooLarge, e);
            continue;
        };
        d.deinit();
        break;
    }
    try testing.expect(needed >= count and needed < 10 * count);
}
