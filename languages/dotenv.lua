-- dotenv, in Lua: the twin of fig's compiled `dotenv` format, row for row.
--
-- `fig lang check lua-dotenv --against dotenv <files…>` holds this script to
-- the compiled parser's node table on every file given, and this script is
-- written against `fig lang table -i dotenv`, which prints that table. What
-- the compiled format accepts is stated in fig's `src/languages/dotenv/`,
-- and this follows it line for line:
--
--   * a key is a bash identifier, `[A-Za-z_][A-Za-z0-9_]*`; an `export `
--     before one is recognized and discarded;
--   * a value is unquoted (trimmed, to end of line, or to a `#` that at
--     least one space or tab precedes), double-quoted (`\n \t \r \\ \"`
--     decoded, may span lines) or single-quoted (raw, may span lines);
--     a `\r\n` inside a quoted value reads as `\n`;
--   * a full-line `#` is a comment, leading for the next key, or dangling
--     on the root when no key follows; a `#` after a value on its line is
--     the value's trailing comment; a `#` right after a closing quote
--     needs no space before it;
--   * a repeated key keeps the FIRST entry's place and takes the LAST
--     value; the later key's own leading comments go with it.
--
-- Every value is a string: dotenv has no typed scalars and does no `$VAR`
-- interpolation. Spans are byte offsets, 0-based, `[start, end)`.

local M = {}

M.name = "lua-dotenv"
M.caps = { read = true, edit = true, serialize = true }
-- Flat: no mapping inside the root.
M.max_mapping_depth = 0
M.syntax = {
  comments = { style = "hash", line = { open = "#" }, trailing = { open = "#" } },
  kv_sep = "=",
  empty_map_literal = "{}",
  flow_containers = false,
}
M.dialects = {
  -- `env`, the extension: the compiled format owns `.env` too, and a
  -- compiled format's extension wins, so this is reached by `--lang`.
  { name = "lua-dotenv", extensions = { "env" }, splice = "raw", empty_doc_seed = "" },
}
M.samples = {
  "A=1\nB=\"two words\"\n",
  "# top\nexport C='raw \\n'\nD=x # trailing\n",
}
M.renderers = {}

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  UnexpectedToken = "unexpected content here; expected `KEY=value` (optionally `export KEY=value`)",
  MissingEquals = "expected `=` after this key; every dotenv line is `KEY=value`",
  BadEscape = "invalid escape in a double-quoted value; supported: \\n \\t \\r \\\\ \\\" — use a single-quoted value for raw text with backslashes",
  InvalidUtf8 = "this file is not valid UTF-8; dotenv documents must be UTF-8 encoded",
  UnexpectedCarriageReturn = "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
  UnclosedString = "unclosed quoted value; expected a matching `\"`/`'` before the end of the file",
  UnexpectedChar = "not a valid key here; a dotenv key is a bash identifier (`[A-Za-z_][A-Za-z0-9_]*`)",
  TrailingContent = "unexpected content after this quoted value; only a `#` comment may follow it on the same line",
}

-- A failure carries the code and the 0-based offset it is about.
local function fail(code, at)
  error({ code = code, at = at }, 0)
end

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- Tokens are `{kind=, s=, e=}` with 0-based `[s, e)` spans, in the order
-- the compiled tokenizer emits them. `i` below is 0-based throughout;
-- `byte(i)` reads the byte at 0-based `i`.

local SPACE, TAB, NL, CR, HASH, EQ, DQ, SQ, BACKSLASH = 32, 9, 10, 13, 35, 61, 34, 39, 92

local function is_ident_start(c)
  return c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
end
local function is_ident_char(c)
  return is_ident_start(c) or (c >= 48 and c <= 57)
end

