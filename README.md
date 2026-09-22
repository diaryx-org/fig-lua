# fig-lua

A [fig](https://github.com/diaryx-org/fig) format written in Lua.

fig reads, converts and edits configuration in the formats it compiles in.
A format it does not compile in can be a program — fig's *runtime language*
contract, carried to a helper process over stdin and stdout — and this is
the first such program: `fig-lua <script.lua>` serves whatever format a Lua
5.4 script defines, and the `fig` command line then reads, converts and
edits that format as it does any other.

```fig
# ~/.config/fig/languages.figl
language[]
> name = lua-dotenv
> extensions = [env]
> command = [fig-lua, ~/.config/fig/languages/dotenv.lua]
```

```bash
$ fig get secrets.env --lang lua-dotenv
$ fig set secrets.env API_KEY hunter2 --lang lua-dotenv
$ fig lang check lua-dotenv --against dotenv secrets.env
lua-dotenv: registered (read edit serialize); every sample parsed, printed and reparsed to the same tree, and took a no-op edit
secrets.env: same table as `dotenv` (13 rows)
```

Eleven scripts ship in `languages/`, each the twin of a format fig compiles
in. The format and the tree are the contract: a twin produces the same
node table as the compiled format — every row, span, text and comment,
`tests/fixtures/<format>/*.table.json` beside each fixture — and refuses
every document the compiled format refuses, in words and at offsets of
its own. How it gets there is its own too; none is written to follow
the compiled parser step for step, and most are grammars:

- `json.lua` — strict JSON, RFC 8259: the values, the escapes with
  surrogate pairs, the byte-order mark, no comments; the format everyone
  already knows, so the one to read first.
- `json5.lua` — JSONC and JSON5, two dialects from one script (`lua-json5`
  and `lua-jsonc`), one grammar built twice: `//` and `/* */` comments,
  with the three refinements of the binding policy these dialects make
  stated as context options; and JSON5's unquoted keys, single quotes,
  trailing commas, `Infinity`/`NaN`, hex and bare dots. The one to read
  for how a grammar states where a comment goes.
- `fig.lua` — fig's own authoring dialect, `.figl`, whole: `>` marker
  depth, section headers and `a.b[]`/`+` append headers, `*` elements,
  dotted keys, `key: type = value` annotations kept as tags, flow values
  with the balanced-then-trailing rule that leaves a markdown link bare,
  multiline strings, comments placed by their own depth; and the `fig
  fmt` house style — sections, hoisting, dotted collapse, append groups,
  multi-line flow — byte for byte, plus the `tail` renderer that
  re-prints a block value one marker level below its key.
- `ini.lua` — `[section]` files: `key = value` lines, `;` and `#`
  comments, a reopened section merged into the first. The smaller section
  format, and the one to read beside `toml.lua` for what a section is.
- `toml.lua` — TOML 1.1, whole: `[tables]`, `[[arrays of tables]]`,
  dotted keys, inline tables, every string and number form, datetimes.
  A *section* format, so it is what a runtime language looks like when
  it carries the regions and mentions the editor moves a table by, and
  the compiled printer's layout rules, width budget and all; held to
  the whole of toml-test, and its edits to the compiled format's bytes.
- `zon.lua` — Zig Object Notation, `.zon`: `.{ .field = value }` structs,
  `.{ 1, 2 }` arrays, Zig's numbers, strings and `\\` multiline strings,
  `.enum` and `'c'` literals kept as extended scalars, `//` comments. A
  grammar over the data format: what is Zig but not ZON — an operator, a
  builtin, a doc comment — is refused in words of its own, not parsed
  and then declined as the compiled `std.zig.Ast` does.
- `yaml.lua` — YAML 1.2, whole, and 1.1's scalar resolution as a second
  dialect (`lua-yaml-1.1`): block and flow collections, every scalar
  style — plain, quoted with their escapes and folds, `|` and `>` blocks
  with their indicators — anchors, aliases and `<<` merges, tags kept
  verbatim with their `%TAG` handles, explicit `?` keys, directives and
  document markers, comments; and the compiled printer's block style
  with its flow form where a
  collection fits the width. The largest twin, and the one that carries
  a reference layer (`caps.references`), so a document leaving it for
  JSON is collapsed as one leaving the compiled YAML is; held to the
  whole yaml-test-suite and to the compiled editor's cases.
- `dotenv.lua` — `.env` files: bash-identifier keys, an optional `export`,
  quoted and unquoted values, `#` comments, flat.
- `properties.lua` — Java `.properties`: `=`, `:` or a space between key
  and value, backslash escapes on both, `\uXXXX`, line continuations,
  `#` and `!` comments, flat.
- `nestedtext.lua` — NestedText: indentation-nested dicts, lists and `>`
  string blocks, multiline `: ` keys, one-line inline `{…}`/`[…]`, every
  scalar a literal string; and the four renderers the compiled editor
  spells its edits with — an entry, an item, a value's tail, a key.
- `plist.lua` — Apple property lists, the XML form: `dict`, `array`, typed
  scalars, `date` and `data`; and the three fragment renderers that spell
  an edited value as a typed element, an entry as `<key>` over it, and a
  renamed key as its whole `<key>` element.
- `canonical.lua` — fig's canonical form, the tree spelled with nothing
  added: flow containers, JSON strings, numbers with their kind pinned,
  extended scalars, anchors, tags and aliases, keys that are any node,
  `//` and `/* */` comments. Every row the wire can carry, in one script;
  the compiled sibling is opt-in (`zig build -Dcanonical=true`).

They are also what a new script is written against: each is a complete
parser and printer, and `fig lang check <name> --against <format>` is how a
twin is proven — the table, row for row. What a twin says when it refuses
a document is not compared; `fig lang table -i <format>` prints what the
table has to be.

## Install

```bash
cargo install fig-lua
```

One binary, Lua built in; nothing else to install. A script is any `.lua`
file, wherever you keep it — `languages.figl` names the path.

## Writing a format

A script returns a table: what the format declares, and the functions it
is. The parser is a description — a grammar whose pieces are fig's own
kinds of node, so the tree, the byte spans, the comment binding and the
duplicate-key policy come with it — and the printer walks the tree back
out.

```lua
local G = require("fig.grammar")

local M = {}
M.name = "tinykv"
M.caps = { read = true, edit = true, serialize = true }
M.max_mapping_depth = 0
M.syntax = {
  comments = { style = "hash", line = { open = "#" }, trailing = { open = "#" } },
  kv_sep = "=",
  empty_map_literal = "{}",
  flow_containers = false,
}
M.dialects = { { name = "tinykv", extensions = { "tkv" }, splice = "raw", empty_doc_seed = "" } }
M.samples = { "a=1\n# two\nb=two # words\n" }

M.parse = G.document({
  root = G.map({
    whole = true,
    trivia = G.trivia({ comment = G.comment("#") }),
    entry = G.entry({
      key = G.key(G.pat("[%w_]+")),
      sep = G.lit("="),
      value = G.bare({ stop = G.lit("#") }),
      missing_sep = "expected `=` after this key",
    }),
    expected = "expected `key=value` here",
  }),
})

function M.print(_, t)
  local root = t.byid(0)
  if root.kind ~= "mapping" then return root.text or "" end
  local w = fig.writer()
  for _, kv in ipairs(root.items) do
    for _, c in ipairs(kv.key.leading) do w:put("# ", c.text, "\n") end
    w:put(kv.key.text, "=", kv.value.text)
    for _, c in ipairs(kv.value.trailing) do w:put(" # ", c.text) end
    w:put("\n")
  end
  return w:string()
end

return M
```

The declarations are the same fields, with the same names and values, as
the description a helper answers `describe` with — documented on the
`helper` module of the [`fig` crate](https://docs.rs/fig), which is where
the wire and every shape on it are stated once.

**The grammar.** A rule is a function over a scanner: it answers a result,
or `nil` for "not here", and a `choice` moves on. `lit`, `pat`, `eol` and
`eof` are the primitives; `seq`, `choice`, `opt`, `many`, `ahead`,
`expect` and `fail` combine them. The rules that matter are the ones that
answer nodes: `key` and `scalar` over anything, `quoted` (escapes, `\r\n`,
what may follow the closing quote) and `bare` (to the line's end or a
stop) for values, `comment` for a comment, `entry` for `key sep value`,
and `map` and `sequence` for containers, which run `trivia` between their
members and take their duplicate policy and their close. `document` makes
a `parse` of a root rule. Comments are bound as trivia passes them: on the
same line as the last node, trailing; otherwise leading on the next entry's
key, or dangling on the container that closes first. To refuse the input
from anywhere, `fig.fail(message, byte_offset)`; the messages a rule uses
are options on it, so a twin can word a refusal exactly as the compiled
parser does.

**Below the grammar.** A `parse` may also return a tree built by hand —
`fig.mapping`, `fig.sequence`, `fig.entry`, `fig.scalar`, nodes that hold
their children and their comments as fields, with `map:put(entry)`
applying the policy — or the wire's node table itself, `fig.table()` and
`t:row(...)`, rows in pre-order. `fig.scanner(src)` is a byte cursor whose
positions are already the wire's: 0-based, `[start, end)`, what `fig lang
table <file>` prints for any file, which is the fastest way to see what a
table should be. A rule is only a function of one, so any piece of a
grammar can be plain Lua where the grammar cannot say it.

Where a format's binding rule is not the module's, a script says so
around it: `canonical.lua` runs its own `parse` over `G.context` with a
`comment` method of its own, and gives `G.map` an `open` rule that keeps a
`//` on the opening line for the container, and an `after` rule that takes
the comma or looks ahead for the close. A rule is a function, and so is
the context's policy.

**Sections.** A format whose containers are opened by a header line and
re-entered by another — INI, TOML, fig — is not a grammar of rules, and
`ini.lua`, `toml.lua` and `fig.lua` state their headers by hand. What the
three share is `G.sections(src)`: `S:open(parent, entry, kind)` puts the
keyvalue in its parent and gives the container its first *region* (the
whole line holding the key) and its first *mention* (the key, of kind
`header` or `entry`); `S:reopen(node, span, kind)` adds one of each for
a header that names it again; `S:region` and `S:mention` add one alone,
for the header line an array-of-tables element shares or the segment a
`[a.b]` passes through. `S:comment(text, depth)` is a comment waiting
for its key, and `S:claim(node, slot, depth)` gives the waiting comments
at that depth or deeper to a key (`leading`) or a closing container
(`dangling`); `depth` is for a format whose lines have one, and the
others leave it. What a header *means* — which containers it may
re-enter, what its dots and brackets say, where the cursor goes — is
each format's own, and stays in its parser.

**XML.** `require("fig.xml")` is the XML shape — tags with or without
attributes, text with entities and CDATA decoded, comments and processing
instructions skipped — as rules: `X.tag`, `X.close(name)`,
`X.text_element(name)`, `X.element{ name = handler }`, `X.trivia`.
`plist.lua` is a `G.map` of `<key>`/value entries closed by `</dict>`.

**Numbers and datetimes.** A number row's `text` is its lexeme, verbatim,
and a printer writing it for another format asks `require("fig.number")`
whether that format reads it back as the same number — `N.text(raw,
N.JSON5)` is the lexeme when it is, decimal when it is not.
`require("fig.datetime")` is the other typed scalar every format spells
alike: `DT.classify(raw, opts)` answers `local_date`, `local_time`,
`local_datetime` or `offset_datetime`, with `opts` for what the format
allows. Both are the twins of the utilities fig's compiled formats share.

**Printing.** `print(dialect, t, options)` gets the table back indexed:
every row has `items` (its children), `leading`, `trailing`, `dangling`;
a keyvalue has `key` and `value`; `t.byid(id)` finds one. `fig.writer(options)`
is a buffer that writes nothing for `nl()` and `indent(depth)` when
`pretty` is off. A table whose root is a scalar is a fragment: spell it
as the scalar stands alone. `options.splice` is `true` when fig wants the
value as the editor splices it into a document — every value a binding's
editor hands it — rather than as a document of its own: a format whose
document wraps its root (`plist.lua`) or spells a root differently from
the same value in place (`nestedtext.lua`) writes it as it stands in
place, and every other prints the same either way.

**Editing** needs no code: fig's splice engine writes an edit from
`M.syntax`. A format whose fragments cannot be spelled from constants
declares `M.renderers` and answers `render(which, args)` — `plist.lua`
does, for the typed element a value becomes. A value renderer is told
what fig's own literal rules made of the text, `args.literal`: `"int"`,
`"float"`, `"bool"`, `"datetime"`, `"null"` or `"string"`, the one meaning
every format's `set` gives `42` or `Yes`, so a script spells a kind and
never decides one.

`fig-lua check <script.lua>` loads a script and runs fig's own harness over
its samples — parse, print, reparse, a no-op edit — which is the check the
`fig` CLI makes before it accepts a helper, and says why if it is refused.

## In a Rust program

The same script is a `fig::language::Language`, registered in-process:

```rust
let lua_dotenv = fig_lua::register_file("languages/dotenv.lua")?[0];
let doc = fig::Document::parse(b"A=1\n", lua_dotenv)?;
```

## License

MIT OR Apache-2.0.
