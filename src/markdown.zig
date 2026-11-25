//! Writes a tree back out as CommonMark (plus the extensions the tree was
//! parsed with), so a document can be read, edited and saved as Markdown.
//!
//! The text is not the original text: the tree does not remember how a
//! construct was spelled. What is kept is the meaning (parsing the output gives
//! a tree that renders to the same HTML) and everything that is stored
//! verbatim, above all **raw HTML, and with it `<!-- comments -->`**, which are
//! `html_block` and `html_inline` nodes and are written as read (later lines of
//! a tag that spans lines are indented). Front matter is written back with its
//! body and its fence lines unchanged.
//!
//! What is normalised: headings are ATX (`# x`), code is fenced, emphasis is
//! `_x_` (or `*x*` inside a word) and `**x**`, thematic breaks are `___`,
//! bullets keep their character except that neighbouring lists alternate so
//! they stay separate, links are inline (`[x](url "title")`; reference
//! definitions are resolved and not written), tables are padded with single
//! spaces. Text is backslash-escaped where it could be mistaken for markup.
//!
//! Where no Markdown spelling of some emphasis reads back correctly, it is
//! written as `<em>`, `<strong>` or `<del>`.
//!
//! Nesting deeper than `max_depth` fails with `error.TooDeep` instead of
//! exhausting the stack.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const Kind = ast.Kind;
const Extensions = @import("options.zig").Extensions;
const unicode = @import("unicode.zig");
const inl = @import("inline.zig");
const html = @import("html.zig");
const block_parser = @import("block.zig").Parser;

pub const Error = Io.Writer.Error || Allocator.Error || error{TooDeep};

pub const max_depth = 200;

/// Writes `root` (a document node) as Markdown.
pub fn write(gpa: Allocator, root: *Node, ext: Extensions, w: *Io.Writer) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var g: Gen = .{ .gpa = gpa, .a = arena.allocator(), .ext = ext };
    const out = try g.blocks(root, false);
    try w.writeAll(out);
}

