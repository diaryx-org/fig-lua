---
title: fig.lua mentions and prints figl as fig 4 did
description: fig-lua builds against fig 7, and fig.lua reads every figl fixture to the compiled tree, but its node table lacks the mentions fig 6 added and its printer writes fig 4's flow objects and multi-line string comments
status: done
created: 2026-10-24
updated: 2026-10-26
part_of: "[Tasks](tasks.md)"
---

# fig.lua mentions and prints figl as fig 4 did

**Status.** Done, by `fix(languages): fig.lua mentions, reads and prints
figl as fig 7 does`. Every key that makes or re-opens a block container is
an `entry` or `header` mention, a literal `[n]` an `index` one and an
`a.b[]` header or a `+` an `append` one; a `{…}` object is read and
printed compact, as spec 2.0 has it; and a `'''` or `"""` string's
comment prints on its opener line. `M.syntax` declares the compiled
figl's flow separators, `empty_seq_literal`, `line_prefix_marks` and
`opener_line_comment`, so an edit spells what it writes the same way.
`FIGL_TABLES_AHEAD` and `FIGL_PRINTS_AHEAD` are gone,
`fig_edits_as_the_compiled_format_does` runs, the refusals test holds the
spec 2.0 flow errors, and `fig_reads_compact_objects_as_the_compiled_format_does`
holds the compact forms no fixture spells.

fig-lua moved from fig 4 to fig 7 with every other twin brought level with
fig 7's compiled language. `fig.lua` was not: it reads each figl fixture to
the same tree and the same values as the compiled figl, but three changes to
figl since fig 4 are not in it.

- **Mentions.** fig's `ecc6d1da` (*a key that re-opens a container mid-path
  is a mention of it*) and `07b3b1b5` (*a mention can say where a sequence
  item's path is written*) give the table an `entry` or `header` mention for
  every key that re-opens a block container, and `index` and `append`
  mentions on sequence elements. `fig.lua` records a container's creating key
  and its header re-entries, all as `entry`.
- **Compact flow objects.** fig's `acd87014` (figl spec 2.0) reads an
  `=`-spelled flow object as whitespace-separated pairs with one-token
  values and dotted keys (`{a.b=1 c=2}`), and prints one as `{x=1 y=2}`.
  `fig.lua` reads and prints fig 4's `{ x = 1, y = 2 }`.
- **A multi-line string's comment.** fig's `8a1c8e48` prints a `'''` or
  `"""` string's trailing comment on its opener line (`x = ''' # note`).
  `fig.lua` prints it after the closing quotes.

## Repro

```console
$ cargo test --test twins fig_edits -- --ignored
$ fig lang table -i figl tests/fixtures/fig/dotted-keys.figl   # fig 7: 11 mentions
```

`fig.lua` gives `dotted-keys.figl` 7 mentions, where fig 7 gives 11, and
prints `a.b = { c = 1, d = 2 }` where fig 7 prints `a.b = {c=1 d=2}`.

## Done when

`FIGL_TABLES_AHEAD` and `FIGL_PRINTS_AHEAD` in `tests/twins.rs` are empty
and gone, `fig_edits_as_the_compiled_format_does` runs unignored with its
expectations of the compiled side updated to spec 2.0's spelling, and
`fig.lua`'s refusals cover spec 2.0's flow-object errors
(`FigFlowMissingEquals` and the rest) where the compiled figl refuses.
