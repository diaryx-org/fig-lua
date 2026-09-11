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

Two scripts ship in `languages/`, each the twin of a format fig compiles
in and held to it row for row:

- `dotenv.lua` — `.env` files: bash-identifier keys, an optional `export`,
  quoted and unquoted values, `#` comments, flat.
- `plist.lua` — Apple property lists, the XML form: `dict`, `array`, typed
  scalars, `date` and `data`; and the two fragment renderers that spell an
  edited value as a typed element and an entry as `<key>` over it.

They are also what a new script is written against: each is a complete
parser and printer, and `fig lang check <name> --against <format>` is how a
twin is proven.

## Install

```bash
cargo install fig-lua
```

One binary, Lua built in; nothing else to install. A script is any `.lua`
file, wherever you keep it — `languages.figl` names the path.

## Writing a format

A script returns a table: what the format declares, and the functions it is.

```lua
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
M.samples = { "a=1\nb=two\n" }

function M.parse(dialect, input)
  local t = fig.table()
  local root = t:row("mapping", nil, { 0, #input })
  local at = 0
  for line in (input .. "\n"):gmatch("(.-)\n") do
    local eq = line:find("=", 1, true)
    if not eq then return fig.fail("expected key=value", at) end
    local kv = t:row("keyvalue", root, { at, at + #line }, { sep = { at + eq - 1, at + eq } })
    t:row("string", kv, { at, at + eq - 1 }, { text = line:sub(1, eq - 1) })
    t:row("string", kv, { at + eq, at + #line }, { text = line:sub(eq + 1) })
    at = at + #line + 1
  end
  return t
end

function M.print(dialect, t, options)
  local out = {}
  for _, id in ipairs(t.byid(0).children) do
    local kv = t.byid(id)
    out[#out + 1] = t.byid(kv.children[1]).text .. "=" .. t.byid(kv.children[2]).text .. "\n"
  end
  return table.concat(out)
end

return M
```

The declarations are the same fields, with the same names and values, as
the description a helper answers `describe` with — documented on the
`helper` module of the [`fig` crate](https://docs.rs/fig), which is where
the wire and every shape on it are stated once. In short:

- `parse(dialect, input)` returns a **node table**: rows in pre-order, one
  per node, each with a `kind`, its `parent` row, its byte `span`, and for
  a scalar its `text`; comments bound to rows by slot. `fig.table()` builds
  one and `t:row(...)` returns the id of the row it added. To refuse the
  input, `return fig.fail(message, byte_offset)`.
- `print(dialect, t, options)` gets the same shape back, indexed — every row
  has `children`, `leading`, `trailing`, `dangling`, and `t.byid(id)` finds
  one — and returns the document as a string.
- `render(which, args)` answers a fragment renderer the script declares in
  `M.renderers`; most formats declare none and let fig's splice engine
  write edits from `M.syntax`.

Offsets are byte offsets, 0-based, `[start, end)` — the wire's, and what
`fig lang table <file>` prints for any file, which is the fastest way to
see what a table should be.

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