const Gen = struct {
    gpa: Allocator,
    a: Allocator,
    ext: Extensions,
    depth: u32 = 0,
    in_cell: bool = false,
    /// How emphasis is being spelled; see `leaf`.
    spelling: Spelling = .usual,
    /// Emphasis containers around the inline being written.
    emphasis_depth: u32 = 0,

    const Spelling = enum {
        /// `_x_` (or `*x*` beside letters), `**x**`, `~~x~~`.
        usual,
        stars,
        underscores,
        /// `*` and `_` taking turns from one level of nesting to the next.
        alternating,
        /// Raw `<em>`, `<strong>` and `<del>`: renders the same where no
        /// Markdown spelling does.
        tags,
    };

    fn enter(self: *Gen) Error!void {
        if (self.depth >= max_depth) return error.TooDeep;
        self.depth += 1;
    }

    // ---- blocks ------------------------------------------------------------

    /// The children of `parent` as blocks. Each block ends with a newline;
    /// blocks are separated by a blank line unless `tight`.
    fn blocks(self: *Gen, parent: *Node, tight: bool) Error![]const u8 {
        try self.enter();
        defer self.depth -= 1;
        const result = self.a;
        var out: std.ArrayList(u8) = .empty;
        // Each child's working memory is freed once its text is in `out`.
        // Otherwise every level of nesting would keep its own copy of all the
        // text below it.
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        var child = parent.first_child;
        var prev: ?*Node = null;
        while (child) |c| : (child = c.next) {
            if (prev != null and !tight) try out.append(result, '\n');
            _ = scratch.reset(.retain_capacity);
            self.a = scratch.allocator();
            defer self.a = result;
            const text = try self.block(c, prev);
            try out.appendSlice(result, text);
            if (text.len == 0 or text[text.len - 1] != '\n') try out.append(result, '\n');
            prev = c;
        }
        return out.items;
    }

    fn block(self: *Gen, n: *Node, prev: ?*Node) Error![]const u8 {
        switch (n.kind) {
            .paragraph => return self.line(try self.leaf(n, .paragraph)),
            .heading => {
                var out: std.ArrayList(u8) = .empty;
                try out.appendNTimes(self.a, '#', @max(@as(u8, 1), @min(n.level, 6)));
                if (n.level <= 2 and hasBreak(n)) {
                    const body = try self.leaf(n, .paragraph);
                    const under: []const u8 = if (n.level == 1) "===\n" else "---\n";
                    return std.mem.concat(self.a, u8, &.{ body, "\n", under });
                }
                const body = try self.leaf(n, .heading);
                if (body.len != 0) {
                    try out.append(self.a, ' ');
                    try out.appendSlice(self.a, body);
                }
                return self.line(out.items);
            },
            // `_` is never a list marker, so no marker before this can join it.
            .thematic_break => return "___\n",
            .html_block => return self.line(n.literal),
            .front_matter => {
                // A tree built elsewhere may not say how the fences were typed.
                var fences = std.mem.splitScalar(u8, n.title, '\n');
                const open = if (n.title.len != 0) fences.first() else "---";
                const close = fences.next() orelse "---";
                return try std.fmt.allocPrint(self.a, "{s}\n{s}{s}\n", .{ open, n.literal, close });
            },
            .code_block => return self.codeBlock(n),
            .block_quote => {
                const inner = try self.blocks(n, false);
                if (inner.len == 0) return ">\n";
                return self.prefixed(inner, "> ", "> ");
            },
            .list => return self.list(n, prev),
            .table => return self.table(n),
            .footnote_def => {
                const inner = try self.blocks(n, false);
                const head = try std.fmt.allocPrint(self.a, "[^{s}]: ", .{n.literal});
                if (inner.len == 0) return head;
                return self.prefixed(inner, head, "    ");
            },
            .deflist => return self.deflist(n),
            // Inlines or parts of a larger node never reach here from a valid tree;
            // treat a stray one as a paragraph of its own.
            else => return self.line(try self.inlineNode(n, .paragraph, false)),
        }
    }

    fn hasBreak(n: *Node) bool {
        var w = ast.Walker.init(n);
        while (w.next()) |ev| {
            if (!ev.entering) continue;
            switch (ev.node.kind) {
                .softbreak, .linebreak => return true,
                .html_inline => if (std.mem.findScalar(u8, ev.node.literal, '\n') != null) return true,
                else => {},
            }
        }
        return false;
    }

    fn line(self: *Gen, s: []const u8) []const u8 {
        _ = self;
        return s;
    }

    /// `info` as it must be written after a fence of `fence` characters: the
    /// tree holds it with escapes and references already replaced.
    fn infoString(self: *Gen, out: *std.ArrayList(u8), info: []const u8, fence: u8) Error!void {
        // A space keeps it from lengthening the fence.
        if (info.len != 0 and info[0] == fence) try out.append(self.a, ' ');
        for (info, 0..) |c, i| {
            // White space at either end would be trimmed away.
            const at_end = i == 0 or i + 1 == info.len;
            switch (c) {
                '\\' => try out.appendSlice(self.a, "\\\\"),
                '&' => try out.appendSlice(self.a, if (startsReference(info[i + 1 ..])) "\\&" else "&"),
                '\n' => try out.appendSlice(self.a, "&#10;"),
                '\r' => try out.appendSlice(self.a, "&#13;"),
                ' ' => try out.appendSlice(self.a, if (at_end) "&#32;" else " "),
                '\t' => try out.appendSlice(self.a, if (at_end) "&#9;" else "\t"),
                else => try out.append(self.a, c),
            }
        }
    }

    /// Whether `&` followed by `rest` could be read as a character reference.
    fn startsReference(rest: []const u8) bool {
        return rest.len != 0 and (std.ascii.isAlphanumeric(rest[0]) or rest[0] == '#');
    }

    fn codeBlock(self: *Gen, n: *Node) Error![]const u8 {
        const info = n.title;
        const ch: u8 = if (std.mem.findScalar(u8, info, '`') != null) '~' else '`';
        var len: usize = 3;
        // The fence must be longer than any run of the fence character that
        // starts a line of the code.
        var it = std.mem.splitScalar(u8, n.literal, '\n');
        while (it.next()) |l| {
            const t = std.mem.trimStart(u8, l, " ");
            var run: usize = 0;
            while (run < t.len and t[run] == ch) run += 1;
            if (run >= len) len = run + 1;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendNTimes(self.a, ch, len);
        try self.infoString(&out, info, ch);
        try out.append(self.a, '\n');
        try out.appendSlice(self.a, n.literal);
        if (n.literal.len != 0 and n.literal[n.literal.len - 1] != '\n') try out.append(self.a, '\n');
        try out.appendNTimes(self.a, ch, len);
        try out.append(self.a, '\n');
        return out.items;
    }

    fn list(self: *Gen, n: *Node, prev: ?*Node) Error![]const u8 {
        const ld = n.list;
        // Two lists in a row with the same marker would read as one list.
        const after_list = prev != null and prev.?.kind == .list and prev.?.list.kind == ld.kind;
        var bullet: u8 = if (ld.bullet_char == '*' or ld.bullet_char == '+' or ld.bullet_char == '-') ld.bullet_char else '-';
        var delim: u8 = if (ld.delimiter == ')') ')' else '.';
        if (after_list) {
            const pb = prev.?.list;
            if (ld.kind == .bullet) {
                const pc: u8 = if (pb.bullet_char == '*' or pb.bullet_char == '+' or pb.bullet_char == '-') pb.bullet_char else '-';
                if (pc == bullet) bullet = if (bullet == '-') '*' else '-';
            } else {
                const pd: u8 = if (pb.delimiter == ')') ')' else '.';
                if (pd == delim) delim = if (delim == '.') ')' else '.';
            }
        }

        // An indented HTML block after the list must stay outside it, so the
        // items' text has to be indented further than the block is.
        var indent_after: usize = 0;
        if (n.next) |after| if (after.kind == .html_block) {
            indent_after = after.literal.len - std.mem.trimStart(u8, after.literal, " ").len;
        };

        var out: std.ArrayList(u8) = .empty;
        var number: u32 = ld.start;
        var item = n.first_child;
        var first = true;
        while (item) |it| : (item = it.next) {
            if (!first and !ld.tight) try out.append(self.a, '\n');
            first = false;
            var marker: []const u8 = if (ld.kind == .bullet)
                try std.fmt.allocPrint(self.a, "{c} ", .{bullet})
            else
                try std.fmt.allocPrint(self.a, "{d}{c} ", .{ number, delim });
            if (marker.len <= indent_after and indent_after < 4) {
                const wider = try self.a.alloc(u8, indent_after + 1);
                @memset(wider, ' ');
                @memcpy(wider[0..marker.len], marker);
                marker = wider;
            }
            // A marker has at most nine digits; only the first number counts.
            if (number < 999_999_999) number += 1;
            var inner = try self.itemBody(it, ld.tight);
            const pad = try self.a.alloc(u8, marker.len);
            @memset(pad, ' ');
            if (it.task != .none and self.ext.task_lists) {
                const box: []const u8 = if (it.task == .checked) "[x]" else "[ ]";
                // The box shares a line only with a paragraph's text.
                const text_follows = if (it.first_child) |f| f.kind == .paragraph else false;
                const between: []const u8 = if (text_follows) " " else "\n";
                inner = if (inner.len == 0)
                    try std.mem.concat(self.a, u8, &.{ box, "\n" })
                else
                    try std.mem.concat(self.a, u8, &.{ box, between, inner });
            }
            if (inner.len == 0) {
                try out.appendSlice(self.a, std.mem.trimEnd(u8, marker, " "));
                try out.append(self.a, '\n');
                continue;
            }
            // Nested markers can add up to a thematic break (`- - -`).
            const first_line = try std.mem.concat(self.a, u8, &.{ marker, inner[0 .. std.mem.findScalar(u8, inner, '\n') orelse inner.len] });
            var unused: usize = 0;
            if (inner[0] == ' ' or block_parser.isThematicBreak(first_line, &unused)) {
                // Spaces after the marker would count as part of it, so an
                // indented first line starts on the next one. So does one that
                // would turn the line into a rule.
                try out.appendSlice(self.a, std.mem.trimEnd(u8, marker, " "));
                try out.append(self.a, '\n');
                try out.appendSlice(self.a, try self.prefixed(inner, pad, pad));
                continue;
            }
            try out.appendSlice(self.a, try self.prefixed(inner, marker, pad));
        }
        return out.items;
    }

    fn itemBody(self: *Gen, item: *Node, tight: bool) Error![]const u8 {
        return self.blocks(item, tight);
    }

    fn deflist(self: *Gen, n: *Node) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var child = n.first_child;
        var prev: ?Kind = null;
        while (child) |c| : (child = c.next) {
            // A term is followed at once by its first definition; a blank line
            // between definitions (or before the next term) makes the list loose.
            if (prev != null and !n.list.tight and !(prev.? == .deflist_term and c.kind == .deflist_term) and
                !(prev.? == .deflist_term and c.kind == .deflist_def)) try out.append(self.a, '\n');
            switch (c.kind) {
                .deflist_term => {
                    try out.appendSlice(self.a, try self.leaf(c, .paragraph));
                    try out.append(self.a, '\n');
                },
                else => {
                    const inner = try self.blocks(c, n.list.tight);
                    // An empty definition still needs the space after `:`.
                    try out.appendSlice(self.a, if (inner.len == 0) ": \n" else try self.prefixed(inner, ": ", "  "));
                },
            }
            prev = c.kind;
        }
        return out.items;
    }

    fn table(self: *Gen, n: *Node) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const saved = self.in_cell;
        self.in_cell = true;
        defer self.in_cell = saved;
        var row = n.first_child;
        var first = true;
        while (row) |r| : (row = r.next) {
            try out.append(self.a, '|');
            var cell = r.first_child;
            while (cell) |c| : (cell = c.next) {
                try out.append(self.a, ' ');
                // The table parser takes one backslash from before each pipe,
                // so each gets one, wherever in the cell it is.
                for (try self.leaf(c, .cell)) |byte| {
                    if (byte == '|') try out.append(self.a, '\\');
                    try out.append(self.a, byte);
                }
                try out.appendSlice(self.a, " |");
            }
            try out.append(self.a, '\n');
            if (first) {
                first = false;
                try out.append(self.a, '|');
                var h = r.first_child;
                while (h) |c| : (h = c.next) {
                    try out.appendSlice(self.a, switch (c.align_) {
                        .none => " --- |",
                        .left => " :-- |",
                        .center => " :-: |",
                        .right => " --: |",
                    });
                }
                try out.append(self.a, '\n');
            }
        }
        return out.items;
    }

    /// `text` with `first` before its first line and `rest` before the others.
    /// Blank lines get the prefix without its trailing spaces.
    fn prefixed(self: *Gen, text: []const u8, first: []const u8, rest: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) {
            // The text ends with a newline, so the last piece is empty.
            if (it.peek() == null and l.len == 0) break;
            const p = if (i == 0) first else rest;
            if (l.len == 0) {
                try out.appendSlice(self.a, std.mem.trimEnd(u8, p, " "));
            } else {
                try out.appendSlice(self.a, p);
                try out.appendSlice(self.a, l);
            }
            try out.append(self.a, '\n');
        }
        return out.items;
    }

    // ---- inlines -----------------------------------------------------------

    const Ctx = enum { paragraph, heading, cell };

    /// The inline content of a paragraph, heading, term or cell. Whether a
    /// delimiter opens or closes emphasis depends on everything around it, so
    /// content with emphasis is read back, and spelled another way until it
    /// renders as the original does.
    fn leaf(self: *Gen, parent: *Node, ctx: Ctx) Error![]const u8 {
        const spelled = try self.spell(parent, ctx);
        if (ctx != .paragraph) return spelled;
        // A term after another term continues the same paragraph.
        const continues = parent.kind == .deflist_term and parent.prev != null and parent.prev.?.kind == .deflist_term;
        return self.guardLines(spelled, !continues);
    }

    /// Keeps a line of a paragraph that starts with inline HTML from being read
    /// as the start of an HTML block. A line indented by four cannot start one,
    /// and the indent of a continuation line is not part of its text. The first
    /// line cannot be indented (it would be code), so a link reference
    /// definition, which shows nothing, goes before it.
    fn guardLines(self: *Gen, s: []const u8, starts_paragraph: bool) Error![]const u8 {
        if (std.mem.findScalar(u8, s, '<') == null) return s;
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, s, '\n');
        var index: usize = 0;
        while (lines.next()) |l| : (index += 1) {
            if (index != 0) try out.append(self.a, '\n');
            const first = index == 0 and starts_paragraph;
            const t = std.mem.trimStart(u8, l, " ");
            const kind = if (l.len - t.len < 4) block_parser.htmlBlockKind(t) else 0;
            // Only kinds 1 to 6 can interrupt a paragraph.
            if (kind != 0 and (first or kind < 7)) {
                try out.appendSlice(self.a, if (first) "[//]: #\n    " else "    ");
            }
            try out.appendSlice(self.a, l);
        }
        return out.items;
    }

    fn spell(self: *Gen, parent: *Node, ctx: Ctx) Error![]const u8 {
        const first = try self.inlines(parent, ctx);
        if (!hasEmphasis(parent)) return first;
        var footnotes: html.Footnotes = .empty;
        const want = try self.innerHtml(parent, &footnotes, true);
        if (try self.readsAs(first, &footnotes, want)) return first;
        defer self.spelling = .usual;
        for ([_]Spelling{ .stars, .underscores, .alternating, .tags }) |spelling| {
            self.spelling = spelling;
            const again = try self.inlines(parent, ctx);
            if (try self.readsAs(again, &footnotes, want)) return again;
        }
        return first;
    }

    fn hasEmphasis(n: *Node) bool {
        var w = ast.Walker.init(n);
        while (w.next()) |ev| switch (ev.node.kind) {
            .emph, .strong, .strikethrough => return true,
            else => {},
        };
        return false;
    }

    /// The HTML of what is inside `n`. With `define`, a stand-in definition is
    /// made in `footnotes` for every footnote referred to.
    fn innerHtml(self: *Gen, n: *Node, footnotes: *html.Footnotes, define: bool) Error![]const u8 {
        if (define) {
            var w = ast.Walker.init(n);
            while (w.next()) |ev| {
                if (ev.node.kind != .footnote_ref) continue;
                const def = try self.a.create(Node);
                def.* = .{ .kind = .footnote_def };
                try footnotes.put(self.a, ev.node.literal, def);
            }
        }
        var out: Io.Writer.Allocating = .init(self.a);
        var child = n.first_child;
        while (child) |c| : (child = c.next) {
            html.write(self.gpa, c, footnotes, self.ext, .{}, &out.writer) catch |e| switch (e) {
                error.WriteFailed => return error.OutOfMemory,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        return out.written();
    }

    /// Whether `written`, parsed as inline content, renders to `want`.
    fn readsAs(self: *Gen, written: []const u8, footnotes: *html.Footnotes, want: []const u8) Error!bool {
        const node = try self.a.create(Node);
        node.* = .{ .kind = .paragraph, .literal = written };
        var refs: inl.RefMap = .empty;
        var nodes: ast.NodeBudget = .{ .left = std.math.maxInt(usize) };
        try inl.processTree(self.a, node, &refs, footnotes, self.ext, 0, &nodes);
        return std.mem.eql(u8, want, try self.innerHtml(node, footnotes, false));
    }

    fn inlines(self: *Gen, parent: *Node, ctx: Ctx) Error![]const u8 {
        try self.enter();
        defer self.depth -= 1;
        var out: std.ArrayList(u8) = .empty;
        var bol = true;
        var child = parent.first_child;
        while (child) |c| {
            child = c.next;
            switch (c.kind) {
                .softbreak => {
                    try out.appendSlice(self.a, if (ctx == .paragraph) "\n" else " ");
                    bol = ctx == .paragraph;
                },
                .linebreak => {
                    try out.appendSlice(self.a, if (ctx == .paragraph) "\\\n" else " ");
                    bol = ctx == .paragraph;
                },
                .text => {
                    // Escapes split text into several nodes; read them as one.
                    var run: std.ArrayList(u8) = .empty;
                    var last = c;
                    try run.appendSlice(self.a, c.literal);
                    while (last.next) |nx| : (last = nx) {
                        if (nx.kind != .text) break;
                        try run.appendSlice(self.a, nx.literal);
                    }
                    // White space before a line ending, or at the end of the
                    // block, is kept only as references.
                    const at_end = if (last.next) |nx|
                        nx.kind == .softbreak or nx.kind == .linebreak
                    else switch (parent.kind) {
                        .paragraph, .heading, .table_cell, .deflist_term => true,
                        else => false,
                    };
                    var kept = run.items.len;
                    if (at_end) {
                        while (kept != 0 and std.mem.findScalar(u8, " \t\x0b\x0c", run.items[kept - 1]) != null) kept -= 1;
                    }
                    try self.escape(&out, run.items[0..kept], last.next, bol);
                    for (run.items[kept..]) |ws| try out.print(self.a, "&#{d};", .{ws});
                    bol = false;
                    child = last.next;
                },
                else => {
                    try out.appendSlice(self.a, try self.inlineNode(c, ctx, bol));
                    bol = false;
                },
            }
        }
        var s = out.items;
        // A closing run of `#` would be read as part of the heading marker.
        if (ctx == .heading and s.len != 0 and s[s.len - 1] == '#') {
            const idx = s.len - 1;
            if (idx == 0 or s[idx - 1] != '\\') {
                s = try std.mem.concat(self.a, u8, &.{ s[0..idx], "\\#" });
            }
        }
        return s;
    }

    fn inlineNode(self: *Gen, n: *Node, ctx: Ctx, bol: bool) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        switch (n.kind) {
            .text => try self.escape(&out, n.literal, n.next, bol),
            .code => try self.codeSpan(&out, n.literal),
            .html_inline => for (n.literal) |byte| {
                try out.append(self.a, byte);
                // A later line of a tag must not start a block. The indent of a
                // continuation line is not part of the text.
                if (byte == '\n' and ctx == .paragraph) try out.appendSlice(self.a, "    ");
            },
            .emph, .strong, .strikethrough => try self.emphasis(&out, n, ctx),
            .link, .image => {
                if (n.kind == .image) try out.append(self.a, '!');
                try out.append(self.a, '[');
                try out.appendSlice(self.a, try self.inlines(n, ctx));
                try out.appendSlice(self.a, "](");
                try self.destination(&out, n.literal);
                if (n.title.len != 0) {
                    try out.appendSlice(self.a, " \"");
                    for (n.title, 0..) |c, i| {
                        if (c == '\n') {
                            try out.appendSlice(self.a, "&#10;");
                            continue;
                        }
                        if (c == '"' or c == '\\' or (c == '&' and startsReference(n.title[i + 1 ..]))) try out.append(self.a, '\\');
                        try out.append(self.a, c);
                    }
                    try out.append(self.a, '"');
                }
                try out.append(self.a, ')');
            },
            .footnote_ref => {
                try out.appendSlice(self.a, "[^");
                try out.appendSlice(self.a, n.literal);
                try out.append(self.a, ']');
            },
            .softbreak => try out.append(self.a, '\n'),
            .linebreak => try out.appendSlice(self.a, "\\\n"),
            else => {},
        }
        return out.items;
    }

    fn emphasis(self: *Gen, out: *std.ArrayList(u8), n: *Node, ctx: Ctx) Error!void {
        const mark: []const u8 = switch (self.spelling) {
            .usual => if (n.kind == .emph and !self.intraword(n)) "_" else "*",
            .stars, .tags => "*",
            .underscores => "_",
            .alternating => if (self.emphasis_depth % 2 == 0) "*" else "_",
        };
        var open: []const u8 = mark;
        var close: []const u8 = mark;
        if (n.kind == .strong) {
            open = try std.mem.concat(self.a, u8, &.{ mark, mark });
            close = open;
        } else if (n.kind == .strikethrough) {
            open = "~~";
            close = open;
        }
        if (self.spelling == .tags) {
            open, close = switch (n.kind) {
                .emph => .{ "<em>", "</em>" },
                .strong => .{ "<strong>", "</strong>" },
                else => .{ "<del>", "</del>" },
            };
        }
        self.emphasis_depth += 1;
        defer self.emphasis_depth -= 1;
        try out.appendSlice(self.a, open);
        try out.appendSlice(self.a, try self.inlines(n, ctx));
        try out.appendSlice(self.a, close);
    }

    /// A letter, as the emphasis rules see it (the test `inline.zig` makes).
    fn isWordChar(cp: u21) bool {
        return !unicode.isUnicodeWhitespace(cp) and !unicode.isUnicodePunct(cp);
    }

    /// Is the emphasis `n` written next to a letter or digit? `_` would not
    /// open or close emphasis there.
    fn intraword(self: *Gen, n: *Node) bool {
        _ = self;
        // `_` directly inside `_` would read as `__`.
        if (n.first_child) |f| if (f.kind == .emph or f.kind == .strong) return true;
        if (n.last_child) |l| if (l.kind == .emph or l.kind == .strong) return true;
        if (n.prev) |p| {
            if (p.kind == .text and p.literal.len != 0 and isWordChar(unicode.decodeBefore(p.literal, p.literal.len))) return true;
            if (p.kind == .code or p.kind == .emph or p.kind == .strong) return true;
        }
        if (n.next) |nx| {
            if (nx.kind == .text and nx.literal.len != 0 and isWordChar(unicode.decodeAt(nx.literal, 0).cp)) return true;
            if (nx.kind == .code or nx.kind == .emph or nx.kind == .strong) return true;
        }
        return false;
    }

    fn codeSpan(self: *Gen, out: *std.ArrayList(u8), lit: []const u8) Error!void {
        // The fence is a backtick run no other run in the code can equal.
        var longest: usize = 0;
        var run: usize = 0;
        for (lit) |c| {
            if (c == '`') {
                run += 1;
                longest = @max(longest, run);
            } else run = 0;
        }
        // Find a length not used by any run.
        var len: usize = 1;
        while (true) : (len += 1) {
            var used = false;
            var r: usize = 0;
            for (lit, 0..) |c, i| {
                if (c == '`') r += 1;
                if (c != '`' or i + 1 == lit.len or lit[i + 1] != '`') {
                    if (c == '`' and r == len) used = true;
                    r = 0;
                }
            }
            if (!used) break;
        }
        const pad = lit.len != 0 and (lit[0] == '`' or lit[lit.len - 1] == '`' or
            (lit[0] == ' ' and lit[lit.len - 1] == ' ' and std.mem.trim(u8, lit, " ").len != 0));
        try out.appendNTimes(self.a, '`', len);
        if (pad) try out.append(self.a, ' ');
        for (lit) |c| {
            try out.append(self.a, c);
        }
        if (pad) try out.append(self.a, ' ');
        try out.appendNTimes(self.a, '`', len);
    }

    fn destination(self: *Gen, out: *std.ArrayList(u8), dest: []const u8) Error!void {
        var plain = dest.len != 0;
        var depth: i32 = 0;
        for (dest) |c| {
            if (c <= ' ' or c == 0x7F) plain = false;
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth < 0) plain = false;
            }
        }
        if (depth != 0) plain = false;
        if (plain) {
            for (dest, 0..) |c, i| {
                if (c == '\\' or (c == '&' and i + 1 < dest.len and (std.ascii.isAlphanumeric(dest[i + 1]) or dest[i + 1] == '#')) or c == '<' and i == 0)
                    try out.append(self.a, '\\');
                try out.append(self.a, c);
            }
            return;
        }
        try out.append(self.a, '<');
        for (dest, 0..) |c, i| {
            if (c == '\n') {
                try out.appendSlice(self.a, "%0A");
                continue;
            }
            if (c == '<' or c == '>' or c == '\\' or (c == '&' and i + 1 < dest.len and (std.ascii.isAlphanumeric(dest[i + 1]) or dest[i + 1] == '#')))
                try out.append(self.a, '\\');
            try out.append(self.a, c);
        }
        try out.append(self.a, '>');
    }

    /// Text with a backslash before whatever might start markup.
    fn escape(self: *Gen, out: *std.ArrayList(u8), s: []const u8, after: ?*Node, bol: bool) Error!void {
        var at_start = bol;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
            var esc = false;
            switch (c) {
                '\n' => {
                    try out.appendSlice(self.a, "&#10;");
                    continue;
                },
                '\r' => {
                    try out.appendSlice(self.a, "&#13;");
                    continue;
                },
                ' ', '\t', 0x0b, 0x0c => if (at_start) {
                    try out.print(self.a, "&#{d};", .{c});
                    at_start = false;
                    continue;
                },
                '\\', '`', '*', '[', ']', '<' => esc = true,
                '_' => {
                    // Inside a word `_` cannot open or close emphasis. (Only
                    // ASCII is relied on here: elsewhere it is escaped.)
                    const prev_alnum = if (i > 0) std.ascii.isAlphanumeric(s[i - 1]) else false;
                    const next_alnum = std.ascii.isAlphanumeric(next);
                    esc = !(prev_alnum and next_alnum);
                },
                '&' => esc = std.ascii.isAlphanumeric(next) or next == '#',
                '!' => esc = next == '[' or (i + 1 == s.len and after != null and (after.?.kind == .link or after.?.kind == .footnote_ref)),
                '~' => esc = self.ext.strikethrough or at_start,
                // In a cell every pipe is escaped later, by `table`.
                '|' => esc = self.ext.tables and !self.in_cell,
                '#', '>', '-', '+', '=' => esc = at_start,
                ':' => esc = at_start and self.ext.definition_lists,
                '0'...'9' => {
                    if (at_start) {
                        var j = i;
                        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
                        if (j < s.len and (s[j] == '.' or s[j] == ')')) {
                            try out.appendSlice(self.a, s[i..j]);
                            try out.append(self.a, '\\');
                            try out.append(self.a, s[j]);
                            i = j;
                            at_start = false;
                            continue;
                        }
                    }
                },
                else => {},
            }
            if (esc) try out.append(self.a, '\\');
            try out.append(self.a, c);
            if (c != ' ' and c != '\t') at_start = false;
        }
    }
};
