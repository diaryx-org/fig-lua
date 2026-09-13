-- Java `.properties`, in Lua: the twin of fig's compiled `properties`
-- format, row for row.
--
-- `fig lang check lua-properties --against properties <files…>` holds this
-- script to the compiled parser's node table on every file given, and
-- this script is written against `fig lang table -i properties`, which
-- prints that table. What the compiled format accepts is stated in fig's
-- `src/languages/properties/`, and this follows it — `java.util.Properties
-- .load` as documented, not INI or dotenv re-skinned:
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
-- Every value is a string: the format has no typed scalars. Spans are
-- byte offsets, 0-based, `[start, end)`. The refusals are the compiled
-- parser's, in its words and at its offsets: a bad `\uXXXX` is reported
-- where the token after the offending one begins, as the compiled parser
-- decodes a token once it has moved past it. The one warning (a
-- duplicate key) has no row and is not carried.

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

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  InvalidUnicode = "invalid \\uXXXX escape; expected exactly 4 hex digits forming a valid Unicode codepoint",
  InvalidUtf8 = "this file is not valid UTF-8; fig requires .properties documents to be UTF-8 encoded",
  UnexpectedCarriageReturn = "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
  UnclosedEscape = "a `\\` at the very end of the file has nothing to escape",
}

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- Tokens are `{ kind=, s=, e= }` over 0-based byte offsets: `key`, `value`
-- (both raw, decoded by the parser; a value follows every key), `comment`
-- (the text after its leader), `newline`, `end_of_file`.

local function is_inline_ws(b)
  return b == 32 or b == 9 or b == 12
end

local function is_separator(b)
  return b == 61 or b == 58 or is_inline_ws(b)
end

