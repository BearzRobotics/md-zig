//! md-zig: a Markdown parser and renderer for Zig, built on `std.Io`.
//!
//! Dialect: CommonMark 0.31.2 (https://spec.commonmark.org/0.31.2/). Input is
//! read line by line from a `std.Io.Reader`; output is written to a
//! `std.Io.Writer`. Nothing here touches the file system or the OS.
//!
//!     var doc = try md.Document.parse(gpa, "# Hello *world*\n", .{});
//!     defer doc.deinit();
//!     try doc.writeHtml(writer);

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ast = @import("ast.zig");
pub const Node = ast.Node;
pub const Kind = ast.Kind;
pub const ListKind = ast.ListKind;
pub const ListData = ast.ListData;
pub const Walker = ast.Walker;
pub const Event = ast.Event;
pub const html = @import("html.zig");
pub const term = @import("term.zig");
pub const markdown = @import("markdown.zig");
pub const TextOptions = term.TextOptions;
pub const HtmlOptions = html.Options;
const block = @import("block.zig");

pub const Options = @import("options.zig").Options;
pub const Extensions = @import("options.zig").Extensions;

pub const ParseError = error{
    OutOfMemory,
    /// The reader failed; see the reader's own error for the cause.
    ReadFailed,
    /// A line, without its ending, is longer than `Options.max_line_bytes`.
    LineTooLong,
    /// The input is longer than `Options.max_bytes`, or its tree would have
    /// more than `Options.max_nodes` nodes.
    InputTooLarge,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    extensions: Extensions = .{},
    footnotes: html.Footnotes = .empty,

    /// Parses a complete text.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options) ParseError!Document {
        var r: Io.Reader = .fixed(source);
        return parseReader(gpa, &r, options);
    }

    /// Parses from a reader, one line at a time. The tree is owned by the
    /// returned document and freed by `deinit`.
    pub fn parseReader(gpa: Allocator, r: *Io.Reader, options: Options) ParseError!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var parser = try block.Parser.init(arena.allocator(), options.extensions);
        parser.max_padded_cells = options.max_padded_cells;
        // The document node is already made.
        parser.nodes.left = options.max_nodes -| 1;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        var total: usize = 0;
        while (true) {
            line.clearRetainingCapacity();
            const end = try readLine(gpa, r, &line, options.max_line_bytes);
            if (end == 0 and line.items.len == 0) break;

            var content: []const u8 = line.items;
            // A byte order mark at the start of the input is not part of the text.
            if (total == 0 and std.mem.startsWith(u8, content, "\u{feff}")) content = content[3..];
            total +|= line.items.len + end;
            if (total > options.max_bytes) return error.InputTooLarge;
            feedLine(&parser, arena.allocator(), content) catch |e| return parser.failure(e);
            if (end == 0) break;
        }
        parser.finish() catch |e| return parser.failure(e);
        return .{ .arena = arena, .root = parser.doc, .extensions = options.extensions, .footnotes = parser.footnotes };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Writes the document as HTML, as CommonMark specifies: raw HTML and
    /// every link address pass through. For input that is not trusted use
    /// `writeHtmlOptions` with `.safe = true`.
    pub fn writeHtml(self: *const Document, gpa: Allocator, w: *Io.Writer) html.Error!void {
        try self.writeHtmlOptions(gpa, w, .{});
    }

    /// Writes the document as HTML with `HtmlOptions`.
    pub fn writeHtmlOptions(self: *const Document, gpa: Allocator, w: *Io.Writer, options: HtmlOptions) html.Error!void {
        try html.write(gpa, self.root, &self.footnotes, self.extensions, options, w);
    }

    /// Writes the document as Markdown (see `markdown.zig`: the meaning and the
    /// raw HTML, including comments, are kept; the spelling is normalised).
    pub fn writeMarkdown(self: *const Document, gpa: Allocator, w: *Io.Writer) markdown.Error!void {
        try markdown.write(gpa, self.root, self.extensions, w);
    }

    /// The document as Markdown in memory, owned by the caller.
    pub fn toMarkdownAlloc(self: *const Document, gpa: Allocator) (Allocator.Error || error{TooDeep})![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.writeMarkdown(gpa, &out.writer) catch |e| switch (e) {
            error.WriteFailed => return error.OutOfMemory,
            else => |other| return other,
        };
        return out.toOwnedSlice();
    }

    /// Writes the document as text for a terminal (see `TextOptions`).
    pub fn writeText(self: *const Document, gpa: Allocator, w: *Io.Writer, options: TextOptions) term.Error!void {
        try term.write(gpa, self.root, &self.footnotes, options, w);
    }

    /// The document as terminal text in memory, owned by the caller.
    pub fn toTextAlloc(self: *const Document, gpa: Allocator, options: TextOptions) Allocator.Error![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.writeText(gpa, &out.writer, options) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// The document as HTML in memory, owned by the caller.
    pub fn toHtmlAlloc(self: *const Document, gpa: Allocator) Allocator.Error![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.writeHtml(gpa, &out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

/// Appends the next line of `r` to `line`, without its ending, which is `\n`,
/// `\r\n` or a lone `\r`. Returns the bytes the ending took: 0 at the end of the
/// input.
fn readLine(gpa: Allocator, r: *Io.Reader, line: *std.ArrayList(u8), max: usize) ParseError!usize {
    while (true) {
        const buffered = r.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => return error.ReadFailed,
        };
        const found = std.mem.findAny(u8, buffered, "\r\n");
        const part = buffered[0 .. found orelse buffered.len];
        if (part.len > max - line.items.len) return error.LineTooLong;
        try line.appendSlice(gpa, part);
        const at = found orelse {
            r.toss(part.len);
            continue;
        };
        const first = buffered[at];
        r.toss(at + 1);
        if (first == '\n') return 1;
        // A `\n` right after `\r` belongs to the same ending.
        const next = r.peekByte() catch |err| switch (err) {
            error.EndOfStream => return 1,
            error.ReadFailed => return error.ReadFailed,
        };
        if (next != '\n') return 1;
        r.toss(1);
        return 2;
    }
}

/// Hands one line (no line ending) to the block parser. NUL becomes U+FFFD.
fn feedLine(parser: *block.Parser, a: Allocator, line: []const u8) Allocator.Error!void {
    if (std.mem.findScalar(u8, line, 0) == null) return parser.feed(line);
    var fixed: std.ArrayList(u8) = .empty;
    for (line) |c| {
        if (c == 0) try fixed.appendSlice(a, "\u{fffd}") else try fixed.append(a, c);
    }
    try parser.feed(fixed.items);
}

test {
    _ = @import("text.zig");
    _ = @import("unicode.zig");
    _ = @import("markdown_tests.zig");
    _ = @import("scan.zig");
    _ = @import("tests.zig");
    _ = @import("io_tests.zig");
    _ = @import("term_tests.zig");
    _ = @import("perf_tests.zig");
}
