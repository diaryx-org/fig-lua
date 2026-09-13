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

- fig-lua, a fig format written in Lua, and dotenv.lua as the first twin ([`dde46e3`](https://github.com/diaryx-org/fig-lua/commit/dde46e3bd4222b409b4cd1f1028580b7b1775fef))
- plist.lua, the twin of fig's compiled plist, with its two renderers ([`38ffb4e`](https://github.com/diaryx-org/fig-lua/commit/38ffb4e25b719afd2d6605f8b83a5306221eeb80))
- fig.grammar, a format as a description, with the twins rewritten against it ([`14f4041`](https://github.com/diaryx-org/fig-lua/commit/14f40419ecd6c9f8098efb7ef9578140d3abf48a))
- a value renderer is told fig's `literal`; plist.lua stops classifying ([`a7d66d0`](https://github.com/diaryx-org/fig-lua/commit/a7d66d0a4d9c0011e0e2363d9476d457dfb781af))
- canonical.lua, the twin of fig's canonical form ([`15aa74c`](https://github.com/diaryx-org/fig-lua/commit/15aa74c61f332e14166e4bb735ec0e4edd05f3f6))
- json.lua, the twin of fig's compiled json format ([`e5b7fdd`](https://github.com/diaryx-org/fig-lua/commit/e5b7fdd328f3c32970a1b131fbdf4b12eb21b193))
- toml.lua, the twin of fig's compiled toml format ([`d9b1cbd`](https://github.com/diaryx-org/fig-lua/commit/d9b1cbde1f54cb289cb2fbc06856361b7c69820b))
- ini.lua, the twin of fig's compiled ini format ([`bfa66a6`](https://github.com/diaryx-org/fig-lua/commit/bfa66a6836a307a47ff1f68ab9a578e2d916647f))
- fig.lua, the twin of fig's own authoring dialect ([`5c79e44`](https://github.com/diaryx-org/fig-lua/commit/5c79e443d679a59d14bdc548206008102522a0a3))

### Fixed

- **prelude** — a mapping key with no text is never a duplicate ([`99f43d4`](https://github.com/diaryx-org/fig-lua/commit/99f43d4ae386a28b2c59e720113803a7eeae9306))

### Behavioural changes

- `fig.fail(message, at)` raises rather than returning `nil, message, at`. A script that wrote `return fig.fail(...)` is unchanged; one that called it and went on to do something else no longer reaches that code.

- `fig.index` sets `items`, `key` and `value` on rows; a script that used those names for its own bookkeeping on a row will find them overwritten.

- on a dotenv input with more than one error, `dotenv.lua` reports the first in the file rather than the one the compiled tokenizer would have found first; a file with one error is refused exactly as before.

- `render("value", args)` receives `args.literal`; a script that classified the value itself may now switch on it instead. A script that ignores the field is unaffected.

- `plist.lua` no longer types a bare value by its own rules but by fig's, as handed in; where the two agreed nothing changes, and a host that calls `render` directly must pass `literal` for a value to be typed — absent, it is a string.

- a script whose grammar puts a null or container key into a `G.map` (or calls `map:put` with one) no longer fails with `table index is nil`; the entry is kept under every duplicate policy.

<!-- git-cliff:end -->
