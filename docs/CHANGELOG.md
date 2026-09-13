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
  What a twin says when it refuses a document is its own, and a reworded
  message is not one of these.
- **Anything that changes what the `fig` global or the modules beside it
  do** — `fig.grammar`, `fig.xml`, `fig.number`, `fig.datetime`: a field a
  row gains, an id that renumbers, a helper that starts trimming. Every
  script ever written runs against them.

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
- **grammar** — `G.sections`, what a format of header lines records alike ([`a51c1b7`](https://github.com/diaryx-org/fig-lua/commit/a51c1b78f09a3dbdc397df13cfe37421b842644a))
- **languages** — properties.lua, the twin of fig's compiled `.properties` ([`eaa6a60`](https://github.com/diaryx-org/fig-lua/commit/eaa6a609176cbd79255ad5613b505a9cfbda95a4))
- **languages** — zon.lua, the twin of fig's compiled ZON ([`edd6159`](https://github.com/diaryx-org/fig-lua/commit/edd6159af01ef01422b724cc7e0c0f456f97c981))
- **languages** — json5.lua, the twins of fig's compiled JSONC and JSON5 dialects ([`c60600d`](https://github.com/diaryx-org/fig-lua/commit/c60600d1a63e7f9eaacbb997980987fc1e0b6a32))
- **languages** — nestedtext.lua, the twin of fig's compiled NestedText ([`5475902`](https://github.com/diaryx-org/fig-lua/commit/5475902d39f91f1265e08b3dd5b7bb8c52826d22))
- **prelude** — a table records its tag directives ([`005a0a0`](https://github.com/diaryx-org/fig-lua/commit/005a0a0a79ca081f9fd9ab8c3a31d90840484823))
- **languages** — yaml.lua, the twin of fig's compiled YAML ([`939b4d2`](https://github.com/diaryx-org/fig-lua/commit/939b4d2df25b870d32cd3b059ef530492c8ca2f3))
- **lib** — `fig.number`, `fig.datetime`, and the helpers the twins share ([`2cf6ad3`](https://github.com/diaryx-org/fig-lua/commit/2cf6ad377ac0087ebaf423ebdca78230c8d679b7))

### Fixed

- **prelude** — a mapping key with no text is never a duplicate ([`99f43d4`](https://github.com/diaryx-org/fig-lua/commit/99f43d4ae386a28b2c59e720113803a7eeae9306))
- **languages** — json.lua writes a number another format spelled as JSON reads it ([`faf0e9e`](https://github.com/diaryx-org/fig-lua/commit/faf0e9e694720dc18686e5d0a8532917e94bfaaa))

### Changed

- **languages** — rebase ini, toml and fig on `G.sections` ([`f2ba1a6`](https://github.com/diaryx-org/fig-lua/commit/f2ba1a6335028c5ea0d8ec4a27dc5512d9bfb685))
- **languages** — nestedtext.lua held to the format, not the compiled parser ([`f66bf43`](https://github.com/diaryx-org/fig-lua/commit/f66bf4315c77552373193669fea70dde86e8c1ae))
- **languages** — fig, json, canonical and plist take the shared helpers ([`44b23ea`](https://github.com/diaryx-org/fig-lua/commit/44b23ea661841add4d08efe9303da6feccf6ff25))
- **languages** — ini and properties as grammars; dotenv trimmed ([`cd0789e`](https://github.com/diaryx-org/fig-lua/commit/cd0789ec1c17377e33f371909b11a4a6940dfee6))
- **languages** — json5.lua as a grammar ([`00f2e35`](https://github.com/diaryx-org/fig-lua/commit/00f2e35cdc2c7971e387c2012b627d03e326556b))
- **languages** — toml.lua held to the format, not the compiled parser ([`0385abd`](https://github.com/diaryx-org/fig-lua/commit/0385abd179356898e9d37b6d59357ff35300af25))
- **languages** — zon.lua as a grammar over the format, not a port of Zig's parser ([`cf25a27`](https://github.com/diaryx-org/fig-lua/commit/cf25a276077fac101cf2cf33835acd47c9f5c967))
- **languages** — yaml.lua held to the format, not the compiled parser ([`b9701e0`](https://github.com/diaryx-org/fig-lua/commit/b9701e03d64851147b3ea4cb937a8d0e177dd09a))

### Behavioural changes

- `fig.fail(message, at)` raises rather than returning `nil, message, at`. A script that wrote `return fig.fail(...)` is unchanged; one that called it and went on to do something else no longer reaches that code.

- `fig.index` sets `items`, `key` and `value` on rows; a script that used those names for its own bookkeeping on a row will find them overwritten.

- on a dotenv input with more than one error, `dotenv.lua` reports the first in the file rather than the one the compiled tokenizer would have found first; a file with one error is refused exactly as before.

- `render("value", args)` receives `args.literal`; a script that classified the value itself may now switch on it instead. A script that ignores the field is unaffected.

- `plist.lua` no longer types a bare value by its own rules but by fig's, as handed in; where the two agreed nothing changes, and a host that calls `render` directly must pass `literal` for a value to be typed — absent, it is a string.

- a script whose grammar puts a null or container key into a `G.map` (or calls `map:put` with one) no longer fails with `table index is nil`; the entry is kept under every duplicate policy.

- a `\x`, `\u` or `\U` escape in a double-quoted
scalar now takes exactly its hex digits; `"\u0_41"` and `"\u+041"`, which
the compiled parser's parseInt accepted, are refused as YAML refuses
them.

<!-- git-cliff:end -->
