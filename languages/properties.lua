-- Java `.properties`, in Lua: the twin of fig's compiled `properties`
-- format, row for row.
--
-- The format — `java.util.Properties.load` as documented, not INI or
-- dotenv re-skinned:
--
--   * a logical line is `key`, then the first unescaped `=`, `:` or run
--     of spaces and tabs, then the value to the line's end; `a=b`, `a:b`,
--     `a b` and `a = b` are the same statement; a line with nothing after
--     its separator, or no separator at all, is a key with an empty value
--     spanning nothing where a value would begin — after the separator,
--     or at the key's end;
--   * key and value both decode `\t \n \r \f`, `\uXXXX`, and `\` before
--     any other byte as that byte (`\:`, `\=`, `\#`, `\ `); a `\` before a
--     line ending is a continuation — it, the newline and the next line's
--     leading spaces and tabs vanish, and the token's span runs on;
--   * a full-line `#` or `!` is a comment, leading for the next key, or
--     dangling on the root when no key follows; nothing trails a value;
--   * a repeated key keeps the first entry's place and takes the last
--     value; the later key's own leading comments go with it.
--
-- Every value is a string: the format has no typed scalars. The node
-- table is held row for row against the compiled format — `fig lang table
-- -i properties` prints that table, and `fig lang check lua-properties
-- --against properties <files…>` compares them file by file. Every
-- document the compiled format refuses is refused here, in this script's
-- own words and at its own offsets: the contract is the format, not the
-- parser. Spans are byte offsets, 0-based, `[start, end)`.

local G = require("fig.grammar")

local M = {}

M.name = "lua-properties"
M.caps = { read = true, edit = true, serialize = true }
-- Flat: no mapping inside the root.
M.max_mapping_depth = 0
M.syntax = {
  -- `#` and `!` are read; `#` is written, and what the editor scans for.
  comments = { style = "hash", line = { open = "#" } },
  -- `=`, `:` and a space are read; `=` is written.
  kv_sep = "=",
  empty_map_literal = "{}",
  flow_containers = false,
}
M.dialects = {
  -- The compiled format owns `.properties`, and a compiled format's
  -- extension wins, so this is reached by `--lang lua-properties`.
  { name = "lua-properties", extensions = { "properties" }, splice = "raw", empty_doc_seed = "" },
}
M.samples = {
  "a=1\nb: two\nc three\n",
}
M.renderers = {}

-- ── the grammar ───────────────────────────────────────────────────────────
-- A form feed counts as inline whitespace, and so as a separator.

local hs = G.pat("[ \t\f]*")
local hs1 = G.pat("[ \t\f]+")

local function is_separator(c)
  return c == 61 or c == 58 or c == 32 or c == 9 or c == 12
end

