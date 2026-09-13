-- INI, in Lua: the twin of fig's compiled `ini` format, row for row,
-- region for region, mention for mention.
--
-- The format:
--
--   * a line is a `[section]` header, a `key = value`, a `;` or `#`
--     comment, or blank; `=` is the only separator; a value is the rest of
--     its line, trimmed, with one layer of matching `"…"`/`'…'` quotes
--     removed and nothing decoded — a `;` after a value is value text,
--     not a comment;
--   * the root is a mapping spanning the whole input; a section is a
--     keyvalue and a mapping, both spanning the name token of the header
--     that created it; a `key = value` is a keyvalue from the key's start
--     to the value's end, its key and value strings spanning their trimmed
--     text (an absent value spans nothing at the line's end);
--   * a repeated key keeps the first entry's place and takes the last
--     value; a repeated `[section]` reopens the section, which then holds
--     every header line as a *region* and every header's name as a
--     *mention*; a section named like a root key is refused;
--   * a comment leads the next key or section, and at the end of the file
--     dangles on the section the last header opened.
--
-- One level deep by construction (`max_mapping_depth = 1`): there is no
-- spelling for a section inside a section. The node table is held row for
-- row against the compiled format — `fig lang table -i ini` prints that
-- table, and `fig lang check lua-ini --against ini <files…>` compares them
-- file by file. Every document the compiled format refuses is refused
-- here, in this script's own words and at its own offsets: the contract is
-- the format, not the parser. Spans are byte offsets, 0-based,
-- `[start, end)`.

local G = require("fig.grammar")

local M = {}

M.name = "lua-ini"
M.caps = { read = true, edit = true, serialize = true }
M.max_mapping_depth = 1
M.syntax = {
  -- `#` is read; `;` is what is written, and what the editor writes. No
  -- same-line trailing comment: a `;` after a value is value text.
  comments = { style = "semicolon", line = { open = ";" } },
  kv_sep = " = ",
  -- `{}` in INI is the two-character string `{}`, so nothing can be
  -- auto-vivified; and a `[` opening the file is a header, not a flow
  -- container.
  flow_containers = false,
  section_noun = "section",
}
M.dialects = {
  -- The compiled format owns `.ini`, and a compiled format's extension
  -- wins, so this is reached by `--lang lua-ini`.
  { name = "lua-ini", extensions = { "ini" }, splice = "raw", empty_doc_seed = "" },
}
M.samples = { "a = 1\n\n[s]\nk = v\n" }
M.renderers = {}

-- ── the grammar ───────────────────────────────────────────────────────────

-- Blank lines and whole-line `;`/`#` comments. A comment waits in the
-- section context for the key or header it leads; nothing trails a value,
-- since a `;` after one is value text.
local trivia = G.trivia({
  space = G.choice({
    G.hs1,
    G.eol,
    G.fail_if(G.lit("\r"), "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`"),
  }),
  comment = G.choice({ G.comment(";"), G.comment("#") }),
})

-- `[name]`, the name trimmed of spaces and tabs.
local header = G.seq({
  G.lit("["),
  G.expect(
    G.key(G.bare({ stop = function(sc) return sc:starts("]") end, empty = false })),
    "a `[section]` header needs a name"
  ),
  G.expect(G.lit("]"), "unclosed `[section]` header; expected a `]` before the end of the line"),
})

-- One layer of matching quotes around the whole value comes off; nothing
-- inside is decoded.
local function unquote(raw)
  local q = raw:sub(1, 1)
  if #raw >= 2 and (q == '"' or q == "'") and raw:sub(-1) == q then return raw:sub(2, -2) end
  return raw
end

local entry = G.entry({
  key = G.key(G.bare({ stop = function(sc) return sc:starts("=") end, empty = false })),
  sep = G.lit("="),
  value = G.bare({ text = unquote }),
  missing_sep = "expected `=` after this key; every INI line is `key = value`",
})

-- A header line: the section its name already stands for, re-entered, or a
-- fresh one under the root. Nothing but spaces may follow the `]`.
local function section(sc, S, root, key)
  sc:match("[ \t]*")
  if not (sc:eof() or sc:starts("\n") or sc:starts("\r")) then
    sc:fail("unexpected content after `]`; a section header must be alone on its line")
  end
  local existing = root.by_key[key.text]
  if existing then
    if existing.value.kind ~= "mapping" then
      fig.fail("this section conflicts with a key of the same name already defined at this level", key.span[1])
    end
    S:reopen(existing.value, key.span, "header")
    return existing.value
  end
  S:claim(key, "leading")
  return S:open(root, fig.entry(key, fig.mapping(key.span)), "header")
end

-- Line by line: what a header *means* — which section it re-enters, where
-- the keys after it land — is the parser's, as `G.sections` says.
function M.parse(_dialect, input)
  local sc = fig.scanner(input)
  if sc:starts("\239\187\191") then sc.pos = 3 end
  local S = G.sections(input)
  local ctx = { comment = function(_, c) S:comment(c.text) end }
  local root = fig.mapping({ 0, sc.n })
  local current = root
  while true do
    trivia(sc, ctx)
    if sc:eof() then break end
    local h = header(sc)
    if h then
      current = section(sc, S, root, h[2])
    else
      local e = entry(sc)
      if e == nil then
        sc:fail("unexpected content here; expected a `[section]` header or a `key = value` line")
      end
      S:claim(e.key, "leading")
      current:put(e)
    end
  end
  S:claim(current, "dangling")
  return root
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: the root's scalar entries first as
-- `key = value` lines, then every mapping-valued entry as a `[section]`
-- block, in that order whatever the tree's — INI cannot interleave them.
-- A value is bare unless bare would not read back the same (empty,
-- padded, or already quoted), then `"…"`. Comments are `;` lines: leading
-- above a key, a trailing one on its own line after, dangling at the end
-- of its section.

local function needs_quoting(v)
  if v == "" then return true end
  local first, last = v:sub(1, 1), v:sub(-1)
  if first == " " or first == "\t" or last == " " or last == "\t" then return true end
  return #v >= 2 and (first == '"' or first == "'") and last == first
end

local function write_text(w, v)
  if v:find("[\n\r]") then error("a value with a line break has no INI spelling", 0) end
  if needs_quoting(v) then w:put('"', v, '"') else w:put(v) end
end

local function write_value(w, row)
  local k = row.kind
  if k == "string" then
    write_text(w, row.text or "")
  elseif k == "int" or k == "float" or k == "bool" then
    w:put(row.text)
  elseif k == "null" then
    error("INI has no null; a null value cannot be written", 0)
  elseif k == "sequence" or k == "mapping" then
    error("a nested container has no INI spelling", 0)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as INI", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

local function key_text(row)
  if row.kind ~= "string" then error("an INI key must be a string", 0) end
  return row.text or ""
end

function M.print(_dialect, t, _options)
  local w = fig.writer()
  local root = t.byid(0)
  if root.kind ~= "mapping" then
    write_value(w, root)
    w:put("\n")
    return w:string()
  end
  -- Whether anything stands above what comes next: a blank line goes
  -- between the root's keys and the first section, and between sections.
  local wrote = false
  local function comments(list)
    wrote = w:comments(list, ";") or wrote
  end
  local function kv_line(e)
    comments(e.key.leading)
    write_text(w, key_text(e.key))
    w:put(" = ")
    write_value(w, e.value)
    w:put("\n")
    wrote = true
    comments(e.value.trailing)
  end
  for _, e in ipairs(root.items) do
    if e.value.kind ~= "mapping" then kv_line(e) end
  end
  for _, e in ipairs(root.items) do
    if e.value.kind == "mapping" then
      comments(e.key.leading)
      if wrote then w:put("\n") end
      w:put("[")
      write_text(w, key_text(e.key))
      w:put("]\n")
      wrote = true
      for _, inner in ipairs(e.value.items) do
        if inner.value.kind == "mapping" then error("a section inside a section has no INI spelling", 0) end
        kv_line(inner)
      end
      comments(e.value.dangling)
    end
  end
  comments(root.dangling)
  return w:string()
end

return M
