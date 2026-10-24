-- TOML, in Lua: a twin of fig's compiled `toml` format — TOML 1.1, the
-- default dialect.
--
-- What is held to the compiled format is the *table*, not the parser's
-- shape. `cargo test --test twins toml` parses every fixture under
-- `tests/fixtures/toml/` through this script and compares the node table
-- it builds — every row, kind, `ext_kind`, text, span, comment, region and
-- mention — against the `*.table.json` beside it, which is what `fig lang
-- table -i toml` printed; it then prints those tables back and requires
-- this printer's bytes to be the compiled printer's, and edits both the
-- same way. The grammar module's rules would not do: TOML is a section
-- format, and which line may open or extend which table is stated here by
-- hand. What every section format shares — the region a header line is,
-- the mention a name is, the comments waiting for a key — is the grammar
-- module's `sections`, and comes from there.
--
-- The shape of the table:
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
-- The refusals are the format's, worded here: every document the compiled
-- format refuses this script refuses too, with a message of its own and an
-- offset that points at the problem rather than at the compiled parser's
-- caret.

local DT = require("fig.datetime")
local G = require("fig.grammar")
local N = require("fig.number")

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
  comments = { line = { open = "#" }, trailing = { open = "#" } },
  kv_sep = " = ",
  flow_map_pad = " ",
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

-- ── refusals ──────────────────────────────────────────────────────────────
-- The wordings more than one rule reaches for; the rest are written where
-- they are raised.

local UNEXPECTED = "unexpected token here; check for a missing `=`, `.`, `,`, or a closing `]`/`}`"
local DUPLICATE = "this key or table conflicts with one already defined; a TOML key or table may be defined only once"
local UNCLOSED = "unclosed string; close the quote, or use a triple-quoted string (`\"\"\"`/`'''`) for text over several lines"
local BAD_ESCAPE = "invalid escape; a basic string takes \\b \\t \\n \\f \\r \\e \\\" \\\\ \\xXX \\uXXXX \\UXXXXXXXX — use a literal string ('...') for raw text"
local BAD_UNICODE = "invalid unicode escape; those hex digits are not a Unicode codepoint"
local BAD_KEY = "invalid key; a bare key allows only letters, digits, `-` and `_` — quote it for anything else"
local CONTROL = "a control character is not allowed here; only tab is, outside a multi-line string"

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- Line-oriented and context-sensitive: the same bytes are a bare key
-- before `=` and a date after it, so a per-line key/value position is
-- tracked, and a stack of open `[`/`{` says whether an inline table is at
-- a key or a value.

local BARE_KEY = "^[A-Za-z0-9_%-]+$"
local CONTROL_CHAR = "[\0-\8\11\12\14-\31\127]"

local function is_bare_key_char(c)
  return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45
end

local function is_value_terminator(c)
  return c == 32 or c == 9 or c == 10 or c == 13 or c == 35 or c == 44 or c == 93 or c == 125 or c == 61
end

local Tok = {}
Tok.__index = Tok

