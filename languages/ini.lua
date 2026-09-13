-- INI, in Lua: the twin of fig's compiled `ini` format, row for row,
-- region for region, mention for mention.
--
-- `fig lang check lua-ini --against ini <files…>` holds this script to the
-- compiled parser's node table on every file given, and this script is
-- written against `fig lang table -i ini`, which prints that table. What
-- the compiled format accepts is stated in fig's `src/languages/ini/`, and
-- this follows it:
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
-- spelling for a section inside a section. The refusals are the compiled
-- parser's, in its words and at its offsets, with one difference of
-- order: the compiled tokenizer runs over the whole file before its
-- parser, so a file with a lexical error after a grammatical one reports
-- the lexical one; this reports the first.

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

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  UnexpectedToken = "unexpected content here; expected a `[section]` header or a `key = value` line",
  InvalidKey = "a key/section name cannot be empty",
  DuplicateKey = "this section conflicts with a key of the same name already defined at this level",
  UnexpectedCarriageReturn = "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
  UnclosedSection = "unclosed `[section]` header; expected a `]` before the end of the line",
  MissingEquals = "expected `=` after this key; every INI line is `key = value`",
  TrailingContent = "unexpected content after `]`; a section header must be alone on its line",
}

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- Line-oriented, as the compiled one: what a byte means depends on
-- whether the line's `=` has passed. Every token is `{kind, s, e}`; a
-- `text` token is a section name, a key or a value by position, its span
-- trimmed of spaces and tabs.

local function is_line_end(src, at)
  local c = src:byte(at + 1)
  return c == nil or c == 10 or c == 13
end

local function trim_span(src, s, e)
  while s < e and (src:byte(s + 1) == 32 or src:byte(s + 1) == 9) do s = s + 1 end
  while e > s and (src:byte(e) == 32 or src:byte(e) == 9) do e = e - 1 end
  return s, e
end