-- An escape-aware run: a `\` protects the byte after it, and a `\` before
-- a line ending is a continuation — the run goes on into the next line,
-- past its leading spaces and tabs. In `key_mode` it stops before the
-- first unescaped separator, otherwise at the line's end. Always matches,
-- and may be empty: a value is zero-width where one would begin.
local function run(key_mode)
  return function(sc)
    local src, n = sc.src, sc.n
    local s = sc.pos
    local i = s
    while i < n do
      local c = src:byte(i + 1)
      if c == 10 or c == 13 then break end
      if c == 92 then
        if i + 1 >= n then fig.fail("a `\\` at the very end of the file has nothing to escape", i) end
        local skip = true
        if src:byte(i + 2) == 10 then
          i = i + 2
        elseif src:byte(i + 2) == 13 and src:byte(i + 3) == 10 then
          i = i + 3
        else
          i = i + 2
          skip = false
        end
        if skip then
          while i < n and (src:byte(i + 1) == 32 or src:byte(i + 1) == 9) do i = i + 1 end
        end
      elseif key_mode and is_separator(c) then
        break
      else
        i = i + 1
      end
    end
    sc.pos = i
    return { s, i }
  end
end

local SIMPLE = { t = "\t", n = "\n", r = "\r", f = "\12" }

-- The text a run spells; a refusal lands on the escape itself.
local function decode(sc, span)
  local raw = sc:slice(span[1], span[2])
  local out = {}
  local i, n = 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    local next_c = raw:sub(i + 1, i + 1)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    elseif next_c == "\n" or raw:sub(i + 1, i + 2) == "\r\n" then
      i = i + (next_c == "\n" and 2 or 3)
      while i <= n and (raw:sub(i, i) == " " or raw:sub(i, i) == "\t") do i = i + 1 end
    elseif next_c == "u" then
      local hex = raw:sub(i + 2, i + 5)
      local cp = hex:match("^%x%x%x%x$") and tonumber(hex, 16) or nil
      if cp == nil or fig.is_surrogate(cp) then
        fig.fail("invalid `\\u` escape; expected four hex digits spelling a character", span[1] + i - 1)
      end
      out[#out + 1] = utf8.char(cp)
      i = i + 6
    else
      out[#out + 1] = SIMPLE[next_c] or next_c
      i = i + 2
    end
  end
  return table.concat(out)
end

local function text(raw, span, sc)
  if raw:find("\\", 1, true) then return decode(sc, span) end
  return raw
end

local entry = G.entry({
  key = G.key(run(true), { text = text }),
  between = hs,
  -- Any run of inline whitespace separates; one `=` or `:` may join it.
  sep = G.opt(G.pat("[=:]")),
  value = G.scalar("string", run(false), { text = text }),
})

M.parse = G.document({
  utf8 = "this file is not valid UTF-8; fig requires .properties documents to be UTF-8 encoded",
  bom = true,
  root = G.map({
    whole = true,
    entry = entry,
    trivia = G.trivia({
      space = G.choice({
        hs1,
        G.eol,
        G.fail_if(G.lit("\r"), "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`"),
      }),
      comment = G.choice({ G.comment("#"), G.comment("!") }),
    }),
  }),
})

-- ── the printer ───────────────────────────────────────────────────────────
-- Canonical `.properties`, as the compiled printer writes it: one
-- `key=value` line per entry, `=` whatever the source's separator was,
-- the escapes that keep it reading back the same — control characters,
-- `\`, a separator or leading `#`/`!` in a key, leading whitespace in a
-- value — and nothing else; leading comments as `# …` lines above the
-- key, dangling comments at the end. A comment that trails a value has
-- no spelling and is not written.

local ESCAPED = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\12"] = "\\f", ["\\"] = "\\\\" }

local function escaped_byte(c)
  return ESCAPED[c] or ("\\" .. c)
end

local function write_key(w, name)
  for idx = 1, #name do
    local c = name:sub(idx, idx)
    if idx == 1 and (c == "#" or c == "!") then
      w:put(escaped_byte(c))
    elseif ESCAPED[c] or c == "=" or c == ":" or c == " " or c == "\t" or c == "\12" then
      w:put(escaped_byte(c))
    else
      w:put(c)
    end
  end
end

local function write_value_text(w, v)
  for idx = 1, #v do
    local c = v:sub(idx, idx)
    if idx == 1 and (c == " " or c == "\t" or c == "\12") then
      w:put(escaped_byte(c))
    elseif ESCAPED[c] then
      w:put(ESCAPED[c])
    else
      w:put(c)
    end
  end
end

local function write_value(w, row)
  local k = row.kind
  if k == "string" then
    write_value_text(w, row.text or "")
  elseif k == "int" or k == "float" or k == "bool" then
    w:put(row.text or "")
  elseif k == "null" then
    error("a .properties file has no null; a null value cannot be written", 0)
  elseif k == "sequence" or k == "mapping" then
    error("a .properties file holds a flat map of strings; a nested value cannot be written", 0)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as .properties", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function M.print(_dialect, t, _options)
  local w = fig.writer()
  local root = t.byid(0)
  if root.kind ~= "mapping" then
    -- A fragment: the scalar as it stands alone.
    write_value(w, root)
    w:put("\n")
    return w:string()
  end
  for _, kv in ipairs(root.items) do
    local key, value = kv.key, kv.value
    if key.kind ~= "string" then error("a .properties key must be a string", 0) end
    w:comments(key.leading, "#")
    write_key(w, key.text or "")
    w:put("=")
    write_value(w, value)
    w:put("\n")
  end
  w:comments(root.dangling, "#")
  return w:string()
end

return M
