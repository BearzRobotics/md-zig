# md-zig

Markdown parser and renderer for Zig, built on `std.Io`.

- **CommonMark 0.31.2**: all 652 examples of the specification pass, byte for byte.
- **Extensions** (flags in `Extensions`, all off by default): GFM tables,
  strikethrough, task lists, extended autolinks and the tag filter, plus
  footnotes, definition lists and front matter. Of 52 examples from cmark-gfm's
  own suite, 51 give identical output; the other has no defined output and is
  only parsed. Where md-zig and a specification differ, see
  `docs/decisions/0004-spec-precedence.md`.
- **Input** is a `*std.Io.Reader`, read one line at a time. **Output** goes to a
  `*std.Io.Writer`: HTML, or text for a terminal (word-wrapped, optional ANSI).
- No file system or OS calls in the library; one module, no dependencies.

Zig 0.17.1.

```zig
const md = @import("md");

var doc = try md.Document.parse(gpa, "# Hello *world*\n", .{});
defer doc.deinit();
try doc.writeHtml(gpa, writer);        // <h1>Hello <em>world</em></h1>
try doc.writeText(gpa, writer, .{ .width = 80, .color = true });
```

Read from any reader, with extensions:

```zig
var doc = try md.Document.parseReader(gpa, &reader, .{ .extensions = md.Extensions.gfm });
```

**HTML from untrusted input is not safe by default.** As CommonMark specifies,
raw HTML and any link address (including `javascript:`) pass through, and the
`tagfilter` extension only filters GFM's nine tags: it is not a sanitiser. Use
the safe mode, which leaves out raw HTML and empties `javascript:`, `vbscript:`,
`file:` and non-image `data:` addresses (`md_to_safe_html` in C):

```zig
try doc.writeHtmlOptions(gpa, writer, .{ .safe = true });
```

`Options` limit what input can cost: `max_bytes` and `max_line_bytes` bound the
input, and `max_nodes` bounds the tree and so the memory (about 1 GB at the
default). Past them parsing fails with `error.InputTooLarge` or
`error.LineTooLong`. `max_padded_cells` bounds the empty cells added to short
table rows, and link references may only add as many bytes as the input has (at
least 100,000); past those two the text is not treated as a table row or link.

The tree (`doc.root`,
`md.Node`, walked iteratively with `md.Walker`) is public, for consumers that
build their own output, such as a GTK viewer.

Write it back out as Markdown (edit the tree, then save):

```zig
try doc.writeMarkdown(gpa, writer);          // or doc.toMarkdownAlloc(gpa)
```

The output has the same meaning, not the same spelling: parsing it gives a tree
that renders to the same HTML (tested on the 652 CommonMark examples, the GFM
examples, harder cases and random input). Random testing still finds rare
contrived exceptions, about one in a million inputs: an HTML block that starts
with a tab inside a block quote, and some adjacent bare autolinks. Raw HTML, and so `<!-- comments -->`, is
written as read, and front matter keeps its body and fence lines. Where no
Markdown spelling of some emphasis reads back correctly, it is written as
`<em>`, `<strong>` or `<del>`. Headings come out ATX, code fenced, links inline (reference
definitions are resolved and not written), emphasis as `_x_`/`**x**`. Nesting
deeper than 200 fails with `error.TooDeep`.

Try it: `zig build` then `zig-out/bin/mdcat FILE [WIDTH]`.

## C interface (experimental)

An optional C adapter lives in `src/capi.zig` and `include/md.h`; the Zig API
does not depend on it. `zig build c-api` installs `libmd.a`, `libmd.so` and
`md.h`. It is **experimental and unstable**: no source or binary compatibility
is promised between releases. `zig build test` builds and runs a C program
(`test/c/smoke.c`) against it; `zig build test-cc` links the same program with
the system `cc` against both libraries.

```c
md_document *doc;
if (md_parse(src, len, MD_EXT_ALL, &doc) == MD_OK) {
    uint8_t *html; size_t n;
    if (md_to_html(doc, &html, &n) == MD_OK) { fwrite(html, 1, n, stdout); md_free_string(html, n); }
    md_free(doc);
}
```

## Extensions

| Flag | Syntax |
|---|---|
| `tables` | `\| a \| b \|` with a `\| - \| - \|` row, alignment with `:` |
| `strikethrough` | `~text~`, `~~text~~` |
| `task_lists` | `- [ ] item`, `- [x] item` |
| `autolinks` | bare `https://...`, `www....`, `user@example.com` |
| `tagfilter` | `<script>` and eight other raw tags shown as text (not a sanitiser) |
| `footnotes` | `text[^1]` and `[^1]: the note` |
| `definition_lists` | `Term` then `: definition` lines; every line above the first `:` is a term; indented lines continue a definition |
| `front_matter` | a `---` ... `---` block at the very start, kept in the tree, not rendered |

`Extensions.gfm` is the first five; `Extensions.all` is all of them.

## Not done

- The Markdown writer does not keep how a construct was spelled (setext vs ATX, `*` vs `_`, reference-style links, indented code, wrapping).
- A blank line between a term and its `: definition` (the `:` line must follow the term directly).
- The terminal renderer does not draw raw HTML (blocks are shown dimmed, inline
  HTML is dropped) and cuts off containers nested more than 64 deep.

## Tests

`zig build test` runs the CommonMark and GFM suites (`test/fixtures/`, from
https://spec.commonmark.org/0.31.2/spec.json and
https://github.com/github/cmark-gfm), the `std.Io` boundary tests (one-byte
buffers, readers and writers that fail part-way, size limits, leaks), and the
renderer tests. `scripts/gen-entities.py`, `scripts/gen-unicode.py`, `scripts/gen-widths.py`
and `scripts/extract-gfm-examples.py` regenerate `src/entities.zig`,
`src/unicode_tables.zig`, `src/widths.zig` and the GFM fixture.

## Layout

See `docs/architecture.md`. Engineering standards: `ai/AGENTS.md`. License: `LICENSE`.