local function tokenize(src)
  local tokens = {}
  local n = #src
  local i = src:sub(1, 3) == "\239\187\191" and 3 or 0
  local in_value = false
  local function emit(kind, s, e) tokens[#tokens + 1] = { kind = kind, s = s, e = e } end
  while i < n do
    local c = src:byte(i + 1)
    if c == 10 then
      emit("newline", i, i + 1)
      i = i + 1
      in_value = false
    elseif c == 13 then
      if src:byte(i + 2) ~= 10 then fig.fail(MESSAGES.UnexpectedCarriageReturn, i) end
      emit("newline", i, i + 2)
      i = i + 2
      in_value = false
    elseif c == 32 or c == 9 then
      i = i + 1
    elseif in_value then
      local s = i
      while not is_line_end(src, i) do i = i + 1 end
      emit("text", trim_span(src, s, i))
    elseif c == 59 or c == 35 then
      i = i + 1
      local s = i
      while not is_line_end(src, i) do i = i + 1 end
      emit("comment", s, i)
    elseif c == 91 then
      emit("open_bracket", i, i + 1)
      i = i + 1
      local s = i
      while i < n and src:byte(i + 1) ~= 93 do
        if is_line_end(src, i) then fig.fail(MESSAGES.UnclosedSection, i) end
        i = i + 1
      end
      if i >= n then fig.fail(MESSAGES.UnclosedSection, i) end
      emit("text", trim_span(src, s, i))
      emit("close_bracket", i, i + 1)
      i = i + 1
      while i < n and (src:byte(i + 1) == 32 or src:byte(i + 1) == 9) do i = i + 1 end
      if not is_line_end(src, i) then fig.fail(MESSAGES.TrailingContent, i) end
    else
      local s = i
      while i < n and src:byte(i + 1) ~= 61 and not is_line_end(src, i) do i = i + 1 end
      if i >= n or src:byte(i + 1) ~= 61 then fig.fail(MESSAGES.MissingEquals, i) end
      emit("text", trim_span(src, s, i))
      emit("equals", i, i + 1)
      i = i + 1
      in_value = true
    end
  end
  emit("end_of_file", n, n)
  return tokens
end

-- ── the parser ────────────────────────────────────────────────────────────

-- One layer of matching quotes around the whole value comes off; nothing
-- inside is decoded.
local function decode_value(raw)
  if #raw >= 2 then
    local q = raw:sub(1, 1)
    if (q == '"' or q == "'") and raw:sub(-1) == q then return raw:sub(2, -2) end
  end
  return raw
end

-- The whole physical line holding `at`, newline included: a region.
local function line_region(src, at)
  local s = at
  while s > 0 and src:byte(s) ~= 10 do s = s - 1 end
  local e = at
  while e < #src and src:byte(e + 1) ~= 10 do e = e + 1 end
  if e < #src then e = e + 1 end
  return { s, e }
end

function M.parse(_dialect, input)
  local tokens = tokenize(input)
  local pos = 1
  local pending = {}
  local root = fig.mapping({ 0, #input })
  local current = root

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

  -- `[name]`: reopen the section when the name was seen, else a fresh
  -- section under the root.
  local function section_header()
    advance() -- [
    local name_tok = peek()
    if name_tok.kind ~= "text" then fig.fail(MESSAGES.UnexpectedToken, name_tok.s) end
    advance()
    local name = text(name_tok)
    if peek().kind ~= "close_bracket" then fig.fail(MESSAGES.UnexpectedToken, peek().s) end
    advance()
    if name == "" then fig.fail(MESSAGES.InvalidKey, name_tok.s) end
    local span = { name_tok.s, name_tok.e }
    local existing = root.by_key[name]
    if existing then
      local m = existing.value
      if m.kind ~= "mapping" then fig.fail(MESSAGES.DuplicateKey, name_tok.s) end
      m.regions[#m.regions + 1] = line_region(input, name_tok.s)
      m.mentions[#m.mentions + 1] = { span = span, kind = "header" }
      current = m
    else
      local key = fig.scalar("string", span, name)
      claim(key, "leading")
      local m = fig.mapping(span)
      m.regions = { line_region(input, name_tok.s) }
      m.mentions = { { span = span, kind = "header" } }
      root:put(fig.entry(key, m))
      current = m
    end
  end

  local function key_value()
    local key_tok = advance()
    local name = text(key_tok)
    if name == "" then fig.fail(MESSAGES.InvalidKey, key_tok.s) end
    if peek().kind ~= "equals" then fig.fail(MESSAGES.UnexpectedToken, peek().s) end
    advance()
    -- `key=` at the line's end has no value token: an empty value there.
    local raw, span = "", { peek().s, peek().s }
    if peek().kind == "text" then
      local value_tok = advance()
      raw = text(value_tok)
      span = { value_tok.s, value_tok.e }
    end
    local key = fig.scalar("string", { key_tok.s, key_tok.e }, name)
    claim(key, "leading")
    current:put(fig.entry(key, fig.scalar("string", span, decode_value(raw))))
  end

  skip_blank()
  while peek().kind ~= "end_of_file" do
    local k = peek().kind
    if k == "open_bracket" then
      section_header()
    elseif k == "text" then
      key_value()
    else
      fig.fail(MESSAGES.UnexpectedToken, peek().s)
    end
    skip_blank()
  end
  claim(current, "dangling")
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

local function comment_lines(w, ctx, list)
  for _, c in ipairs(list) do
    for line in (c.text .. "\n"):gmatch("(.-)\n") do
      local t = line:match("^[ \t]*(.-)[ \t]*$")
      w:put(t == "" and ";" or ("; " .. t), "\n")
    end
    ctx.wrote = true
  end
end

local function key_text(row)
  if row.kind ~= "string" then error("an INI key must be a string", 0) end
  return row.text or ""
end

local function kv_line(w, ctx, e)
  comment_lines(w, ctx, e.key.leading)
  write_text(w, key_text(e.key))
  w:put(" = ")
  write_value(w, e.value)
  w:put("\n")
  ctx.wrote = true
  comment_lines(w, ctx, e.value.trailing)
end

function M.print(_dialect, t, _options)
  local w = fig.writer()
  local ctx = { wrote = false }
  local root = t.byid(0)
  if root.kind ~= "mapping" then
    write_value(w, root)
    w:put("\n")
    return w:string()
  end
  for _, e in ipairs(root.items) do
    if e.value.kind ~= "mapping" then kv_line(w, ctx, e) end
  end
  for _, e in ipairs(root.items) do
    if e.value.kind == "mapping" then
      comment_lines(w, ctx, e.key.leading)
      if ctx.wrote then w:put("\n") end
      w:put("[")
      write_text(w, key_text(e.key))
      w:put("]\n")
      ctx.wrote = true
      for _, inner in ipairs(e.value.items) do
        if inner.value.kind == "mapping" then error("a section inside a section has no INI spelling", 0) end
        kv_line(w, ctx, inner)
      end
      comment_lines(w, ctx, e.value.dangling)
    end
  end
  comment_lines(w, ctx, root.dangling)
  return w:string()
end

return M
