---
title: toml.lua reads an integer past 64 bits
description: toml.lua means to refuse an integer outside i64, but an `and`/`or` falls through to the float path, so `2^63` is read as a Uint, `10^20` as a Float, and `-2^63 - 1` as `-2^63`, where the compiled TOML refuses all three
status: open
created: 2026-11-09
updated: 2026-11-09
part_of: "[Tasks](tasks.md)"
---

# toml.lua reads an integer past 64 bits

TOML gives an integer 64 signed bits, and a value it cannot hold losslessly
is an error. The compiled TOML refuses one (`not a valid TOML number`), and
`toml.lua` means to: `canonical_int` returns nil where `math.tointeger`
gives no integer, and `parse_value` then fails with *this integer is too
large for the 64 bits TOML gives it*. That refusal never fires:

```lua
local text = kind == "int" and canonical_int(raw) or canonical_float(raw)
if not text then self:fail("this integer is too large …", t) end
```

When `canonical_int` returns nil, the `or` takes `canonical_float(raw)`,
which is the lexeme minus underscores, so `text` is never nil. The row
goes out as an `int` whose text is past i64, and fig reads it as whatever
that text fits.

A second gap is behind the first. `canonical_int` goes through
`tonumber`, which gives a float for a decimal past i64, and a float rounded
to `-2^63` converts back to an integer. So `-9223372036854775809` (and every
value down to `-9223372036854776832`, which rounds to the same double) gets
an integer, the wrong one, even with the `and`/`or` mended.

## Repro

Against the compiled TOML, in-process, as `tests/twins.rs` holds the twins:

| source | compiled `fig-toml` 7 | `lua-toml` |
|---|---|---|
| `a = 9223372036854775808` | refused | `Uint(9223372036854775808)` |
| `a = 0x8000000000000000` | refused | `Uint(9223372036854775808)` |
| `a = 0xffffffffffffffff` | refused | `Uint(18446744073709551615)` |
| `a = 0b1` then 63 `0`s | refused | `Uint(9223372036854775808)` |
| `a = 18446744073709551616` | refused | `Float(1.8446744073709552e19)` |
| `a = 99999999999999999999` | refused | `Float(1e20)` |
| `a = -9223372036854775809` | refused | `Int(-9223372036854775808)` |
| `a = -9223372036854777856` | refused | `Float(-9.223372036854778e18)` |

`9223372036854775807`, `-9223372036854775808` and `0x7fffffffffffffff`
agree. Each line is `Document::parse(source, format)` then `to_value()`,
on `main` at 872f83c.

## Done when

Every source in the table is refused by `toml.lua`, with the integers at
i64's two ends still read, and `toml_refuses_what_the_compiled_format_refuses`
in `tests/twins.rs` holds them. Deciding the range from the digits rather than
from `tonumber`'s float (compare the canonical decimal against
`9223372036854775807` and `-9223372036854775808` as strings, or let
`math.tointeger` see only a string `tonumber` reads as an integer) closes
both gaps.
