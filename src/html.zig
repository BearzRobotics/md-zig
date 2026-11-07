//! Renders a tree as HTML, byte for byte like the CommonMark reference
//! implementation, so the spec examples can be compared exactly.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const Node = ast.Node;

pub const Error = Io.Writer.Error;

const Renderer = struct {
    w: *Io.Writer,
    /// Last byte written, to decide whether a line break is needed.
    last: u8 = '\n',
    /// Greater than 0 inside an image description, where tags are left out.
    no_tags: u32 = 0,

    fn lit(self: *Renderer, s: []const u8) Error!void {
        if (s.len == 0) return;
        try self.w.writeAll(s);
        self.last = s[s.len - 1];
    }

    fn cr(self: *Renderer) Error!void {
        if (self.last != '\n') try self.lit("\n");
    }

    fn esc(self: *Renderer, s: []const u8) Error!void {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            const rep: []const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => continue,
            };
            try self.lit(s[start..i]);
            try self.lit(rep);
            start = i + 1;
        }
        try self.lit(s[start..]);
    }

    fn open(self: *Renderer, name: []const u8) Error!void {
        if (self.no_tags > 0) return;
        try self.lit("<");
        try self.lit(name);
        try self.lit(">");
    }

    fn close(self: *Renderer, name: []const u8) Error!void {
        if (self.no_tags > 0) return;
        try self.lit("</");
        try self.lit(name);
        try self.lit(">");
    }

    fn render(self: *Renderer, root: *Node) Error!void {
        var walker = ast.Walker.init(root);
        while (walker.next()) |ev| try self.node(ev.node, ev.entering);
    }

    fn node(self: *Renderer, n: *Node, entering: bool) Error!void {
        switch (n.kind) {
            .document => {},
            .text => try self.esc(n.literal),
            .softbreak => try self.lit("\n"),
            .linebreak => {
                if (self.no_tags == 0) try self.lit("<br />");
                try self.cr();
            },
            .code => {
                try self.open("code");
                try self.esc(n.literal);
                try self.close("code");
            },
            .html_inline => if (self.no_tags == 0) try self.lit(n.literal),
            .html_block => {
                try self.cr();
                try self.lit(n.literal);
                try self.cr();
            },
            .emph => if (entering) try self.open("em") else try self.close("em"),
            .strong => if (entering) try self.open("strong") else try self.close("strong"),
            .link => {
                if (entering) {
                    if (self.no_tags == 0) {
                        try self.lit("<a href=\"");
                        try self.esc(n.literal);
                        try self.lit("\"");
                        if (n.title.len > 0) {
                            try self.lit(" title=\"");
                            try self.esc(n.title);
                            try self.lit("\"");
                        }
                        try self.lit(">");
                    }
                } else try self.close("a");
            },
            .image => {
                if (entering) {
                    if (self.no_tags == 0) {
                        try self.lit("<img src=\"");
                        try self.esc(n.literal);
                        try self.lit("\" alt=\"");
                    }
                    self.no_tags += 1;
                } else {
                    self.no_tags -= 1;
                    if (self.no_tags == 0) {
                        if (n.title.len > 0) {
                            try self.lit("\" title=\"");
                            try self.esc(n.title);
                        }
                        try self.lit("\" />");
                    }
                }
            },
            .paragraph => {
                // In a tight list the paragraph's tags are left out.
                if (n.parent) |p| if (p.parent) |g| if (g.kind == .list and g.list.tight) return;
                if (entering) {
                    try self.cr();
                    try self.open("p");
                } else {
                    try self.close("p");
                    try self.cr();
                }
            },
            .heading => {
                var buf: [2]u8 = .{ 'h', '0' + n.level };
                if (entering) {
                    try self.cr();
                    try self.open(&buf);
                } else {
                    try self.close(&buf);
                    try self.cr();
                }
            },
            .thematic_break => {
                try self.cr();
                try self.lit("<hr />");
                try self.cr();
            },
            .block_quote => {
                if (entering) {
                    try self.cr();
                    try self.open("blockquote");
                    try self.cr();
                } else {
                    try self.cr();
                    try self.close("blockquote");
                    try self.cr();
                }
            },
            .list => {
                const name = if (n.list.kind == .bullet) "ul" else "ol";
                if (entering) {
                    try self.cr();
                    if (n.list.kind == .ordered and n.list.start != 1) {
                        var b: [16]u8 = undefined;
                        try self.lit("<ol start=\"");
                        try self.lit(std.fmt.bufPrint(&b, "{d}", .{n.list.start}) catch unreachable);
                        try self.lit("\">");
                    } else try self.open(name);
                    try self.cr();
                } else {
                    try self.cr();
                    try self.close(name);
                    try self.cr();
                }
            },
            .item => if (entering) try self.open("li") else {
                try self.close("li");
                try self.cr();
            },
            .code_block => {
                try self.cr();
                try self.lit("<pre><code");
                var words = std.mem.tokenizeAny(u8, n.title, " \t\n\r\x0b\x0c");
                if (words.next()) |lang| {
                    try self.lit(" class=\"language-");
                    try self.esc(lang);
                    try self.lit("\"");
                }
                try self.lit(">");
                try self.esc(n.literal);
                try self.lit("</code></pre>");
                try self.cr();
            },
        }
    }
};

pub fn write(root: *Node, w: *Io.Writer) Error!void {
    var r: Renderer = .{ .w = w };
    try r.render(root);
}
