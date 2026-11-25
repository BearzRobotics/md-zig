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

## Consequences

- md-zig can differ from cmark or cmark-gfm where they differ from their own
  specification.
- A change that departs from a specification needs an entry here saying why.