local function tokenize(src)
  return setmetatable({ src = src, n = #src, i = 0, tokens = {}, in_value = false, flow = {} }, Tok):run()
end

function Tok:byte(k) return self.src:byte(self.i + 1 + (k or 0)) end

function Tok:emit(kind, s, e)
  self.tokens[#self.tokens + 1] = { kind = kind, s = s, e = e }
end

--- Emit a one-byte token and step past it.
function Tok:one(kind)
  self:emit(kind, self.i, self.i + 1)
  self.i = self.i + 1
end

--- How far `pattern` reaches from `at`, or nil.
function Tok:match_at(pattern, at)
  local _, e = self.src:find("^" .. pattern, at + 1)
  return e
end

function Tok:run()
  if self.src:sub(1, 3) == "\239\187\191" then self.i = 3 end
  while self.i < self.n do
    local c = self:byte()
    if c == 10 or (c == 13 and self:byte(1) == 10) then
      local e = self.i + (c == 10 and 1 or 2)
      self:emit("newline", self.i, e)
      self.i = e
      if #self.flow == 0 then self.in_value = false end
    elseif c == 13 then
      fig.fail("a bare `\\r` must be followed by `\\n`; TOML line endings are `\\n` or `\\r\\n`", self.i)
    elseif c == 32 or c == 9 then
      local s = self.i
      self.i = self:match_at("[ \t]+", s)
      self:emit("whitespace", s, self.i)
    elseif c == 35 then
      local s = self.i
      self.i = self:match_at("[^\n\r]*", s)
      local bad = self.src:sub(s + 1, self.i):find(CONTROL_CHAR)
      if bad then fig.fail(CONTROL, s + bad - 1) end
      self:emit("comment", s, self.i)
    elseif self.in_value or #self.flow > 0 then
      self:lex_value()
    else
      self:lex_key()
    end
  end
  self:emit("end_of_file", self.n, self.n)
  return self.tokens
end

function Tok:lex_key()
  local c = self:byte()
  if c == 91 or c == 93 then
    -- `[[`/`]]` are an array of tables' header, `[`/`]` a table's.
    local kind = c == 91 and "open_bracket" or "close_bracket"
    local width = self:byte(1) == c and 2 or 1
    self:emit(width == 2 and "double_" .. kind or kind, self.i, self.i + width)
    self.i = self.i + width
  elseif c == 61 then
    self:one("equals")
    self.in_value = true
  elseif c == 46 then
    self:one("dot")
  elseif c == 34 or c == 39 then
    local s = self.i
    self:scan_string(c, false)
    self:emit("key", s, self.i)
  else
    self:lex_bare_key()
  end
end

function Tok:lex_bare_key()
  local s = self.i
  while self.i < self.n and is_bare_key_char(self:byte()) do self.i = self.i + 1 end
  if self.i == s then fig.fail(BAD_KEY, self.i) end
  self:emit("key", s, self.i)
end

function Tok:lex_value()
  local c = self:byte()
  local top = self.flow[#self.flow]
  if c == 91 then
    self:one("open_bracket")
    self.flow[#self.flow + 1] = { table = false }
  elseif c == 123 then
    self:one("open_brace")
    self.flow[#self.flow + 1] = { table = true, expect_key = true }
  elseif c == 93 or c == 125 then
    self.flow[#self.flow] = nil
    self:one(c == 93 and "close_bracket" or "close_brace")
  elseif c == 44 then
    self:one("comma")
    if top and top.table then top.expect_key = true end
  elseif c == 61 then
    self:one("equals")
    if top and top.table then top.expect_key = false end
  elseif c == 46 then
    self:one("dot")
  elseif c == 34 or c == 39 then
    -- A quoted key in an inline table's key position, else a string
    -- value; both lex the same and the parser reads them by position.
    local s = self.i
    self:scan_string(c, self:byte(1) == c and self:byte(2) == c)
    self:emit("string", s, self.i)
  elseif top and top.table and top.expect_key then
    self:lex_bare_key()
  else
    local e = self:match_datetime(self.i)
    if e then
      self:emit("datetime", self.i, e)
      self.i = e
      return
    end
    local s = self.i
    while self.i < self.n and not is_value_terminator(self:byte()) do self.i = self.i + 1 end
    if self.i == s then
      fig.fail("not a recognized value; a TOML value is a string, number, boolean, datetime, array or inline table", self.i)
    end
    local word = self.src:sub(s + 1, self.i)
    self:emit((word == "true" or word == "false") and "boolean" or "number", s, self.i)
  end
end

-- The four string forms are one scan: `multiline` says whether the
-- delimiter is three quotes, which lets newlines in and lets up to two
-- more quotes hug the close.
function Tok:scan_string(q, multiline)
  self.i = self.i + (multiline and 3 or 1)
  local basic = q == 34
  while self.i < self.n do
    local c = self:byte()
    if c == 10 or c == 13 then
      if not multiline then fig.fail(UNCLOSED, self.i) end
      if c == 13 and self:byte(1) ~= 10 then fig.fail(CONTROL, self.i) end
    elseif (c < 32 and c ~= 9) or c == 127 then
      fig.fail(CONTROL, self.i)
    end
    if basic and c == 92 then
      self.i = self.i + 2
    elseif c == q and (not multiline or (self:byte(1) == q and self:byte(2) == q)) then
      self.i = self.i + (multiline and 3 or 1)
      local extra = 0
      while multiline and extra < 2 and self:byte() == q do
        self.i = self.i + 1
        extra = extra + 1
      end
      return
    else
      self.i = self.i + 1
    end
  end
  fig.fail(UNCLOSED, self.i)
end

-- A datetime's outline, as far as it reaches from `at`, or nil; whether
-- it spells a real instant is `DT.classify`'s to say.
function Tok:match_time(at)
  local hm = self:match_at("%d%d:%d%d", at)
  if not hm then return nil end
  local sec = self:match_at(":%d%d", hm)
  if not sec then return hm end
  return self:match_at("%.%d+", sec) or sec
end

function Tok:match_datetime(at)
  local date = self:match_at("%d%d%d%d%-%d%d%-%d%d", at)
  if not date then return self:match_time(at) end
  local sep = self:match_at("[Tt ]", date)
  if not sep then return date end
  local time = self:match_time(sep)
  if not time then return date end
  return self:match_at("[Zz]", time) or self:match_at("[%+%-]%d%d:%d%d", time) or time
end

-- ── scalars ───────────────────────────────────────────────────────────────

local SPECIALS = { inf = true, ["+inf"] = true, ["-inf"] = true, nan = true, ["+nan"] = true, ["-nan"] = true }

-- The digits of each radix prefix, as a character class.
local RADIX = { ["0x"] = "%x", ["0o"] = "[0-7]", ["0b"] = "[01]" }

-- `s` with its underscores removed, or nil unless every one sits between
-- two characters of `class` — TOML's digit grouping.
local function ungroup(s, class)
  for i = 1, #s do
    if s:sub(i, i) == "_" and not (s:sub(i - 1, i - 1):match(class) and s:sub(i + 1, i + 1):match(class)) then
      return nil
    end
  end
  return (s:gsub("_", ""))
end

-- "int", "float", or nil for not a number at all.
local function classify_number(raw)
  if SPECIALS[raw] then return "float" end
  local class = RADIX[raw:sub(1, 2)]
  if class then
    local digits = ungroup(raw:sub(3), class)
    if digits and digits:match("^" .. class .. "+$") then return "int" end
    return nil
  end
  local body = ungroup((raw:gsub("^[%+%-]", "")), "%d")
  if not body or body:match("^0%d") then return nil end
  if body:match("^%d+$") then return "int" end
  if body:match("^%d+%.%d+$") or body:match("^%d+[eE][%+%-]?%d+$") or body:match("^%d+%.%d+[eE][%+%-]?%d+$") then
    return "float"
  end
  return nil
end

-- An integer's text is its value in decimal: radix converted, underscores
-- and a leading `+` gone, `-0` just `0`. Beyond i64 there is no value, and
-- the document is refused — which is where `tonumber` stops giving an
-- integer.
local function canonical_int(raw)
  local v = math.tointeger(tonumber(N.canonical(raw)))
  if v == nil then return nil end
  return string.format("%d", v)
end

-- A float keeps its lexeme; only the grouping and the spelling of the
-- specials are normalized.
local function canonical_float(raw)
  if raw == "inf" or raw == "+inf" then return "inf" end
  if raw == "-inf" then return "-inf" end
  if raw == "nan" or raw == "+nan" or raw == "-nan" then return "nan" end
  return (raw:gsub("_", ""))
end

-- ── string decoding ───────────────────────────────────────────────────────

local function trim_leading_newline(inner)
  if inner:sub(1, 1) == "\n" then return inner:sub(2) end
  if inner:sub(1, 2) == "\r\n" then return inner:sub(3) end
  return inner
end

local SIMPLE = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", e = "\27", ['"'] = '"', ["\\"] = "\\" }

-- ── the parser ────────────────────────────────────────────────────────────
-- A token cursor — `peek`, `advance`, `at`, `take`, `text` and `fail` come
-- from `fig.cursor` — with TOML's table rules written over it.

local P = setmetatable({}, { __index = getmetatable(fig.cursor({}, nil)) })
P.__index = P

local function new_parser(tokens, sc)
  local p = fig.cursor(tokens, sc)
  p.sections = G.sections(sc.src) -- regions, mentions, comments waiting for a key
  p.last_value = nil -- the node a same-line comment trails
  p.meta = {} -- per table: explicit / dotted / implicit / aot / inline_table
  return setmetatable(p, P)
end

-- ── strings ──

function P:decode_basic(inner, multiline, t)
  local out = {}
  local i = 1
  local n = #inner
  while i <= n do
    local c = inner:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      local e = inner:sub(i + 1, i + 1)
      if SIMPLE[e] then
        out[#out + 1] = SIMPLE[e]
        i = i + 2
      elseif e == "u" or e == "U" or e == "x" then
        local width = e == "u" and 4 or e == "U" and 8 or 2
        local hex = inner:sub(i + 2, i + 1 + width)
        if #hex < width or not hex:match("^%x+$") then self:fail(BAD_UNICODE, t) end
        local cp = tonumber(hex, 16)
        if cp > 0x10FFFF or fig.is_surrogate(cp) then self:fail(BAD_UNICODE, t) end
        out[#out + 1] = utf8.char(cp)
        i = i + 2 + width
      elseif e == " " or e == "\t" or e == "\n" or e == "\r" then
        -- A line-ending backslash: whitespace, then a newline, then every
        -- blank up to the next content, all trimmed.
        if not multiline then self:fail(BAD_ESCAPE, t) end
        local j = i + 1
        while j <= n and (inner:sub(j, j) == " " or inner:sub(j, j) == "\t") do j = j + 1 end
        if j > n or (inner:sub(j, j) ~= "\n" and inner:sub(j, j) ~= "\r") then self:fail(BAD_ESCAPE, t) end
        while j <= n and inner:sub(j, j):match("[ \t\r\n]") do j = j + 1 end
        i = j
      else
        self:fail(BAD_ESCAPE, t)
      end
    end
  end
  return table.concat(out)
end

-- Any of the four string forms to its value.
function P:decode_string(t)
  local raw = self:text(t)
  if #raw < 2 then self:fail(UNCLOSED, t) end
  local q = raw:sub(1, 1)
  local triple = #raw >= 6 and raw:sub(2, 2) == q and raw:sub(3, 3) == q
  local inner = triple and trim_leading_newline(raw:sub(4, -4)) or raw:sub(2, -2)
  if q == "'" or not inner:find("\\", 1, true) then return inner end
  return self:decode_basic(inner, triple, t)
end

-- ── comments and trivia ──

function P:capture_comment(t)
  local raw = self:text(t)
  local text = fig.trim_comment(raw:sub(1, 1) == "#" and raw:sub(2) or raw)
  if self.last_value then
    self.last_value:comment("trailing", text)
    self.last_value = nil
  else
    self.sections:comment(text)
  end
end

-- Whitespace and comments, and blank lines too when `newlines`. A comment
-- before a newline is on the line just parsed, so it can trail that line's
-- value; past one it waits and leads the next key.
function P:skip(newlines)
  while true do
    local k = self:peek().kind
    if k == "comment" then
      self:capture_comment(self:peek())
    elseif k == "newline" and newlines then
      self.last_value = nil
    elseif k ~= "whitespace" then
      return
    end
    self.pos = self.pos + 1
  end
end

function P:skip_inline() self:skip(false) end

function P:skip_blank() self:skip(true) end

function P:require_line_end()
  self:skip_inline()
  if not self:at("newline") and not self:at("end_of_file") then
    self:fail("unexpected content after this line's value; a TOML statement ends its line, and a `#` comment wants whitespace before it")
  end
end

-- ── keys ──

function P:decode_key(t)
  local raw = self:text(t)
  if raw == "" then self:fail(BAD_KEY, t) end
  local c = raw:sub(1, 1)
  if c == '"' or c == "'" then return self:decode_string(t) end
  return raw
end

-- `a.b.c`: the cursor at the first key.
function P:parse_key_path()
  local segs = {}
  while true do
    local t = self:peek()
    if t.kind ~= "key" then self:fail(UNEXPECTED) end
    self:advance()
    segs[#segs + 1] = { str = self:decode_key(t), span = { t.s, t.e } }
    self:skip_inline()
    if not self:take("dot") then return segs end
    self:skip_inline()
  end
end

function P:lookup_child(map, key)
  local e = map.by_key[key]
  return e and e.value or nil
end

function P:key_of(seg)
  local key = fig.scalar("string", seg.span, seg.str)
  self.sections:claim(key, "leading")
  return key
end

function P:append_key_value(map, seg, value)
  return map:put(fig.entry(self:key_of(seg), value, { seg.span[1], value.span[2] }))
end

-- A table `seg` names, opened under `parent`: its header line the first
-- region, its name the first mention, of `kind`.
function P:create_table(parent, seg, meta, kind)
  local m = fig.mapping(seg.span, { duplicates = "keep" })
  self.sections:open(parent, fig.entry(self:key_of(seg), m), kind)
  self.meta[m] = meta
  return m
end

function P:append_array_element(seq)
  return seq:add(fig.mapping(seq.span, { duplicates = "keep" }))
end

-- An existing path node to continue from: a table itself, an array of
-- tables its last element; anything else is a conflict.
function P:descend(child, seg)
  local meta = self.meta[child] or {}
  if child.kind == "mapping" and not meta.inline_table then return child end
  if child.kind == "sequence" and meta.aot and #child.items > 0 then return child.items[#child.items] end
  fig.fail(DUPLICATE, seg.span[1])
end

function P:navigate_header_path(start, segs, count)
  local cur = start
  for j = 1, count do
    local seg = segs[j]
    local child = self:lookup_child(cur, seg.str)
    if child then
      -- Passed through, not reopened: a mention and no region.
      self.sections:mention(child, seg.span, "header")
      cur = self:descend(child, seg)
    else
      cur = self:create_table(cur, seg, { implicit = true }, "header")
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
      local meta = self.meta[child] or {}
      if child.kind ~= "mapping" or meta.explicit or meta.inline_table then fig.fail(DUPLICATE, seg.span[1]) end
      self.sections:reopen(child, seg.span, "entry")
      cur = child
    else
      cur = self:create_table(cur, seg, { dotted = true }, "entry")
    end
  end
  return cur
end

-- ── statements ──

-- `[a.b]`, and `[[a.b]]` when `array`: every segment but the last is
-- navigated from the root, and the last is the table the line opens or
-- reopens and the one the lines below it fill.
function P:parse_header(array)
  self:advance()
  self:skip_inline()
  local segs = self:parse_key_path()
  self:skip_inline()
  if not self:take(array and "double_close_bracket" or "close_bracket") then self:fail(UNEXPECTED) end
  local cur = self:navigate_header_path(self.root, segs, #segs - 1)
  local final = segs[#segs]
  local child = self:lookup_child(cur, final.str)
  local meta = child and self.meta[child] or {}
  if not array then
    if not child then
      self.current = self:create_table(cur, final, { explicit = true }, "header")
      return
    end
    if child.kind ~= "mapping" or meta.explicit or meta.dotted or meta.inline_table then
      fig.fail(DUPLICATE, final.span[1])
    end
    self.meta[child] = { explicit = true }
    self.sections:reopen(child, final.span, "header")
    self.current = child
    return
  end
  local seq = child
  if not seq then
    seq = fig.sequence(final.span)
    self.sections:open(cur, fig.entry(self:key_of(final), seq), "header")
    self.meta[seq] = { aot = true }
  else
    if seq.kind ~= "sequence" or not meta.aot then fig.fail(DUPLICATE, final.span[1]) end
    self.sections:reopen(seq, final.span, "header")
  end
  self.current = self:append_array_element(seq)
  -- The element shares the array's span, so its `[[…]]` line is recorded
  -- on the element too: the only way its header is findable.
  self.sections:region(self.current, final.span[1])
end

function P:parse_key_value()
  local segs = self:parse_key_path()
  self:skip_inline()
  if not self:take("equals") then self:fail(UNEXPECTED) end
  self:skip_inline()
  local cur = self:navigate_dotted_path(self.current, segs, #segs - 1)
  local final = segs[#segs]
  if self:lookup_child(cur, final.str) then fig.fail(DUPLICATE, final.span[1]) end
  local value = self:parse_value()
  self.last_value = value
  self:append_key_value(cur, final, value)
end

-- ── values ──

function P:parse_value()
  local t = self:peek()
  local k = t.kind
  if k == "open_bracket" then return self:parse_array() end
  if k == "open_brace" then return self:parse_inline_table() end
  self:advance()
  local span = { t.s, t.e }
  if k == "string" then return fig.scalar("string", span, self:decode_string(t)) end
  if k == "boolean" then return fig.scalar("bool", span, self:text(t)) end
  local raw = self:text(t)
  if k == "datetime" then
    local shape = DT.classify(raw, { minute_precision = true })
    if not shape then self:fail("not a valid RFC 3339 date or time", t) end
    return fig.scalar("string", span, raw, { ext_kind = shape })
  end
  if k == "number" then
    local kind = classify_number(raw)
    if not kind then
      self:fail("not a TOML value; TOML has no bare strings, so quote text — and a number takes one `_` between digits, no leading zero, and `0x`/`0o`/`0b` for another radix", t)
    end
    local text = kind == "int" and canonical_int(raw) or canonical_float(raw)
    if not text then self:fail("this integer is too large for the 64 bits TOML gives it", t) end
    return fig.scalar(kind, span, text)
  end
  self:fail(UNEXPECTED, t)
end

function P:parse_array()
  local start = self:peek().s
  self:advance()
  local seq = fig.sequence({ start, start + 1 })
  while true do
    self:skip_blank()
    if self:at("close_bracket") then break end
    seq:add(self:parse_value())
    self:skip_blank()
    if self:at("close_bracket") then break end
    if not self:take("comma") then self:fail(UNEXPECTED) end
  end
  seq.span = { start, self:peek().e }
  self:advance()
  return seq
end

function P:decode_inline_key(t)
  local k = t.kind
  if k == "string" then return self:decode_string(t) end
  if k == "key" then return self:text(t) end
  -- A number, a boolean or a date in key position is a bare key when its
  -- bytes spell one: `1 = true`, `2024 = "y"`.
  if k == "number" or k == "boolean" or k == "datetime" then
    local text = self:text(t)
    if not text:match(BARE_KEY) then self:fail(BAD_KEY, t) end
    return text
  end
  self:fail(UNEXPECTED, t)
end

function P:parse_inline_entry(map)
  local segs = {}
  while true do
    local t = self:peek()
    segs[#segs + 1] = { str = self:decode_inline_key(t), span = { t.s, t.e } }
    self:advance()
    self:skip_blank()
    if not self:take("dot") then break end
    self:skip_blank()
  end
  if not self:take("equals") then self:fail(UNEXPECTED) end
  self:skip_blank()
  local cur = self:navigate_dotted_path(map, segs, #segs - 1)
  local final = segs[#segs]
  if self:lookup_child(cur, final.str) then fig.fail(DUPLICATE, final.span[1]) end
  self:append_key_value(cur, final, self:parse_value())
end

function P:parse_inline_table()
  local start = self:peek().s
  self:advance()
  local map = fig.mapping({ start, start + 1 }, { duplicates = "keep" })
  self.meta[map] = { inline_table = true }
  self:skip_blank()
  while not self:at("close_brace") do
    self:parse_inline_entry(map)
    self:skip_blank()
    if self:at("close_brace") then break end
    -- TOML 1.1 lets a newline and a trailing comma into an inline table.
    if not self:take("comma") then self:fail(UNEXPECTED) end
    self:skip_blank()
  end
  if not self:at("close_brace") then self:fail(UNEXPECTED) end
  map.span = { start, self:peek().e }
  self:advance()
  return map
end

-- ── the document ──

function M.parse(_dialect, input)
  local sc = fig.scanner(input)
  local p = new_parser(tokenize(input), sc)
  local root = fig.mapping({ 0, #input }, { duplicates = "keep" })
  p.root = root
  p.current = root
  p:skip_blank()
  while not p:at("end_of_file") do
    local k = p:peek().kind
    if k == "key" then
      p:parse_key_value()
    elseif k == "open_bracket" then
      p:parse_header(false)
    elseif k == "double_open_bracket" then
      p:parse_header(true)
    else
      p:fail(UNEXPECTED)
    end
    p:require_line_end()
    p:skip_blank()
  end
  -- Comments left at the end of the file dangle off the table the last
  -- header opened.
  p.sections:claim(p.current, "dangling")
  return root
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The root's scalar and array entries as `key = value` lines; a mapping
-- inline when the whole line fits the width and nothing in it carries a
-- comment, else a `[section]`; a non-empty sequence of mappings always
-- `[[array.of.tables]]`; an array wider than the budget wrapped one element
-- per line. TOML puts a table's sections after its lines, so a table child
-- that sits before a later inline sibling is *demoted* to dotted keys (an
-- inline array, for an array of tables) to keep its place — unless it
-- carries comments, which outrank order and keep the section form. Widths
-- are byte widths.

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
  return name:match(BARE_KEY) and name or basic_string(name)
end

local function spell_path(path)
  local parts = {}
  for _, seg in ipairs(path) do parts[#parts + 1] = spell_key(seg) end
  return table.concat(parts, ".")
end

--- `path` with `name` appended, a copy: a section's path grows per level.
local function extend(path, name)
  local out = { table.unpack(path) }
  out[#out + 1] = name
  return out
end

local function toml_special(text)
  local f = text:sub(1, 1)
  if text:sub(-3) == "NaN" then
    return f == "-" and "-nan" or f == "+" and "+nan" or "nan"
  end
  return f == "-" and "-inf" or f == "+" and "+inf" or "inf"
end

local inline

local function inline_list(items, f)
  local parts = {}
  for _, item in ipairs(items) do parts[#parts + 1] = f(item) end
  return parts
end

inline = function(row)
  local k = row.kind
  if k == "null" then error("TOML has no null; a null value cannot be written", 0) end
  if k == "bool" or k == "int" or k == "float" then return row.text end
  if k == "string" then
    local ext = row.ext_kind
    if ext == nil then return basic_string(row.text or "") end
    if DT.KINDS[ext] or ext == "char_literal" then return row.text end
    if ext == "number_special" then return toml_special(row.text) end
    return basic_string(row.text or "")
  end
  if k == "sequence" then
    if #row.items == 0 then return "[]" end
    return "[" .. table.concat(inline_list(row.items, inline), ", ") .. "]"
  end
  if k == "mapping" then
    if #row.items == 0 then return "{}" end
    local parts = inline_list(row.items, function(e) return spell_key(key_text(e.key)) .. " = " .. inline(e.value) end)
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
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

-- Whether anything about an entry is commented: what keeps a table in its
-- section form rather than letting it demote or go inline.
local function commented(e)
  return has_comments(e) or subtree_has_comments(e.key) or subtree_has_comments(e.value)
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
  if commented(e) then return false end
  return #spell_key(key_text(e.key)) + 3 + #inline(e.value) <= ctx.width
end

local function classify(ctx, e)
  local v = e.value
  if v.kind == "mapping" then return fits_inline(ctx, e) and "inline" or "section" end
  if v.kind == "sequence" then return all_mappings(v) and "aot" or "inline" end
  return "inline"
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
  w:comments(e.key.leading, "#")
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
    local path = extend(prefix, key_text(e.key))
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
  local path = extend(parent, key_text(e.key))
  if needs_header(ctx, e.value) then
    if ctx.wrote then w:put("\n") end
    w:comments(e.key.leading, "#")
    w:put("[", spell_path(path), "]\n")
    ctx.wrote = true
  end
  body(ctx, w, e.value, path)
end

local function aot(ctx, w, e, parent)
  local path = extend(parent, key_text(e.key))
  for _, elem in ipairs(e.value.items) do
    if ctx.wrote then w:put("\n") end
    w:put("[[", spell_path(path), "]]\n")
    ctx.wrote = true
    body(ctx, w, elem, path)
  end
end

body = function(ctx, w, map, path)
  local last_inline = 0
  for i, e in ipairs(map.items) do
    if classify(ctx, e) == "inline" then last_inline = i end
  end
  -- Pass 1: the lines, in document order, up to the last inline child.
  for i = 1, last_inline do
    local e = map.items[i]
    local class = classify(ctx, e)
    if class == "inline" then
      kv_line(ctx, w, e)
    elseif class == "section" then
      if not commented(e) then dotted_body(ctx, w, { key_text(e.key) }, e.value) end
    elseif not commented(e) then
      kv_line(ctx, w, e)
    end
  end
  if w:comments(map.dangling, "#") then ctx.wrote = true end
  -- Pass 2: the sections, after the lines; a commented one that could not
  -- demote comes here from the middle.
  for i, e in ipairs(map.items) do
    local demoted = i <= last_inline and not commented(e)
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

-- A key's name as TOML writes one, for a key the editor inserts or
-- renames: bare when it can be, else a basic string.
M.renderers = { "key_name" }

function M.render(which, args)
  if which == "key_name" then return spell_key(args.key) end
  error("no renderer `" .. which .. "`", 0)
end

return M
