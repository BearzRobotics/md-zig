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

## Consequences

- md-zig can differ from cmark or cmark-gfm where they differ from their own
  specification.
- A change that departs from a specification needs an entry here saying why.
