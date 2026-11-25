# 0004: The official specifications take precedence

Status: accepted by the maintainer in conversation.

## Problem

md-zig's behaviour, its documents and the reference implementations do not
always agree with the published specifications.

## Decision

Where they differ, md-zig follows the official specification:

1. CommonMark 0.31.2 (https://spec.commonmark.org/0.31.2/).
2. The GitHub Flavored Markdown specification (https://github.github.com/gfm/)
   for the GFM extensions.

Where a specification says nothing (footnotes, front matter, definition lists,
or how two rules interact), md-zig follows cmark-gfm, or the project's own
documented rule for an extension cmark-gfm does not have.

Every difference that is found is recorded in the table below.

## Record

| Subject | Specification | Differed | Outcome |
|---|---|---|---|
| Table rows shorter than the header | GFM: "empty cells are inserted" | md-zig padded without limit, so 24 KB of input used 2.9 GB | **Departs from the spec** past `Options.max_padded_cells` (default 524,288 for the document): the table ends there. cmark-gfm has a limit of the same size. |
| Many uses of one reference definition | CommonMark sets no limit | output grew with definition length times uses | **Departs from the spec** past a budget equal to the input size, at least 100,000 bytes: further references stay text. This follows the rule in cmark. |
| Nested parentheses in a bare link destination | CommonMark 6.3: implementations may limit them, supporting at least three levels | unlimited, with quadratic time | Limited to 32, as in cmark. Within the spec. |
| Longest link label | CommonMark 6.3: "at most 999 characters inside the square brackets" | md-zig accepted 1000, as cmark 0.30.2 does | Follows the spec: 999 characters (not bytes). Differs from cmark. |
| Tabs around link destinations and titles | CommonMark 4.7 and 6.3: spaces or tabs | only spaces were accepted | Follows the spec. |
| What ends a table | GFM: the first empty line "or beginning of another block-level structure" | only quotes, headings and fences ended it | Follows the spec: also thematic breaks, list items, HTML blocks and indented code, matching cmark-gfm. Footnote definitions and `: ` lines, which the spec does not cover, stay rows (footnotes as in cmark-gfm). |
| `~a b~~ c~` (an unmatched run of the other length between a pair) | GFM does not say | an audit suspected a bug | No change: md-zig already gives the same output as cmark-gfm. |
| Footnote ids | HTML: ids are unique and `&` is escaped in attributes (footnotes are in neither Markdown spec) | a label `x-2` could repeat the id of the second use of `x`; `&` was not escaped | Keys are escaped. Only where an id would repeat, the suffix gets `-again`; otherwise the ids are those of cmark-gfm. |
| Wide characters in the terminal | Unicode East Asian Width (UAX #11), version 16.0.0: W and F are two columns | hand-written ranges missed many emoji and widened some narrow characters | Follows the Unicode data: some pictographs it calls narrow now count as one column. |
| A footnote reference inside link text | footnotes are in neither Markdown spec; CommonMark forbids links inside links | md-zig treated the reference as a link, so the outer link became text | Follows cmark-gfm: the outer link stands. Note that its HTML puts an `a` element inside another, which HTML does not allow. |
| Unicode punctuation, white space and link label case folding | CommonMark 0.31.2: categories P and S; category Zs with tab, LF, FF, CR; the Unicode case fold | approximated by ranges (a deviation listed in 0001); line tabulation counted as white space | Follows the spec, with tables from the Unicode Character Database 16.0.0. |
| Blank lines in an HTML block that is never closed | CommonMark 4.6: kinds 1 to 5 end only at their end condition or the end of the document | blank lines at the end were dropped | Follows the spec, as cmark does. |
| `[^1](url)` where footnote 1 exists | CommonMark 6.3: an inline link | md-zig made a footnote reference followed by text | Follows the spec, as cmark-gfm does. |

## Seen and left unchanged

Differences from cmark 0.30.2 or cmark-gfm 0.29.0.gfm.13 found while comparing,
where it is not clear that a specification requires a change:

| Subject | md-zig | cmark or cmark-gfm |
|---|---|---|
| A footnote referred to only from footnote definitions that the body never reaches | not listed | listed (cmark-gfm) |
| `\\|` (two backslashes) in a table row | the pipe separates cells | the pipe is part of the cell (cmark-gfm) |
| Spaces on a blank line of an HTML block inside a list item | dropped | kept (cmark) |
| A tab at the end of a line, before a soft line break | kept (the specification speaks of spaces) | removed (cmark) |

## Consequences

- md-zig can differ from cmark or cmark-gfm where they differ from their own
  specification.
- A change that departs from a specification needs an entry here saying why.