local function tokenize(src)
  local n = #src
  local i = 0
  local tokens = {}
  local function at(k) return src:byte(k + 1) end
  local function emit(kind, s, e) tokens[#tokens + 1] = { kind = kind, s = s, e = e } end

  local function skip_continuation_ws()
    while i < n and (at(i) == 32 or at(i) == 9) do i = i + 1 end
  end

  -- An escape-aware run: a `\` protects the byte after it, a `\` before a
  -- line ending joins the next line on. Stops before the first unescaped
  -- separator in `key_mode`, else at the logical line's end.
  local function scan_escaped(key_mode)
    while i < n do
      local c = at(i)
      if c == 10 or c == 13 then return end
      if c == 92 then
        if i + 1 < n and at(i + 1) == 10 then
          i = i + 2
          skip_continuation_ws()
        elseif i + 2 < n and at(i + 1) == 13 and at(i + 2) == 10 then
          i = i + 3
          skip_continuation_ws()
        elseif i + 1 >= n then
          fig.fail(MESSAGES.UnclosedEscape, i)
        else
          i = i + 2
        end
      elseif key_mode and is_separator(c) then
        return
      else
        i = i + 1
      end
    end
  end

  if src:sub(1, 3) == "\239\187\191" then i = 3 end
  while i < n do
    while i < n and is_inline_ws(at(i)) do i = i + 1 end
    if i >= n then break end
    local c = at(i)
    if c == 10 then
      emit("newline", i, i + 1)
      i = i + 1
    elseif c == 13 then
      if i + 1 < n and at(i + 1) == 10 then
        emit("newline", i, i + 2)
        i = i + 2
      else
        fig.fail(MESSAGES.UnexpectedCarriageReturn, i)
      end
    elseif c == 35 or c == 33 then
      i = i + 1
      local s = i
      while i < n and at(i) ~= 10 and at(i) ~= 13 do i = i + 1 end
      emit("comment", s, i)
    else
      local key_start = i
      scan_escaped(true)
      emit("key", key_start, i)
      while i < n and is_inline_ws(at(i)) do i = i + 1 end
      if i < n and (at(i) == 61 or at(i) == 58) then
        i = i + 1
        while i < n and is_inline_ws(at(i)) do i = i + 1 end
      end
      -- Always a value: zero-width where one would begin when nothing
      -- follows.
      local value_start = i
      if i < n and at(i) ~= 10 and at(i) ~= 13 then scan_escaped(false) end
      emit("value", value_start, i)
    end
  end
  emit("end_of_file", n, n)
  return tokens
end

-- ── decoding ──────────────────────────────────────────────────────────────

local SIMPLE = { t = "\t", n = "\n", r = "\r", f = "\12" }

-- The text of a raw key or value token; `fail_at` is where a bad
-- `\uXXXX` is reported.
local function decode_escaped(raw, fail_at)
  if not raw:find("\\", 1, true) then return raw end
  local out = {}
  local i = 1
  local n = #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    elseif raw:sub(i + 1, i + 1) == "\n" then
      i = i + 2
      while i <= n and (raw:sub(i, i) == " " or raw:sub(i, i) == "\t") do i = i + 1 end
    elseif raw:sub(i + 1, i + 2) == "\r\n" then
      i = i + 3
      while i <= n and (raw:sub(i, i) == " " or raw:sub(i, i) == "\t") do i = i + 1 end
    else
      local ch = raw:sub(i + 1, i + 1)
      if SIMPLE[ch] then
        out[#out + 1] = SIMPLE[ch]
      elseif ch == "u" then
        local hex = raw:sub(i + 2, i + 5)
        if #hex < 4 or not hex:match("^%x%x%x%x$") then fig.fail(MESSAGES.InvalidUnicode, fail_at) end
        local cp = tonumber(hex, 16)
        if cp >= 0xD800 and cp <= 0xDFFF then fig.fail(MESSAGES.InvalidUnicode, fail_at) end
        out[#out + 1] = utf8.char(cp)
        i = i + 4
      else
        out[#out + 1] = ch
      end
      i = i + 2
    end
  end
  return table.concat(out)
end

-- ── the parser ────────────────────────────────────────────────────────────

function M.parse(_dialect, input)
  local ok, bad = utf8.len(input)
  if not ok then fig.fail(MESSAGES.InvalidUtf8, bad and bad - 1 or nil) end
  local tokens = tokenize(input)
  local pos = 1
  local pending = {}
  local root = fig.mapping({ 0, #input })

  local function peek() return tokens[pos] end
  local function advance()
    local t = tokens[pos]
    if pos < #tokens then pos = pos + 1 end
    return t
  end
  local function text(t) return input:sub(t.s + 1, t.e) end
  local function claim(node, slot)
    for _, c in ipairs(pending) do node:comment(slot, c) end
    pending = {}
  end
  local function skip_blank()
    while true do
      local k = peek().kind
      if k == "comment" then
        pending[#pending + 1] = text(peek()):match("^[ \t\r]*(.-)[ \t\r]*$")
        pos = pos + 1
      elseif k == "newline" then
        pos = pos + 1
      else
        return
      end
    end
  end

  skip_blank()
  while peek().kind ~= "end_of_file" do
    local key_tok = advance()
    local name = decode_escaped(text(key_tok), peek().s)
    local value_tok = advance()
    local value_text = decode_escaped(text(value_tok), peek().s)
    local key = fig.scalar("string", { key_tok.s, key_tok.e }, name)
    claim(key, "leading")
    root:put(fig.entry(key, fig.scalar("string", { value_tok.s, value_tok.e }, value_text)))
    skip_blank()
  end
  claim(root, "dangling")
  return root
end

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

local function comment_lines(w, c)
  for line in (c.text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^[ \t]*(.-)[ \t]*$")
    w:put(trimmed == "" and "#\n" or ("# " .. trimmed .. "\n"))
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
    for _, c in ipairs(key.leading) do comment_lines(w, c) end
    write_key(w, key.text or "")
    w:put("=")
    write_value(w, value)
    w:put("\n")
  end
  for _, c in ipairs(root.dangling) do comment_lines(w, c) end
  return w:string()
end

return M
