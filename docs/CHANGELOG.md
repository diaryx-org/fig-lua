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

<!-- git-cliff:begin -->
<!-- git-cliff:end -->
