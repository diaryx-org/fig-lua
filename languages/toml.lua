-- TOML, in Lua: the twin of fig's compiled `toml` format — TOML 1.1, the
-- default dialect — row for row, region for region, mention for mention.
--
-- `fig lang check lua-toml --against toml <files…>` holds this script to
-- the compiled parser's node table on every file given, and this script
-- is written against `fig lang table -i toml`, which prints that table.
-- What the compiled format accepts is stated in fig's `src/languages/toml/`
-- (`tokenizer.zig`, `parser.zig`, `printer.zig`), and this follows them
-- function for function. Where the grammar module would do, it is not
-- used: TOML is a section format, and what makes it one — the table a
-- `[header]` opens, the regions and mentions the editor moves a table by,
-- the rules for which line may extend which table — is exactly what the
-- compiled parser states by hand, so this states it by hand too.
--
-- The shape, as the compiled parser builds it:
--
--   * the root mapping spans the whole input; a `key = value` line is a
--     keyvalue from the key's start to the value's end; a string's span
--     includes its quotes, a container's its brackets;
--   * a `[a.b]` header, a `[[a]]` header and a dotted `a.b = 1` line each
--     make a *section* table per segment they create: a keyvalue and a
--     mapping whose span is just that segment's key text. An array of
--     tables is a sequence spanning its first header's key text, and so
--     is every element mapping in it. A header names the table again
--     rather than creating it when it exists;
--   * a table's *regions* are the header lines that created or reopened
--     it — `[a]`, `[[a]]`, and a dotted line for every table it passes
--     through — each the whole physical line; an element of an array of
--     tables carries its own `[[a]]` line, and the array every one;
--   * a table's *mentions* are every place its name is written: each
--     segment of a header (`header`) or of a dotted key (`entry`), on
--     the node that segment names — an array of tables, not its element;
--   * an integer's text is its decimal value (`0xff` → `255`, `1_000` →
--     `1000`, `+5` → `5`); a float keeps its lexeme minus underscores,
--     `+inf` is `inf`, every nan is `nan`; a datetime is a string with an
--     `ext_kind` and its lexeme as text;
--   * a comment on the line of a top-level `key = value` trails the value;
--     any other waits and leads the next key or header's key, whatever
--     it was inside — an array, a `[header]` line — and at the end of the
--     file dangles on the table the last header opened.
--
-- The refusals are the compiled parser's, in its words and at its
-- offsets, with one difference of order: the compiled tokenizer runs over
-- the whole file before its parser, so a file with a lexical error after
-- a grammatical one reports the lexical one; this reports the first.

local M = {}

M.name = "lua-toml"
M.caps = { read = true, edit = true, serialize = true }
-- TOML holds its four datetimes and inf/nan natively; nothing else is
-- native, so a null or an enum literal rides in a `$fig` envelope.
M.lossless = {
  offset_datetime = true, local_datetime = true, local_date = true, local_time = true,
  number_special = true,
}
M.syntax = {
  comments = { style = "hash", line = { open = "#" }, trailing = { open = "#" } },
  kv_sep = " = ",
  flow_map_pad = " ",
  key_style = "bare_or_quoted",
  empty_map_literal = "{}",
  block_seq_editable = false,
  section_noun = "table",
  section_header = { open = "[", close = "]", seq_open = "[[", seq_close = "]]" },
}
M.dialects = {
  -- The compiled format owns `.toml`, and a compiled format's extension
  -- wins, so this is reached by `--lang lua-toml`.
  { name = "lua-toml", extensions = { "toml" }, splice = "literal", empty_doc_seed = "" },
}
M.samples = {
  'a = 1\nb = [1, 2]\n\n[s]\nk = "v"\nt = { x = 1 }\n',
}
M.renderers = {}

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  UnexpectedToken = "unexpected token here; check for a missing `=`, `.`, `,`, or closing `]`/`}`",
  UnclosedString = "unclosed string; a single-line string cannot contain a literal newline — close the quote, or use a triple-quoted string (`\"\"\"`/`'''`) for multi-line text",
  BadEscape = "invalid escape; basic strings support \\b \\t \\n \\f \\r \\\" \\\\ \\uXXXX \\UXXXXXXXX — use a literal string ('...') for raw text with backslashes",
  InvalidUnicode = "invalid unicode escape; the hex digits do not form a valid Unicode codepoint",
  InvalidNumber = "not a valid TOML number; if this is text (a version, an id), quote it — TOML has no bare strings. Otherwise check the radix prefix, digit grouping (a single `_` between digits, none leading/trailing), and that there is no leading zero",
  UnquotedString = "TOML has no bare strings: a value that is not a number, boolean, date, array, or inline table must be quoted (`\"...\"`, or `'...'` for raw text)",
  InvalidDatetime = "not a valid RFC 3339 date/time",
  InvalidKey = "invalid key; a bare key allows only letters, digits, `-`, and `_` — quote it for anything else",
  DuplicateKey = "this key or table conflicts with one already defined; a TOML key or table may be defined only once",
  TrailingContent = "unexpected content after this line's value; each TOML statement must end its line (a `#` comment needs whitespace before it)",
  UnexpectedCarriageReturn = "a bare `\\r` must be followed by `\\n`; TOML line endings are `\\n` or `\\r\\n`",
  BadKey = "invalid key; expected a bare key, a quoted key, `.`, or `=` here",
  BadValue = "not a recognized value; TOML values are strings, numbers, booleans, datetimes, arrays, or inline tables",
  BadControlChar = "control characters are not allowed here (only tab is permitted outside a multi-line string)",
}

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- Line-oriented and context-sensitive, as the compiled one: the same bytes
-- are a bare key before `=` and a date after it, so a per-line key/value
-- position is tracked, and a stack of open `[`/`{` says whether an inline
-- table is at a key or a value.

local function is_bare_key_char(c)
  return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45
end

local function forbidden_inline(c) return (c < 32 and c ~= 9) or c == 127 end
local function forbidden_multiline(c) return (c < 32 and c ~= 9 and c ~= 10 and c ~= 13) or c == 127 end