local function tokenize(src)
  local n = #src
  local byte = function(i) return string.byte(src, i + 1) end
  local tokens = {}
  local function emit(kind, s, e) tokens[#tokens + 1] = { kind = kind, s = s, e = e } end
  local i = 0
  local in_value = false

  if src:sub(1, 3) == "\239\187\191" then i = 3 end

  local function at_line_end(at)
    return at >= n or byte(at) == NL or byte(at) == CR
  end

  -- Content only, the `#` excluded.
  local function lex_comment()
    i = i + 1
    local s = i
    while not at_line_end(i) do i = i + 1 end
    emit("comment", s, i)
  end

  local function lex_key()
    local s = i
    i = i + 1
    while i < n and is_ident_char(byte(i)) do i = i + 1 end
    emit("key", s, i)
  end

  local function lex_quoted(q, kind)
    local s = i
    i = i + 1
    local escapes = q == DQ
    while i < n do
      local c = byte(i)
      if c == CR then
        if i + 1 < n and byte(i + 1) == NL then
          i = i + 2
        else
          fail("UnexpectedCarriageReturn", i)
        end
      elseif escapes and c == BACKSLASH then
        if i + 1 >= n then fail("UnclosedString", i) end
        i = i + 2
      elseif c == q then
        i = i + 1
        emit(kind, s, i)
        return
      else
        i = i + 1
      end
    end
    fail("UnclosedString", i)
  end

  local function after_quoted_value()
    while i < n and (byte(i) == SPACE or byte(i) == TAB) do i = i + 1 end
    if i < n and byte(i) == HASH then
      lex_comment()
      return
    end
    if not at_line_end(i) then fail("TrailingContent", i) end
  end

  local function trim_start(s)
    while s < n and (byte(s) == SPACE or byte(s) == TAB) do s = s + 1 end
    return s
  end
  local function trim_end(s, e)
    while e > s and (byte(e - 1) == SPACE or byte(e - 1) == TAB) do e = e - 1 end
    return e
  end

  local function lex_unquoted()
    local s = i
    local e = s
    -- The whitespace after `=` was skipped by the main loop, so a `#`
    -- sitting right here needs to know whitespace preceded it.
    local saw_space = i > 0 and (byte(i - 1) == SPACE or byte(i - 1) == TAB)
    while i < n do
      local c = byte(i)
      if c == NL or c == CR then break end
      if c == HASH and saw_space then break end
      saw_space = (c == SPACE or c == TAB)
      i = i + 1
      e = i
    end
    emit("unquoted", trim_start(s), trim_end(s, e))
    if i < n and byte(i) == HASH then lex_comment() end
  end

  while i < n do
    local c = byte(i)
    if c == NL then
      emit("newline", i, i + 1)
      i = i + 1
      in_value = false
    elseif c == CR then
      if i + 1 < n and byte(i + 1) == NL then
        emit("newline", i, i + 2)
        i = i + 2
        in_value = false
      else
        fail("UnexpectedCarriageReturn", i)
      end
    elseif c == SPACE or c == TAB then
      i = i + 1
    elseif in_value then
      if c == DQ then
        lex_quoted(DQ, "double_quoted")
        after_quoted_value()
      elseif c == SQ then
        lex_quoted(SQ, "single_quoted")
        after_quoted_value()
      else
        lex_unquoted()
      end
    else
      if c == HASH then
        lex_comment()
      elseif c == EQ then
        emit("equals", i, i + 1)
        i = i + 1
        in_value = true
      elseif is_ident_start(c) then
        lex_key()
      else
        fail("UnexpectedChar", i)
      end
    end
  end
  emit("end_of_file", n, n)
  return tokens
end

-- ── value decoding ────────────────────────────────────────────────────────

local function normalize_crlf(s)
  return (s:gsub("\r\n", "\n"))
end

local function decode_single(raw)
  local inner = raw:sub(2, -2)
  if not inner:find("\r", 1, true) then return inner end
  return normalize_crlf(inner)
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"' }

local function decode_double(raw, err_at)
  local inner = raw:sub(2, -2)
  local out = {}
  local i = 1
  local len = #inner
  while i <= len do
    local c = inner:sub(i, i)
    if c == "\r" and inner:sub(i + 1, i + 1) == "\n" then
      out[#out + 1] = "\n"
      i = i + 2
    elseif c == "\\" then
      local e = ESCAPES[inner:sub(i + 1, i + 1)]
      if not e then fail("BadEscape", err_at) end
      out[#out + 1] = e
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- ── the parser ────────────────────────────────────────────────────────────

local function parse_tokens(src, tokens)
  local pos = 1
  local function peek() return tokens[pos] end
  local function advance()
    local t = tokens[pos]
    if pos < #tokens then pos = pos + 1 end
    return t
  end
  local function text(t) return src:sub(t.s + 1, t.e) end

  -- The document, before it is laid out as rows: entries in first-seen
  -- order, each with a key and the value that currently wins.
  local entries = {}
  local by_name = {}
  local pending = {}
  local last_value = nil
  local dangling = {}

  local function capture_comment(t)
    local body = text(t):match("^[ \t\r]*(.-)[ \t\r]*$")
    if last_value then
      last_value.trailing = body
      last_value = nil
    else
      pending[#pending + 1] = body
    end
  end

  local function skip_blank()
    while true do
      local t = peek()
      if t.kind == "comment" then
        capture_comment(t)
        pos = pos + 1
      elseif t.kind == "newline" then
        last_value = nil
        pos = pos + 1
      else
        return
      end
    end
  end

  local function parse_key_value()
    local key_tok = advance()
    if text(key_tok) == "export" and peek().kind == "key" then
      key_tok = advance()
    end
    if peek().kind ~= "equals" then fail("MissingEquals", peek().s) end
    advance()

    local value_s, value_e = peek().s, peek().s
    local kind = nil
    local raw = ""
    local t = peek()
    if t.kind == "double_quoted" or t.kind == "single_quoted" or t.kind == "unquoted" then
      advance()
      raw = text(t)
      value_s, value_e = t.s, t.e
      kind = t.kind
    end
    local decoded
    if kind == "single_quoted" then
      decoded = decode_single(raw)
    elseif kind == "double_quoted" then
      decoded = decode_double(raw, peek().s)
    else
      decoded = raw
    end

    local key = { text = text(key_tok), s = key_tok.s, e = key_tok.e, leading = pending }
    pending = {}
    local value = { text = decoded, s = value_s, e = value_e }
    last_value = value
    local existing = by_name[key.text]
    if existing then
      -- The first entry keeps its place, its key and its span; the later
      -- value wins. The later key, and the comments on it, are unreachable.
      existing.value = value
    else
      local entry = { key = key, value = value, s = key.s, e = value.e }
      entries[#entries + 1] = entry
      by_name[key.text] = entry
    end
  end

  skip_blank()
  while peek().kind ~= "end_of_file" do
    if peek().kind == "key" then
      parse_key_value()
    else
      fail("UnexpectedToken", peek().s)
    end
    skip_blank()
  end
  dangling = pending

  -- Lay it out: root, then per entry the keyvalue, its key, its value.
  local t = fig.table()
  local root = t:row("mapping", nil, { 0, #src })
  for _, entry in ipairs(entries) do
    local kv = t:row("keyvalue", root, { entry.s, entry.e })
    local k = t:row("string", kv, { entry.key.s, entry.key.e }, { text = entry.key.text })
    local v = t:row("string", kv, { entry.value.s, entry.value.e }, { text = entry.value.text })
    for _, c in ipairs(entry.key.leading) do t:comment(k, "leading", "line", c) end
    if entry.value.trailing then t:comment(v, "trailing", "line", entry.value.trailing) end
  end
  for _, c in ipairs(dangling) do t:comment(root, "dangling", "line", c) end
  return t
end

function M.parse(_dialect, input)
  local ok_utf8, bad_at = utf8.len(input)
  if not ok_utf8 then
    return fig.fail(MESSAGES.InvalidUtf8, bad_at and bad_at - 1 or nil)
  end
  local ok, result = pcall(function()
    return parse_tokens(input, tokenize(input))
  end)
  if ok then return result end
  if type(result) == "table" and result.code then
    return fig.fail(MESSAGES[result.code] or result.code, result.at)
  end
  error(result, 0)
end

-- ── the printer ───────────────────────────────────────────────────────────
-- Canonical `.env`, as the compiled printer writes it: one `KEY=value` line
-- per entry, a value bare when that is unambiguous and double-quoted with
-- escapes otherwise (never a literal embedded newline), leading comments
-- as `# …` lines above the key, a trailing comment inline after the value,
-- dangling comments at the end.

local function is_identifier(name)
  return name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function needs_quoting(v)
  if v == "" then return false end
  local first, last = v:sub(1, 1), v:sub(-1)
  if first == " " or first == "\t" or last == " " or last == "\t" then return true end
  return v:find("[\n\r\"\\#]") ~= nil
end

local QUOTE = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\" }

local function write_text(out, v)
  if not needs_quoting(v) then
    out[#out + 1] = v
    return
  end
  out[#out + 1] = '"' .. v:gsub('[\n\r\t"\\]', QUOTE) .. '"'
end

local function write_value(out, row)
  local k = row.kind
  if k == "string" then
    write_text(out, row.text or "")
  elseif k == "int" or k == "float" or k == "bool" then
    out[#out + 1] = row.text or ""
  elseif k == "null" then
    error("dotenv has no null; a null value cannot be written", 0)
  elseif k == "sequence" or k == "mapping" then
    error("dotenv holds a flat map of strings; a nested value cannot be written", 0)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as dotenv", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

local function comment_lines(out, c)
  for line in (c.text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^[ \t]*(.-)[ \t]*$")
    if trimmed ~= "" then
      out[#out + 1] = "# " .. trimmed .. "\n"
    else
      out[#out + 1] = "#\n"
    end
  end
end

function M.print(_dialect, t, _options)
  local out = {}
  local root = t.byid(0)
  if root.kind ~= "mapping" then
    -- A fragment: the scalar as it stands alone.
    write_value(out, root)
    return table.concat(out)
  end
  for _, kv_id in ipairs(root.children) do
    local kv = t.byid(kv_id)
    local key, value = t.byid(kv.children[1]), t.byid(kv.children[2])
    if key.kind ~= "string" then error("a dotenv key must be a string", 0) end
    if not is_identifier(key.text or "") then
      error("`" .. (key.text or "") .. "` is not a dotenv key; a key is a bash identifier", 0)
    end
    for _, c in ipairs(key.leading) do comment_lines(out, c) end
    out[#out + 1] = key.text
    out[#out + 1] = "="
    write_value(out, value)
    local trailing = value.trailing[1]
    if trailing then
      out[#out + 1] = " #"
      if trailing.text ~= "" then
        out[#out + 1] = " " .. trailing.text:gsub("\n", " ")
      end
    end
    out[#out + 1] = "\n"
  end
  for _, c in ipairs(root.dangling) do comment_lines(out, c) end
  return table.concat(out)
end

return M
