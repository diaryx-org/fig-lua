# Changelog

What has changed in fig-lua, release by release, for someone deciding
whether to move to a newer one.

Two halves, written two different ways.

The bulleted groups below — **Added**, **Fixed**, **Changed**, and a
**Behavioural changes** section under them — are **generated** from the commit
log by `dx changelog --write`, which reads one shared `cliff.toml` — the same
file, and the same style, in every repository here. Anything inside a
`git-cliff:begin` / `git-cliff:end` pair is rewritten on every run, so an edit
made there is an edit thrown away.

Everything else is handwritten and stays: this prose, and any intro a release
needs under its own heading, below the end marker where regeneration cannot
reach it.

**Behavioural changes** are collected from `Behavioural-change:` trailers on the
commits themselves, not from their subjects — because "would a reader who
upgrades without editing a line of their own code observe a difference" is a
judgment about the change that no subject can carry. Write one trailer per
observable difference, as prose someone can act on.

Two kinds of change here deserve a trailer that would not obviously need one
elsewhere:

- **Anything that changes the table a shipped script produces.** A twin is
  held to its compiled sibling row for row, so a span that moves in
  `dotenv.lua` is a span that moves for whoever reads it through `fig`, even
  when the compiled format moved first and the script is only following.
- **Anything that changes what the `fig` global does** — a field a row gains,
  an id that renumbers, a helper that starts trimming. Every script ever
  written runs against it.

## Unreleased

<!-- git-cliff:begin — generated; edits here are overwritten -->

### Added

- fig-lua, a fig format written in Lua, and dotenv.lua as the first twin ([`dde46e3`](https://github.com///commit/dde46e3bd4222b409b4cd1f1028580b7b1775fef))
- plist.lua, the twin of fig's compiled plist, with its two renderers ([`38ffb4e`](https://github.com///commit/38ffb4e25b719afd2d6605f8b83a5306221eeb80))
- fig.grammar, a format as a description, with the twins rewritten against it ([`14f4041`](https://github.com///commit/14f40419ecd6c9f8098efb7ef9578140d3abf48a))

### Behavioural changes

- `fig.fail(message, at)` raises rather than returning `nil, message, at`. A script that wrote `return fig.fail(...)` is unchanged; one that called it and went on to do something else no longer reaches that code.

- `fig.index` sets `items`, `key` and `value` on rows; a script that used those names for its own bookkeeping on a row will find them overwritten.

- on a dotenv input with more than one error, `dotenv.lua` reports the first in the file rather than the one the compiled tokenizer would have found first; a file with one error is refused exactly as before.

<!-- git-cliff:end -->