local function is_value_terminator(c)
  return c == 32 or c == 9 or c == 10 or c == 13 or c == 35 or c == 44 or c == 93 or c == 125 or c == 61
end

local Tok = {}
Tok.__index = Tok

local function tokenize(src, minute_precision)
  local T = setmetatable({ src = src, n = #src, i = 0, tokens = {}, in_value = false, flow = {}, minute_precision = minute_precision }, Tok)
  if src:sub(1, 3) == "\239\187\191" then T.i = 3 end
  while T.i < T.n do
    local c = src:byte(T.i + 1)
    if c == 10 then
      T:emit("newline", T.i, T.i + 1)
      T.i = T.i + 1
      if #T.flow == 0 then T.in_value = false end
    elseif c == 13 then
      if src:byte(T.i + 2) == 10 then
        T:emit("newline", T.i, T.i + 2)
        T.i = T.i + 2
        if #T.flow == 0 then T.in_value = false end
      else
        fig.fail(MESSAGES.UnexpectedCarriageReturn, T.i)
      end
    elseif c == 32 or c == 9 then
      local s = T.i
      while T.i < T.n and (src:byte(T.i + 1) == 32 or src:byte(T.i + 1) == 9) do T.i = T.i + 1 end
      T:emit("whitespace", s, T.i)
    elseif c == 35 then
      local s = T.i
      while T.i < T.n and src:byte(T.i + 1) ~= 10 and src:byte(T.i + 1) ~= 13 do
        if forbidden_inline(src:byte(T.i + 1)) then fig.fail(MESSAGES.BadControlChar, T.i) end
        T.i = T.i + 1
      end
      T:emit("comment", s, T.i)
    elseif T.in_value or #T.flow > 0 then
      T:lex_value()
    else
      T:lex_key_context()
    end
  end
  T:emit("end_of_file", T.n, T.n)
  return T.tokens
end

function Tok:emit(kind, s, e)
  self.tokens[#self.tokens + 1] = { kind = kind, s = s, e = e }
end

function Tok:byte(k) return self.src:byte(self.i + 1 + (k or 0)) end

function Tok:lex_key_context()
  local c = self:byte()
  if c == 61 then
    self:emit("equals", self.i, self.i + 1)
    self.i = self.i + 1
    self.in_value = true
  elseif c == 46 then
    self:emit("dot", self.i, self.i + 1)
    self.i = self.i + 1
  elseif c == 91 then
    if self:byte(1) == 91 then
      self:emit("double_open_bracket", self.i, self.i + 2)
      self.i = self.i + 2
    else
      self:emit("open_bracket", self.i, self.i + 1)
      self.i = self.i + 1
    end
  elseif c == 93 then
    if self:byte(1) == 93 then
      self:emit("double_close_bracket", self.i, self.i + 2)
      self.i = self.i + 2
    else
      self:emit("close_bracket", self.i, self.i + 1)
      self.i = self.i + 1
    end
  elseif c == 34 or c == 39 then
    local s = self.i
    self:scan_single_line_string(c)
    self:emit("key", s, self.i)
  else
    self:lex_bare_key()
  end
end

function Tok:lex_bare_key()
  local s = self.i
  while self.i < self.n and is_bare_key_char(self:byte()) do self.i = self.i + 1 end
  if self.i == s then fig.fail(MESSAGES.BadKey, self.i) end
  self:emit("key", s, self.i)
end

function Tok:at_inline_key()
  local top = self.flow[#self.flow]
  return top ~= nil and top.table and top.expect_key
end

function Tok:lex_value()
  local c = self:byte()
  if c == 91 then
    self:emit("open_bracket", self.i, self.i + 1)
    self.i = self.i + 1
    self.flow[#self.flow + 1] = { table = false }
  elseif c == 93 then
    if #self.flow > 0 then self.flow[#self.flow] = nil end
    self:emit("close_bracket", self.i, self.i + 1)
    self.i = self.i + 1
  elseif c == 123 then
    self:emit("open_brace", self.i, self.i + 1)
    self.i = self.i + 1
    self.flow[#self.flow + 1] = { table = true, expect_key = true }
  elseif c == 125 then
    if #self.flow > 0 then self.flow[#self.flow] = nil end
    self:emit("close_brace", self.i, self.i + 1)
    self.i = self.i + 1
  elseif c == 44 then
    self:emit("comma", self.i, self.i + 1)
    self.i = self.i + 1
    local top = self.flow[#self.flow]
    if top and top.table then top.expect_key = true end
  elseif c == 61 then
    self:emit("equals", self.i, self.i + 1)
    self.i = self.i + 1
    local top = self.flow[#self.flow]
    if top and top.table then top.expect_key = false end
  elseif c == 46 then
    self:emit("dot", self.i, self.i + 1)
    self.i = self.i + 1
  elseif c == 34 or c == 39 then
    -- A quoted key in inline-table key position, else a string value;
    -- both lex the same and the parser reads them by position.
    local s = self.i
    if self:byte(1) == c and self:byte(2) == c and self.i + 2 < self.n then
      self:scan_multi_line_string(c)
    else
      self:scan_single_line_string(c)
    end
    self:emit("string", s, self.i)
  else
    if self:at_inline_key() then return self:lex_bare_key() end
    local e = self:match_datetime(self.i)
    if e then
      self:emit("datetime", self.i, e)
      self.i = e
      return
    end
    local s = self.i
    while self.i < self.n and not is_value_terminator(self:byte()) do self.i = self.i + 1 end
    if self.i == s then fig.fail(MESSAGES.BadValue, self.i) end
    local word = self.src:sub(s + 1, self.i)
    self:emit((word == "true" or word == "false") and "boolean" or "number", s, self.i)
  end
end

function Tok:scan_single_line_string(q)
  self.i = self.i + 1
  local basic = q == 34
  while self.i < self.n do
    local c = self:byte()
    if c == 10 or c == 13 then fig.fail(MESSAGES.UnclosedString, self.i) end
    if forbidden_inline(c) then fig.fail(MESSAGES.BadControlChar, self.i) end
    if basic and c == 92 then
      self.i = self.i + 2
    elseif c == q then
      self.i = self.i + 1
      return
    else
      self.i = self.i + 1
    end
  end
  fig.fail(MESSAGES.UnclosedString, self.i)
end

function Tok:scan_multi_line_string(q)
  self.i = self.i + 3
  local basic = q == 34
  while self.i < self.n do
    local c = self:byte()
    if forbidden_multiline(c) then fig.fail(MESSAGES.BadControlChar, self.i) end
    if c == 13 and self:byte(1) ~= 10 then fig.fail(MESSAGES.BadControlChar, self.i) end
    if basic and c == 92 then
      self.i = self.i + 2
    elseif c == q and self:byte(1) == q and self:byte(2) == q then
      self.i = self.i + 3
      -- Up to two more quotes may hug the close.
      local extra = 0
      while extra < 2 and self.i < self.n and self:byte() == q do
        self.i = self.i + 1
        extra = extra + 1
      end
      return
    else
      self.i = self.i + 1
    end
  end
  fig.fail(MESSAGES.UnclosedString, self.i)
end

function Tok:digits_at(at, k)
  if at + k > self.n then return false end
  for j = at + 1, at + k do
    local c = self.src:byte(j)
    if c < 48 or c > 57 then return false end
  end
  return true
end

function Tok:char_at(at, ch) return at < self.n and self.src:byte(at + 1) == ch end

-- The shape of a datetime, the range checks being the parser's.
function Tok:match_datetime(at)
  if self:digits_at(at, 4) and self:char_at(at + 4, 45) and self:digits_at(at + 5, 2) and self:char_at(at + 7, 45) and self:digits_at(at + 8, 2) then
    local date_end = at + 10
    local sep
    if self:char_at(date_end, 84) or self:char_at(date_end, 116) then
      sep = date_end + 1
    elseif self:char_at(date_end, 32) and self:match_time(date_end + 1) then
      sep = date_end + 1
    end
    if sep then
      local time_end = self:match_time(sep)
      if not time_end then return date_end end
      return self:match_offset(time_end) or time_end
    end
    return date_end
  end
  return self:match_time(at)
end

function Tok:match_time(at)
  if not (self:digits_at(at, 2) and self:char_at(at + 2, 58) and self:digits_at(at + 3, 2)) then return nil end
  local e = at + 5
  if self:char_at(e, 58) and self:digits_at(e + 1, 2) then
    e = e + 3
    if self:char_at(e, 46) then
      local f = e + 1
      if not self:digits_at(f, 1) then return nil end
      while self:digits_at(f, 1) do f = f + 1 end
      e = f
    end
  elseif not self.minute_precision then
    return nil
  end
  return e
end

function Tok:match_offset(at)
  if self:char_at(at, 90) or self:char_at(at, 122) then return at + 1 end
  if (self:char_at(at, 43) or self:char_at(at, 45)) and self:digits_at(at + 1, 2) and self:char_at(at + 3, 58) and self:digits_at(at + 4, 2) then
    return at + 6
  end
  return nil
end

-- ── scalars ───────────────────────────────────────────────────────────────

local function valid_underscored(s, pred)
  if s == "" then return false end
  if s:sub(1, 1) == "_" or s:sub(-1) == "_" then return false end
  local prev_us = false
  for j = 1, #s do
    local c = s:byte(j)
    if c == 95 then
      if prev_us then return false end
      prev_us = true
    elseif pred(c) then
      prev_us = false
    else
      return false
    end
  end
  return true
end

local function is_digit(c) return c >= 48 and c <= 57 end
local function is_hex(c) return is_digit(c) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102) end
local function is_octal(c) return c >= 48 and c <= 55 end
local function is_binary(c) return c == 48 or c == 49 end

local function valid_decimal_int(s)
  if not valid_underscored(s, is_digit) then return false end
  if #s > 1 and s:sub(1, 1) == "0" then return false end
  return true
end

local SPECIALS = { inf = true, ["+inf"] = true, ["-inf"] = true, nan = true, ["+nan"] = true, ["-nan"] = true }

-- "int", "float", or nil for not a number.
local function classify_number(raw)
  if raw == "" then return nil end
  if SPECIALS[raw] then return "float" end
  if #raw >= 2 and raw:sub(1, 1) == "0" then
    local r = raw:sub(2, 2)
    if r == "x" then return valid_underscored(raw:sub(3), is_hex) and "int" or nil end
    if r == "o" then return valid_underscored(raw:sub(3), is_octal) and "int" or nil end
    if r == "b" then return valid_underscored(raw:sub(3), is_binary) and "int" or nil end
  end
  local body = raw
  local first = body:sub(1, 1)
  if first == "+" or first == "-" then body = body:sub(2) end
  if body == "" then return nil end
  local mantissa, exponent = body, nil
  local e = body:find("[eE]")
  if e then
    mantissa = body:sub(1, e - 1)
    exponent = body:sub(e + 1)
  end
  local int_part, frac_part = mantissa, nil
  local d = mantissa:find(".", 1, true)
  if d then
    int_part = mantissa:sub(1, d - 1)
    frac_part = mantissa:sub(d + 1)
  end
  if not valid_decimal_int(int_part) then return nil end
  local is_float = false
  if frac_part then
    if not valid_underscored(frac_part, is_digit) then return nil end
    is_float = true
  end
  if exponent then
    local ex = exponent
    local es = ex:sub(1, 1)
    if es == "+" or es == "-" then ex = ex:sub(2) end
    if not valid_underscored(ex, is_digit) then return nil end
    is_float = true
  end
  return is_float and "float" or "int"
end

local function looks_numeric(raw)
  local body = raw
  local first = body:sub(1, 1)
  if first == "+" or first == "-" then body = body:sub(2) end
  if body == "" then return false end
  if body == "inf" or body == "nan" then return true end
  return is_digit(body:byte(1))
end

-- A decimal integer's text is its value: radix and underscores gone, a
-- `+` dropped, `-0` is `0`. Beyond i64 the compiled parser refuses, so a
-- radix literal past sixteen hex, twenty-two octal or sixty-four binary
-- digits (leading zeros aside) is refused here, where Lua would wrap.
local RADIX = { x = { 16, 16 }, o = { 8, 22 }, b = { 2, 64 } }

local function canonical_int(raw)
  local digits = raw:gsub("_", "")
  local radix = RADIX[digits:sub(2, 2)]
  if digits:sub(1, 1) == "0" and radix then
    local body = digits:sub(3):gsub("^0+", "")
    if #body > radix[2] then return nil end
    local v = tonumber(body == "" and "0" or body, radix[1])
    if v == nil or v < 0 then return nil end
    return string.format("%d", v)
  end
  if digits:sub(1, 1) == "+" then digits = digits:sub(2) end
  local v = math.tointeger(tonumber(digits))
  if v == nil then return nil end
  return string.format("%d", v)
end

local function canonical_float(raw)
  if raw == "inf" or raw == "+inf" then return "inf" end
  if raw == "-inf" then return "-inf" end
  if raw == "nan" or raw == "+nan" or raw == "-nan" then return "nan" end
  return (raw:gsub("_", ""))
end

-- RFC 3339, as fig's shared `util.datetime` validates it.
local function two(s, at) return tonumber(s:sub(at, at + 1)) end
local function both_digits(s, at)
  local a, b = s:byte(at), s:byte(at + 1)
  return a ~= nil and b ~= nil and is_digit(a) and is_digit(b)
end

local function days_in_month(year, month)
  if month == 2 then
    local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
    return leap and 29 or 28
  end
  if month == 4 or month == 6 or month == 9 or month == 11 then return 30 end
  return 31
end

local function valid_date(s)
  if #s ~= 10 or s:sub(5, 5) ~= "-" or s:sub(8, 8) ~= "-" then return false end
  if not (both_digits(s, 1) and both_digits(s, 3) and both_digits(s, 6) and both_digits(s, 9)) then return false end
  local year = two(s, 1) * 100 + two(s, 3)
  local month, day = two(s, 6), two(s, 9)
  if month < 1 or month > 12 then return false end
  if day < 1 or day > days_in_month(year, month) then return false end
  return true
end

local function valid_time(s, minute_precision)
  if #s < 5 or s:sub(3, 3) ~= ":" then return false end
  if not (both_digits(s, 1) and both_digits(s, 4)) then return false end
  if two(s, 1) > 23 or two(s, 4) > 59 then return false end
  if #s == 5 then return minute_precision end
  if s:sub(6, 6) ~= ":" or #s < 8 then return false end
  if not both_digits(s, 7) or two(s, 7) > 60 then return false end
  if #s == 8 then return true end
  if s:sub(9, 9) ~= "." or #s < 10 then return false end
  return s:sub(10):match("^%d+$") ~= nil
end

local function valid_offset(s)
  if #s ~= 6 or s:sub(4, 4) ~= ":" then return false end
  if not (both_digits(s, 2) and both_digits(s, 5)) then return false end
  return two(s, 2) <= 23 and two(s, 5) <= 59
end

local function classify_datetime(raw, minute_precision)
  if #raw >= 3 and raw:sub(3, 3) == ":" then
    return valid_time(raw, minute_precision) and "local_time" or nil
  end
  if #raw < 10 then return nil end
  if not valid_date(raw:sub(1, 10)) then return nil end
  if #raw == 10 then return "local_date" end
  local sep = raw:sub(11, 11)
  if sep ~= "T" and sep ~= "t" and sep ~= " " then return nil end
  local rest = raw:sub(12)
  local time_str, has_offset = rest, false
  local last = rest:sub(-1)
  if last == "Z" or last == "z" then
    time_str = rest:sub(1, -2)
    has_offset = true
  elseif #rest >= 6 and (rest:sub(-6, -6) == "+" or rest:sub(-6, -6) == "-") and rest:sub(-3, -3) == ":" then
    if not valid_offset(rest:sub(-6)) then return nil end
    time_str = rest:sub(1, -7)
    has_offset = true
  end
  if not valid_time(time_str, minute_precision) then return nil end
  return has_offset and "offset_datetime" or "local_datetime"
end

-- ── string decoding ───────────────────────────────────────────────────────

local function trim_leading_newline(inner)
  if inner:sub(1, 1) == "\n" then return inner:sub(2) end
  if inner:sub(1, 2) == "\r\n" then return inner:sub(3) end
  return inner
end

local SIMPLE = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

-- A codepoint as UTF-8, or nil where the compiled parser refuses it: a
-- surrogate, or past U+10FFFF.
local function utf8_of(cp)
  if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil end
  return utf8.char(cp)
end

local P = {}
P.__index = P

function P:decode_basic(inner, multiline, at)
  local out = {}
  local i = 1
  local n = #inner
  while i <= n do
    local c = inner:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      if i + 1 > n then self:fail_at(at, MESSAGES.BadEscape) end
      local e = inner:sub(i + 1, i + 1)
      if SIMPLE[e] then
        out[#out + 1] = SIMPLE[e]
        i = i + 2
      elseif e == "u" or e == "U" or e == "x" then
        local width = e == "u" and 4 or e == "U" and 8 or 2
        if e == "x" and not self.v11 then self:fail_at(at, MESSAGES.BadEscape) end
        if i + 1 + width > n then self:fail_at(at, MESSAGES.BadEscape) end
        local hex = inner:sub(i + 2, i + 1 + width)
        if not hex:match("^%x+$") then self:fail_at(at, MESSAGES.InvalidUnicode) end
        local ch = utf8_of(tonumber(hex, 16))
        if not ch then self:fail_at(at, MESSAGES.InvalidUnicode) end
        out[#out + 1] = ch
        i = i + 2 + width
      elseif e == "e" then
        if not self.v11 then self:fail_at(at, MESSAGES.BadEscape) end
        out[#out + 1] = "\27"
        i = i + 2
      elseif e == " " or e == "\t" or e == "\n" or e == "\r" then
        if not multiline then self:fail_at(at, MESSAGES.BadEscape) end
        -- A line-ending backslash: whitespace, then a newline, then every
        -- blank up to the next content, all trimmed.
        local j = i + 1
        while j <= n and (inner:sub(j, j) == " " or inner:sub(j, j) == "\t") do j = j + 1 end
        if j > n or (inner:sub(j, j) ~= "\n" and inner:sub(j, j) ~= "\r") then self:fail_at(at, MESSAGES.BadEscape) end
        while j <= n and inner:sub(j, j):match("[ \t\r\n]") do j = j + 1 end
        i = j
      else
        self:fail_at(at, MESSAGES.BadEscape)
      end
    end
  end
  return table.concat(out)
end

-- Any of the four string forms to its value. `at` is where a refusal is
-- reported: the compiled parser has consumed the token by then and its
-- caret rests on what follows.
function P:decode_string(raw, at)
  if #raw < 2 then self:fail_at(at, MESSAGES.UnclosedString) end
  local q = raw:sub(1, 1)
  local triple = #raw >= 6 and raw:sub(2, 2) == q and raw:sub(3, 3) == q
  if q == "'" then
    if triple then return trim_leading_newline(raw:sub(4, -4)) end
    return raw:sub(2, -2)
  end
  if triple then return self:decode_basic(trim_leading_newline(raw:sub(4, -4)), true, at) end
  local inner = raw:sub(2, -2)
  if not inner:find("\\", 1, true) then return inner end
  return self:decode_basic(inner, false, at)
end

-- ── the parser ────────────────────────────────────────────────────────────
-- Over the token list, with the cursor's token as the default place a
-- refusal points to; `fail_at` pins another where the cursor has already
-- moved past the offender, as the compiled `failSpan` does.

local function new_parser(src, tokens, v11)
  return setmetatable({
    src = src,
    tokens = tokens,
    pos = 1,
    v11 = v11,
    pending = {}, -- comments waiting for a key
    last_value = nil, -- the node a same-line comment trails
    meta = {}, -- per table: explicit / dotted / implicit / aot / inline_table
  }, P)
end

function P:peek() return self.tokens[self.pos] end

function P:advance()
  local t = self.tokens[self.pos]
  if self.pos < #self.tokens then self.pos = self.pos + 1 end
  return t
end

function P:fail(message) fig.fail(message, self:peek().s) end
function P:fail_at(at, message) fig.fail(message, at) end

function P:text(t) return self.src:sub(t.s + 1, t.e) end

local function comment_text(raw)
  local body = raw:sub(1, 1) == "#" and raw:sub(2) or raw
  return body:match("^[ \t\r]*(.-)[ \t\r]*$")
end

function P:capture_comment(t)
  local text = comment_text(self:text(t))
  if self.last_value then
    self.last_value:comment("trailing", text)
    self.last_value = nil
  else
    self.pending[#self.pending + 1] = text
  end
end

-- Whitespace and comments, not newlines: a comment here is on the current
-- line, so it can trail a just-parsed value.
function P:skip_inline()
  while true do
    local k = self:peek().kind
    if k == "whitespace" then
      self.pos = self.pos + 1
    elseif k == "comment" then
      self:capture_comment(self:peek())
      self.pos = self.pos + 1
    else
      return
    end
  end
end

-- Whitespace, comments and blank lines; a newline closes the trailing
-- window, so comments past it lead the next entry.
function P:skip_blank()
  while true do
    local k = self:peek().kind
    if k == "whitespace" then
      self.pos = self.pos + 1
    elseif k == "comment" then
      self:capture_comment(self:peek())
      self.pos = self.pos + 1
    elseif k == "newline" then
      self.last_value = nil
      self.pos = self.pos + 1
    else
      return
    end
  end
end

function P:skip_flow_ws()
  if self.v11 then self:skip_blank() else self:skip_inline() end
end

function P:claim_leading(node)
  for _, text in ipairs(self.pending) do node:comment("leading", text) end
  self.pending = {}
end

function P:claim_dangling(node)
  for _, text in ipairs(self.pending) do node:comment("dangling", text) end
  self.pending = {}
end

function P:require_line_end()
  self:skip_inline()
  local k = self:peek().kind
  if k ~= "newline" and k ~= "end_of_file" then self:fail(MESSAGES.TrailingContent) end
end

-- The whole physical line holding `at`, newline included: a region.
function P:line_region(at)
  local src = self.src
  local s = at
  while s > 0 and src:byte(s) ~= 10 do s = s - 1 end
  local e = at
  while e < #src and src:byte(e + 1) ~= 10 do e = e + 1 end
  if e < #src then e = e + 1 end
  return { s, e }
end

local function add_region(node, r)
  node.regions = node.regions or {}
  node.regions[#node.regions + 1] = r
end

local function add_mention(node, span, kind)
  node.mentions = node.mentions or {}
  node.mentions[#node.mentions + 1] = { span = span, kind = kind }
end

function P:record_header(node, at) add_region(node, self:line_region(at)) end

-- ── keys ──

function P:decode_key(t)
  local raw = self:text(t)
  if raw == "" then self:fail(MESSAGES.InvalidKey) end
  local c = raw:sub(1, 1)
  if c == '"' or c == "'" then return self:decode_string(raw, self:peek().s) end
  return raw
end

-- `a.b.c`: the cursor at the first key.
function P:parse_key_path()
  local segs = {}
  while true do
    local t = self:peek()
    if t.kind ~= "key" then self:fail(MESSAGES.UnexpectedToken) end
    self:advance()
    segs[#segs + 1] = { str = self:decode_key(t), span = { t.s, t.e } }
    self:skip_inline()
    if self:peek().kind ~= "dot" then return segs end
    self:advance()
    self:skip_inline()
  end
end

function P:lookup_child(map, key)
  for _, e in ipairs(map.entries) do
    if e.key.text == key then return e.value end
  end
  return nil
end

function P:append_key_value(map, seg, value)
  local key = fig.scalar("string", seg.span, seg.str)
  self:claim_leading(key)
  local e = fig.entry(key, value, { seg.span[1], value.span[2] })
  map.entries[#map.entries + 1] = e
  return e
end

function P:create_table(parent, seg, meta)
  local m = fig.mapping(seg.span, { duplicates = "keep" })
  self:append_key_value(parent, seg, m)
  self.meta[m] = meta
  self:record_header(m, seg.span[1])
  return m
end

function P:last_element(seq)
  local last = seq.items[#seq.items]
  if not last then self:fail(MESSAGES.DuplicateKey) end
  return last
end

function P:append_array_element(seq)
  local elem = fig.mapping(seq.span, { duplicates = "keep" })
  seq.items[#seq.items + 1] = elem
  return elem
end

-- An existing path node to continue from: a table itself, an array of
-- tables its last element; anything else is a conflict.
function P:descend(child, seg)
  local meta = self.meta[child] or {}
  if child.kind == "mapping" then
    if meta.inline_table then self:fail_at(seg.span[1], MESSAGES.DuplicateKey) end
    return child
  elseif child.kind == "sequence" then
    if not meta.aot then self:fail_at(seg.span[1], MESSAGES.DuplicateKey) end
    return self:last_element(child)
  end
  self:fail_at(seg.span[1], MESSAGES.DuplicateKey)
end

function P:navigate_header_path(start, segs, count)
  local cur = start
  for j = 1, count do
    local seg = segs[j]
    local child = self:lookup_child(cur, seg.str)
    if child then
      add_mention(child, seg.span, "header")
      cur = self:descend(child, seg)
    else
      cur = self:create_table(cur, seg, { implicit = true })
      add_mention(cur, seg.span, "header")
    end
  end
  return cur
end

function P:navigate_dotted_path(start, segs, count)
  local cur = start
  for j = 1, count do
    local seg = segs[j]
    local child = self:lookup_child(cur, seg.str)
    if child then
      if child.kind ~= "mapping" then self:fail_at(seg.span[1], MESSAGES.DuplicateKey) end
      local meta = self.meta[child] or {}
      if meta.explicit or meta.inline_table then self:fail_at(seg.span[1], MESSAGES.DuplicateKey) end
      self:record_header(child, seg.span[1])
      add_mention(child, seg.span, "entry")
      cur = child
    else
      cur = self:create_table(cur, seg, { dotted = true })
      add_mention(cur, seg.span, "entry")
    end
  end
  return cur
end

-- ── statements ──

function P:parse_table_header()
  self:advance() -- [
  self:skip_inline()
  local segs = self:parse_key_path()
  self:skip_inline()
  if self:peek().kind ~= "close_bracket" then self:fail(MESSAGES.UnexpectedToken) end
  self:advance()
  local cur = self:navigate_header_path(self.root, segs, #segs - 1)
  local final = segs[#segs]
  local child = self:lookup_child(cur, final.str)
  if child then
    if child.kind ~= "mapping" then self:fail_at(final.span[1], MESSAGES.DuplicateKey) end
    local meta = self.meta[child] or {}
    if meta.explicit or meta.dotted or meta.inline_table then self:fail_at(final.span[1], MESSAGES.DuplicateKey) end
    self.meta[child] = { explicit = true }
    self:record_header(child, final.span[1])
    add_mention(child, final.span, "header")
    self.current = child
  else
    self.current = self:create_table(cur, final, { explicit = true })
    add_mention(self.current, final.span, "header")
  end
end

function P:parse_array_table()
  self:advance() -- [[
  self:skip_inline()
  local segs = self:parse_key_path()
  self:skip_inline()
  if self:peek().kind ~= "double_close_bracket" then self:fail(MESSAGES.UnexpectedToken) end
  self:advance()
  local cur = self:navigate_header_path(self.root, segs, #segs - 1)
  local final = segs[#segs]
  local child = self:lookup_child(cur, final.str)
  if child then
    local meta = self.meta[child] or {}
    if child.kind ~= "sequence" or not meta.aot then self:fail_at(final.span[1], MESSAGES.DuplicateKey) end
    self:record_header(child, final.span[1])
    add_mention(child, final.span, "header")
    self.current = self:append_array_element(child)
  else
    local seq = fig.sequence(final.span)
    self:append_key_value(cur, final, seq)
    self.meta[seq] = { aot = true }
    self:record_header(seq, final.span[1])
    add_mention(seq, final.span, "header")
    self.current = self:append_array_element(seq)
  end
  -- The element shares the array's span, so its `[[…]]` line is recorded
  -- on the element too: the only way its header is findable.
  self:record_header(self.current, final.span[1])
end

function P:parse_key_value()
  local segs = self:parse_key_path()
  self:skip_inline()
  if self:peek().kind ~= "equals" then self:fail(MESSAGES.UnexpectedToken) end
  self:advance()
  self:skip_inline()
  local cur = self:navigate_dotted_path(self.current, segs, #segs - 1)
  local final = segs[#segs]
  if self:lookup_child(cur, final.str) then self:fail_at(final.span[1], MESSAGES.DuplicateKey) end
  local value = self:parse_value()
  self.last_value = value
  self:append_key_value(cur, final, value)
end

-- ── values ──

function P:parse_value()
  local t = self:peek()
  local k = t.kind
  if k == "string" then
    self:advance()
    return fig.scalar("string", { t.s, t.e }, self:decode_string(self:text(t), self:peek().s))
  elseif k == "number" then
    self:advance()
    local raw = self:text(t)
    local kind = classify_number(raw)
    if not kind then
      self:fail_at(t.s, looks_numeric(raw) and MESSAGES.InvalidNumber or MESSAGES.UnquotedString)
    end
    local canon
    if kind == "int" then
      canon = canonical_int(raw)
      if not canon then self:fail_at(t.s, MESSAGES.InvalidNumber) end
    else
      canon = canonical_float(raw)
    end
    return fig.scalar(kind, { t.s, t.e }, canon)
  elseif k == "datetime" then
    self:advance()
    local raw = self:text(t)
    local shape = classify_datetime(raw, self.v11)
    if not shape then self:fail(MESSAGES.InvalidDatetime) end
    return fig.scalar("string", { t.s, t.e }, raw, { ext_kind = shape })
  elseif k == "boolean" then
    self:advance()
    return fig.scalar("bool", { t.s, t.e }, self:text(t))
  elseif k == "open_bracket" then
    return self:parse_array()
  elseif k == "open_brace" then
    return self:parse_inline_table()
  end
  self:fail(MESSAGES.UnexpectedToken)
end

function P:parse_array()
  local start = self:peek().s
  self:advance()
  local seq = fig.sequence({ start, start + 1 })
  while true do
    self:skip_blank()
    if self:peek().kind == "close_bracket" then break end
    seq.items[#seq.items + 1] = self:parse_value()
    self:skip_blank()
    local k = self:peek().kind
    if k == "comma" then
      self:advance()
    elseif k == "close_bracket" then
      break
    else
      self:fail(MESSAGES.UnexpectedToken)
    end
  end
  seq.span = { start, self:peek().e }
  self:advance()
  return seq
end

function P:decode_inline_key(t)
  local k = t.kind
  if k == "string" then return self:decode_string(self:text(t), self:peek().s) end
  if k == "key" then return self:text(t) end
  if k == "number" or k == "boolean" or k == "datetime" then
    local text = self:text(t)
    if text == "" then self:fail(MESSAGES.InvalidKey) end
    for j = 1, #text do
      if not is_bare_key_char(text:byte(j)) then self:fail(MESSAGES.InvalidKey) end
    end
    return text
  end
  self:fail(MESSAGES.UnexpectedToken)
end

function P:parse_inline_entry(map)
  local segs = {}
  while true do
    local t = self:peek()
    local key = self:decode_inline_key(t)
    self:advance()
    segs[#segs + 1] = { str = key, span = { t.s, t.e } }
    self:skip_flow_ws()
    if self:peek().kind ~= "dot" then break end
    self:advance()
    self:skip_flow_ws()
  end
  if self:peek().kind ~= "equals" then self:fail(MESSAGES.UnexpectedToken) end
  self:advance()
  self:skip_flow_ws()
  local cur = self:navigate_dotted_path(map, segs, #segs - 1)
  local final = segs[#segs]
  if self:lookup_child(cur, final.str) then self:fail_at(final.span[1], MESSAGES.DuplicateKey) end
  local value = self:parse_value()
  self:append_key_value(cur, final, value)
end

function P:parse_inline_table()
  local start = self:peek().s
  self:advance()
  local map = fig.mapping({ start, start + 1 }, { duplicates = "keep" })
  self.meta[map] = { inline_table = true }
  self:skip_flow_ws()
  if self:peek().kind ~= "close_brace" then
    while true do
      self:parse_inline_entry(map)
      self:skip_flow_ws()
      local k = self:peek().kind
      if k == "comma" then
        self:advance()
        self:skip_flow_ws()
        if self:peek().kind == "close_brace" then
          if not self.v11 then self:fail(MESSAGES.UnexpectedToken) end
          break
        end
      elseif k == "close_brace" then
        break
      else
        self:fail(MESSAGES.UnexpectedToken)
      end
    end
  end
  if self:peek().kind ~= "close_brace" then self:fail(MESSAGES.UnexpectedToken) end
  map.span = { start, self:peek().e }
  self:advance()
  return map
end

-- ── the document ──

function M.parse(dialect, input)
  local v11 = true
  local tokens = tokenize(input, v11)
  local p = new_parser(input, tokens, v11)
  local root = fig.mapping({ 0, #input }, { duplicates = "keep" })
  p.root = root
  p.current = root
  p:skip_blank()
  while p:peek().kind ~= "end_of_file" do
    local k = p:peek().kind
    if k == "key" then
      p:parse_key_value()
    elseif k == "open_bracket" then
      p:parse_table_header()
    elseif k == "double_open_bracket" then
      p:parse_array_table()
    else
      p:fail(MESSAGES.UnexpectedToken)
    end
    p:require_line_end()
    p:skip_blank()
  end
  -- Comments left at the end of the file dangle off the table the last
  -- header opened.
  p:claim_dangling(p.current)
  return root
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout, rule for rule: the root's scalar and
-- array entries as `key = value` lines; a mapping inline when the whole
-- line fits the width and nothing in it carries a comment, else a
-- `[section]`; a non-empty sequence of mappings always `[[array.of.tables]]`;
-- an array wider than the budget wrapped one element per line. TOML puts
-- a table's sections after its lines, so a table child that sits before a
-- later inline sibling is *demoted* to dotted keys (an inline array, for
-- an array of tables) to keep its place — unless it carries comments,
-- which outrank order and keep the section form.

local function is_bare_key(name)
  return name ~= "" and name:match("^[A-Za-z0-9_%-]+$") ~= nil
end

local function basic_string(s)
  return '"' .. s:gsub('[%c"\\\127]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == "\\" then return "\\\\" end
    if ch == "\b" then return "\\b" end
    if ch == "\t" then return "\\t" end
    if ch == "\n" then return "\\n" end
    if ch == "\f" then return "\\f" end
    if ch == "\r" then return "\\r" end
    return string.format("\\u%04X", ch:byte())
  end) .. '"'
end

local function key_text(row)
  if row.kind ~= "string" then error("a TOML key must be a string", 0) end
  return row.text or ""
end

local function spell_key(name)
  return is_bare_key(name) and name or basic_string(name)
end

local function spell_path(path)
  local parts = {}
  for _, seg in ipairs(path) do parts[#parts + 1] = spell_key(seg) end
  return table.concat(parts, ".")
end

local function toml_special(text)
  if text:sub(-3) == "NaN" then
    local f = text:sub(1, 1)
    return f == "-" and "-nan" or f == "+" and "+nan" or "nan"
  end
  local f = text:sub(1, 1)
  return f == "-" and "-inf" or f == "+" and "+inf" or "inf"
end

local inline

local function inline_array(row)
  if #row.items == 0 then return "[]" end
  local parts = {}
  for _, item in ipairs(row.items) do parts[#parts + 1] = inline(item) end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function inline_table(row)
  if #row.items == 0 then return "{}" end
  local parts = {}
  for _, e in ipairs(row.items) do parts[#parts + 1] = spell_key(key_text(e.key)) .. " = " .. inline(e.value) end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

inline = function(row)
  local k = row.kind
  if k == "null" then error("TOML has no null; a null value cannot be written", 0) end
  if k == "bool" or k == "int" or k == "float" then return row.text end
  if k == "string" then
    local ext = row.ext_kind
    if ext == nil then return basic_string(row.text or "") end
    if ext == "offset_datetime" or ext == "local_datetime" or ext == "local_date" or ext == "local_time" then return row.text end
    if ext == "char_literal" then return row.text end
    if ext == "number_special" then return toml_special(row.text) end
    return basic_string(row.text or "")
  end
  if k == "sequence" then return inline_array(row) end
  if k == "mapping" then return inline_table(row) end
  if k == "alias" then error("an alias must be resolved before it is written as TOML", 0) end
  error("a " .. k .. " is not a value", 0)
end

local function has_comments(row)
  return #row.leading > 0 or #row.trailing > 0 or #row.dangling > 0
end

local function subtree_has_comments(row)
  if has_comments(row) then return true end
  if row.kind == "sequence" then
    for _, item in ipairs(row.items) do
      if subtree_has_comments(item) then return true end
    end
  elseif row.kind == "mapping" then
    for _, e in ipairs(row.items) do
      if has_comments(e) or subtree_has_comments(e.key) or subtree_has_comments(e.value) then return true end
    end
  end
  return false
end

local function all_mappings(row)
  if #row.items == 0 then return false end
  for _, item in ipairs(row.items) do
    if item.kind ~= "mapping" then return false end
  end
  return true
end

local function fits_inline(ctx, e)
  if e.value.kind == "mapping" and #e.value.items == 0 then return false end
  if has_comments(e) or subtree_has_comments(e.key) or subtree_has_comments(e.value) then return false end
  return #spell_key(key_text(e.key)) + 3 + #inline(e.value) <= ctx.width
end

local function classify(ctx, e)
  local v = e.value
  if v.kind == "mapping" then return fits_inline(ctx, e) and "inline" or "section" end
  if v.kind == "sequence" then return all_mappings(v) and "aot" or "inline" end
  return "inline"
end

local function demotable(e)
  return not (has_comments(e) or subtree_has_comments(e.key) or subtree_has_comments(e.value))
end

local function hash_lines(w, list)
  for _, c in ipairs(list) do
    for line in (c.text .. "\n"):gmatch("(.-)\n") do
      local t = line:match("^[ \t]*(.-)[ \t]*$")
      w:put(t == "" and "#" or ("# " .. t), "\n")
    end
  end
end

local function write_value(ctx, w, value, col)
  if value.kind == "sequence" and ctx.pretty and #value.items > 0 then
    local text = inline(value)
    if col + #text > ctx.width then
      w:put("[\n")
      for _, item in ipairs(value.items) do w:put(ctx.unit, inline(item), ",\n") end
      w:put("]")
      return
    end
    w:put(text)
    return
  end
  w:put(inline(value))
end

local function kv_line(ctx, w, e)
  hash_lines(w, e.key.leading)
  local key = spell_key(key_text(e.key))
  w:put(key, " = ")
  write_value(ctx, w, e.value, #key + 3)
  local t = e.value.trailing[1]
  if t then
    w:put(" #")
    if t.text ~= "" then w:put(" ", (t.text:gsub("\n", " "))) end
  end
  w:put("\n")
  ctx.wrote = true
end

local body

local function dotted_body(ctx, w, prefix, map)
  for _, e in ipairs(map.items) do
    local path = { table.unpack(prefix) }
    path[#path + 1] = key_text(e.key)
    if e.value.kind == "mapping" and #e.value.items > 0 then
      dotted_body(ctx, w, path, e.value)
    else
      local spelled = spell_path(path)
      w:put(spelled, " = ")
      write_value(ctx, w, e.value, #spelled + 3)
      w:put("\n")
      ctx.wrote = true
    end
  end
end

local function needs_header(ctx, map)
  if #map.items == 0 then return true end
  for _, e in ipairs(map.items) do
    if classify(ctx, e) == "inline" then return true end
  end
  return false
end

local function section(ctx, w, e, parent)
  local path = { table.unpack(parent) }
  path[#path + 1] = key_text(e.key)
  if needs_header(ctx, e.value) then
    if ctx.wrote then w:put("\n") end
    hash_lines(w, e.key.leading)
    w:put("[", spell_path(path), "]\n")
    ctx.wrote = true
  end
  body(ctx, w, e.value, path)
end

local function aot(ctx, w, e, parent)
  local path = { table.unpack(parent) }
  path[#path + 1] = key_text(e.key)
  for _, elem in ipairs(e.value.items) do
    if ctx.wrote then w:put("\n") end
    w:put("[[", spell_path(path), "]]\n")
    ctx.wrote = true
    body(ctx, w, elem, path)
  end
end

body = function(ctx, w, map, path)
  local last_inline = nil
  for i, e in ipairs(map.items) do
    if classify(ctx, e) == "inline" then last_inline = i end
  end
  -- Pass 1: the lines, in document order, up to the last inline child.
  if last_inline then
    for i = 1, last_inline do
      local e = map.items[i]
      local class = classify(ctx, e)
      if class == "inline" then
        kv_line(ctx, w, e)
      elseif class == "section" then
        if demotable(e) then dotted_body(ctx, w, { key_text(e.key) }, e.value) end
      elseif demotable(e) then
        kv_line(ctx, w, e)
      end
    end
  end
  hash_lines(w, map.dangling)
  if #map.dangling > 0 then ctx.wrote = true end
  -- Pass 2: the sections, after the lines; a commented one that could not
  -- demote comes here from the middle.
  for i, e in ipairs(map.items) do
    local demoted = last_inline ~= nil and i <= last_inline and demotable(e)
    local class = classify(ctx, e)
    if class == "section" then
      if not demoted then section(ctx, w, e, path) end
    elseif class == "aot" then
      if not demoted then aot(ctx, w, e, path) end
    end
  end
end

function M.print(_dialect, t, options)
  options = options or {}
  local w = fig.writer(options)
  local ctx = { width = options.width or 80, pretty = options.pretty ~= false, unit = string.rep(" ", options.indent or 2), wrote = false }
  local root = t.byid(0)
  if root.kind == "mapping" then
    body(ctx, w, root, {})
  else
    -- A non-table root has no TOML document form; the inline value is a
    -- best-effort fragment.
    w:put(inline(root), "\n")
  end
  return w:string()
end

return M
