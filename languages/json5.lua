-- JSONC and JSON5, in Lua: the twins of fig's compiled `jsonc` and `json5`
-- dialects — one script, two dialects, as the compiled JSON module is one
-- parser with a dialect switch.
--
-- The contract is the format and the tree, not the compiled parser's
-- shape: this script's node table is held row for row against the compiled
-- dialects' on every fixture under `tests/fixtures/jsonc/` and
-- `tests/fixtures/json5/` — every row, span, text and comment — and every
-- document the compiled dialects refuse this refuses too, in words and at
-- offsets of its own. `fig lang table -i jsonc` / `-i json5` prints the
-- table a document must give.
--
-- The format:
--
--   * JSONC is JSON with `//` and `/* */` comments; JSON5 adds unquoted
--     `identifier` keys (and `true`/`false`/`null` as keys), single-quoted
--     strings, the escapes `\x`, `\v`, `\0`, `\'`, any other `\c` as `c`,
--     a `\` before a line ending as a continuation, trailing commas,
--     `Infinity`/`NaN` (signed too) as `number_special` strings, `0x`
--     integers, `.5`, `5.`, `+1`, and `\v`/`\f` as whitespace;
--   * a container spans its brackets, an entry its key through its value;
--     a number keeps its lexeme and is a float when it has a `.` or an
--     exponent (a `0x` integer never); a duplicate key keeps both entries;
--   * a comment that is the last thing on the line of the value just
--     finished trails it — or dangles on a container whose closing line it
--     is; one on the line a container opens, with nothing else after it,
--     is that container's trailing comment; any other waits and leads the
--     next key, value or container, or dangles on the container that
--     closes with it still waiting; what waits after the document is
--     dropped. A comment's text is trimmed; a block comment's style is
--     `block`.
--
-- That is the grammar module's own binding with `ends_line`, `one` and
-- `closing_line` set, and two things it cannot express: a container claims
-- what waits and what rides its opening line before it exists, which the
-- `opener`/`container` pair below does; and "the last thing on its line"
-- counts a following `,` or closer as nothing, so `[1 /* one */, 2]`
-- trails `1`, which `ends_line` below widens the context's
-- `rest_is_blank` to say.
--
-- Spans are byte offsets, 0-based, `[start, end)`; a container's span
-- includes its brackets and a string's its quotes.

local G = require("fig.grammar")
local N = require("fig.number")

local M = {}

M.name = "lua-json5"
M.caps = { read = true, edit = true, serialize = true }
-- Beyond the core kinds, `null` and nothing else: every extended scalar
-- rides in a `$fig` envelope, JSON5's own `Infinity`/`NaN` included.
M.lossless = { null = true }
M.syntax = {
  comments = { line = { open = "//" }, trailing = { open = "//" } },
  kv_sep = ": ",
  empty_map_literal = "{}",
}
M.dialects = {
  -- The language's own name goes on its first dialect; the compiled
  -- dialects own `.json5` and `.jsonc`, and a compiled format's extension
  -- wins, so these are reached by `--lang lua-json5` / `--lang lua-jsonc`.
  { name = "lua-json5", extensions = { "json5" }, splice = "escaped", empty_doc_seed = "{}\n" },
  { name = "lua-jsonc", extensions = { "jsonc" }, splice = "escaped", empty_doc_seed = "{}\n" },
}
M.samples = {
  '{"a": 1, "b": [true, null, "s"], "c": {"d": 2.5}}\n',
  "// top\n[] // empty\n",
}

-- ── errors ────────────────────────────────────────────────────────────────

local MESSAGES = {
  value = "expected a value here: an object, an array, a string, a number, `true`, `false` or `null`",
  entry = "expected a `key: value` entry or `}` here",
  item = "expected a value or `]` here",
  colon = "expected `:` after this key",
  comma = "expected `,` between elements",
  trailing_comma = "a trailing comma is not allowed here; JSONC follows strict JSON — drop it, or use a .json5 file",
  unclosed_object = "unclosed object; expected `}` before the end of the input",
  unclosed_array = "unclosed array; expected `]` before the end of the input",
  unclosed_string = "unclosed string; add the closing quote, or escape the line ending as `\\n`",
  unclosed_comment = "unclosed block comment; add the closing `*/`",
  control = "a raw control character cannot stand inside a string; escape it (`\\n`, `\\t`, `\\u0000`)",
  leading_zero = "a number cannot have a leading zero; write the digits without the padding, or quote it as a string to keep the padding (e.g. a zip code)",
  digits = "expected the digits of a number here",
  hex_digits = "expected hex digits after `0x`",
  exponent = "expected the digits of the exponent here",
  bad_u = "invalid `\\u` escape; it needs exactly 4 hex digits (e.g. `\\u00e9`)",
  bad_x = "invalid `\\x` escape; it needs exactly 2 hex digits (e.g. `\\x41`)",
  empty = "no document here; expected a value",
  trailing = "unexpected content after the document; a JSON document is one value",
}

local function bad_escape(e)
  return "invalid escape `\\" .. e .. "` in a string; JSON reads `\\\" \\\\ \\/ \\b \\f \\n \\r \\t \\uXXXX`"
end

local function not_a_value(w)
  return "`" .. w .. "` is not a value; quote it to mean the string"
end

-- ── lexical ───────────────────────────────────────────────────────────────

local IDENT = "[%a_$][%w_$]*"
local SIMPLE_ESCAPES = { ['"'] = 34, ["\\"] = 92, ["/"] = 47, b = 8, f = 12, n = 10, r = 13, t = 9 }

local function is_digit(c) return c ~= nil and c >= 48 and c <= 57 end

local comment = G.choice({
  G.comment("//"),
  G.comment({ open = "/*", close = "*/", unclosed = MESSAGES.unclosed_comment }),
})

-- Whether nothing but a `,` or a closer stands between `at` and the end of
-- the line: what these dialects count as the end of a line, so that a
-- comment before a comma still trails what the comma follows.
local function ends_line(sc, at)
  local src = sc.src
  local i = at + 1
  while i <= #src do
    local b = src:byte(i)
    if b ~= 32 and b ~= 9 then
      return b == 10 or b == 13 or b == 44 or b == 93 or b == 125
    end
    i = i + 1
  end
  return true
end

-- ── strings ───────────────────────────────────────────────────────────────

-- The text of a string's inside. Decoded by hand rather than with
-- `G.quoted`, because `\u` is not a fixed replacement: a surrogate pair is
-- one character, and a lone surrogate is no character at all — the string
-- is then kept as written, every escape in it undecoded.
local function decode(sc, inner, json5, at)
  if not inner:find("\\", 1, true) then return inner end
  local function fail(message) sc:fail(message, at) end
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
      i = i + 2
      if SIMPLE_ESCAPES[e] then
        out[#out + 1] = string.char(SIMPLE_ESCAPES[e])
      elseif e == "u" then
        local hex = inner:sub(i, i + 3)
        if not hex:match("^%x%x%x%x$") then fail(MESSAGES.bad_u) end
        local cp = tonumber(hex, 16)
        i = i + 4
        if fig.is_surrogate(cp) then
          local pair = nil
          if inner:sub(i, i + 1) == "\\u" then
            local lo = inner:sub(i + 2, i + 5)
            if not lo:match("^%x%x%x%x$") then fail(MESSAGES.bad_u) end
            pair = fig.surrogate_pair(cp, tonumber(lo, 16))
          end
          if pair == nil then return inner end
          cp = pair
          i = i + 6
        end
        out[#out + 1] = utf8.char(cp)
      elseif not json5 or e == "" then
        fail(bad_escape(e))
      elseif e == "x" then
        local hex = inner:sub(i, i + 1)
        if not hex:match("^%x%x$") then fail(MESSAGES.bad_x) end
        out[#out + 1] = utf8.char(tonumber(hex, 16))
        i = i + 2
      elseif e == "v" then
        out[#out + 1] = "\11"
      elseif e == "0" then
        out[#out + 1] = "\0"
      elseif e == "\n" then
        -- A `\` before a line ending is a continuation: neither is in the text.
      elseif e == "\r" then
        if inner:sub(i, i) == "\n" then i = i + 1 end
      else
        out[#out + 1] = e
      end
    end
  end
  return table.concat(out)
end

-- A string: `"…"`, and in JSON5 `'…'`. A raw control character inside, a
-- line ending among them, is a refusal rather than a byte.
local function string_rule(json5)
  return function(sc)
    local s = sc.pos
    local q = sc:byte()
    if not (q == 34 or (json5 and q == 39)) then return nil end
    local src, n = sc.src, sc.n
    local i = s + 1
    while true do
      if i >= n then sc:fail(MESSAGES.unclosed_string, s) end
      local c = src:byte(i + 1)
      if c == q then
        i = i + 1
        break
      elseif c == 92 then
        if i + 1 >= n then sc:fail(MESSAGES.unclosed_string, s) end
        if src:byte(i + 2) == 13 and src:byte(i + 3) == 10 then i = i + 3 else i = i + 2 end
      elseif c < 32 then
        sc:fail(MESSAGES.control, i)
      else
        i = i + 1
      end
    end
    sc.pos = i
    return fig.scalar("string", { s, i }, decode(sc, sc:slice(s + 1, i - 1), json5, s))
  end
end

-- ── numbers and words ─────────────────────────────────────────────────────

-- The kind a lexeme implies: a float when it has a `.` or an exponent, an
-- int otherwise — a `0x` integer never, whatever its digits look like.
local function number_kind(raw)
  if raw:match("^[+-]?0[xX]") then return "int" end
  return raw:find("[%.eE]") and "float" or "int"
end

-- A number, the lexeme kept verbatim as the row's text: JSON's
-- `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, and for JSON5 an
-- ES5.1 numeric literal — a `+` too, `Infinity` and `NaN` (no number the
-- wire can hold, so they ride as `number_special` strings), a `0x`
-- integer, and either side of the point left out.
local function number_rule(json5)
  return function(sc)
    local s = sc.pos
    local c = sc:byte()
    -- `I` and `N` open `Infinity` and `NaN`; any other word the rule meets
    -- it hands back, for `word` below to judge.
    if not (is_digit(c) or c == 45 or (json5 and (c == 43 or c == 46 or c == 73 or c == 78))) then return nil end
    if c == 45 or c == 43 then
      sc:advance()
      c = sc:byte()
    end
    if json5 then
      local ms, me = sc:match("Infinity")
      if ms == nil then ms, me = sc:match("NaN") end
      if ms ~= nil and sc.src:sub(me + 1, me + 1):match("[%w_$]") == nil then
        return fig.scalar("string", { s, me }, sc:slice(s, me), { ext_kind = "number_special" })
      end
      if not (is_digit(c) or c == 46) then
        sc.pos = s
        return nil
      end
    end
    if json5 and sc:match("0[xX]") then
      if not sc:match("%x+") then sc:fail(MESSAGES.hex_digits) end
    else
      local ds = sc.pos
      local seen = sc:match("%d+") ~= nil
      if seen and sc.src:byte(ds + 1) == 48 and sc.pos > ds + 1 then sc:fail(MESSAGES.leading_zero, ds) end
      if not json5 and not seen then sc:fail(MESSAGES.digits) end
      if sc:byte() == 46 then
        sc:advance()
        local frac = sc:match("%d+") ~= nil
        if not json5 and not frac then sc:fail(MESSAGES.digits) end
        seen = seen or frac
      end
      if not seen then sc:fail(MESSAGES.digits, s) end
      local e = sc:byte()
      if e == 101 or e == 69 then
        sc:advance()
        local sign = sc:byte()
        if sign == 43 or sign == 45 then sc:advance() end
        if not sc:match("%d+") then sc:fail(MESSAGES.exponent) end
      end
    end
    local raw = sc:slice(s, sc.pos)
    return fig.scalar(number_kind(raw), { s, sc.pos }, raw)
  end
end

-- `null`, `true`, `false`, whole words; any other word is a value only
-- once it is quoted. (In JSON5 `Infinity` and `NaN` are numbers, and the
-- number rule has taken them before this one is tried.)
local function word(sc)
  local s, e = sc:match(IDENT)
  if s == nil then return nil end
  local w = sc:slice(s, e)
  if w == "null" then return fig.scalar("null", { s, e }, nil) end
  if w == "true" or w == "false" then return fig.scalar("bool", { s, e }, w) end
  sc:fail(not_a_value(w), s)
end

-- ── the dialect ───────────────────────────────────────────────────────────
-- One set of rules per dialect: the containers are `G.map` and
-- `G.sequence`, with the opener, the separator and the key and value rules
-- doing what this binding asks that the module's defaults do not.

local function build(json5)
  local string_value = string_rule(json5)
  local number = number_rule(json5)
  local trivia = G.trivia({ space = G.pat(json5 and "[ \t\r\n\v\f]+" or "[ \t\r\n]+"), comment = comment })

  local value

  -- A container's opener: the delimiter, and — when nothing before it can
  -- claim it — a comment on its line that ends the line, which the
  -- container takes as its trailing comment once it exists. What was
  -- waiting when it opened is its leading comments. Both ride a stack,
  -- because containers nest, and neither can go through the context: the
  -- node does not exist until the container closes.
  local function opener(delim)
    return function(sc, ctx)
      local s = sc.pos
      if not sc:lit(delim) then return nil end
      local head = { leading = ctx.pending }
      ctx.pending = {}
      local p = sc.pos
      G.hs(sc)
      local at = sc.pos
      local c = comment(sc)
      local claimed = ctx.last ~= nil and sc:same_line(ctx.last.span[2], at)
      if c ~= nil and not claimed and ends_line(sc, c[2]) then head.trailing = c else sc.pos = p end
      ctx.heads[#ctx.heads + 1] = head
      return { s, sc.pos }
    end
  end

  local function container(rule)
    return function(sc, ctx)
      local n = rule(sc, ctx)
      if n == nil then return nil end
      local head = table.remove(ctx.heads)
      for _, c in ipairs(head.leading) do n:comment("leading", c.text, c.style) end
      if head.trailing then n:comment("trailing", head.trailing.text, head.trailing.style) end
      return n
    end
  end

  -- After an element: a `,`, or the close ahead. JSON5 takes a trailing
  -- comma before the close; JSONC refuses one where the next element
  -- should be.
  local function separator(close)
    return function(sc, ctx)
      trivia(sc, ctx)
      if sc:lit(",") then
        if not json5 then
          local at = sc.pos - 1
          trivia(sc, ctx)
          if close(sc) then sc:fail(MESSAGES.trailing_comma, at) end
        end
        return
      end
      local p = sc.pos
      if close(sc) then
        sc.pos = p
        return
      end
      if not sc:eof() then sc:fail(MESSAGES.comma) end
    end
  end

  -- A key claims what is waiting as soon as it is read, so that a comment
  -- between the `:` and the value is the value's and not the key's; a
  -- value claims what is waiting for the same reason.
  local function claims(rule)
    return function(sc, ctx)
      local n = rule(sc, ctx)
      if n ~= nil then ctx:flush(n, "leading") end
      return n
    end
  end

  -- A JSON key is a quoted string; JSON5 takes a bare identifier too, the
  -- keywords among them (`{ true: 1, null: 2 }`).
  local key = claims(json5 and G.choice({ string_value, G.key(G.pat(IDENT)) }) or string_value)

  local mapping = container(G.map({
    open = opener("{"),
    close = G.lit("}"),
    trivia = trivia,
    entry = G.entry({
      key = key,
      between = trivia,
      sep = G.lit(":"),
      value = claims(function(sc, ctx) return value(sc, ctx) end),
      missing_sep = MESSAGES.colon,
      missing_value = MESSAGES.value,
    }),
    after = separator(G.lit("}")),
    duplicates = "keep",
    expected = MESSAGES.entry,
    unclosed = MESSAGES.unclosed_object,
  }))

  local sequence = container(G.sequence({
    open = opener("["),
    close = G.lit("]"),
    trivia = trivia,
    item = function(sc, ctx) return value(sc, ctx) end,
    after = separator(G.lit("]")),
    expected = MESSAGES.item,
    unclosed = MESSAGES.unclosed_array,
  }))

  value = G.choice({ mapping, sequence, string_value, number, word })

  -- The document, by hand rather than `G.document`: what is still waiting
  -- when it ends is dropped, where `document` would dangle it on the root.
  return function(input)
    local sc = fig.scanner(input)
    if input:sub(1, 3) == "\239\187\191" then sc.pos = 3 end
    local ctx = G.context(sc, { ends_line = true, one = true, closing_line = true })
    ctx.rest_is_blank = function(_, at) return ends_line(sc, at) end
    ctx.heads = {}
    trivia(sc, ctx)
    local root = value(sc, ctx)
    if root == nil then sc:fail(sc:eof() and MESSAGES.empty or MESSAGES.value) end
    ctx:flush(root, "leading")
    ctx.last = root
    trivia(sc, ctx)
    if not sc:eof() then sc:fail(MESSAGES.trailing) end
    return fig.rows(root)
  end
end

local DIALECTS = { ["lua-json5"] = build(true), ["lua-jsonc"] = build(false) }

function M.parse(dialect, input)
  return DIALECTS[dialect](input)
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout, as `json.lua` has it — one element per
-- line at `indent` spaces a level when `pretty`, nothing but the tokens
-- otherwise — plus what the dialects add: comments (leading above a
-- member, trailing after its comma, a container's own after its opener,
-- dangling before its close; `pretty` only), and in JSON5 a bare
-- identifier key, `Infinity`/`NaN` as written, and the number spellings
-- JSON5 reads (`0xC8`, `.5`, `+1`). A number no JSON can read is written
-- as decimal, which `fig.number` is the rule for.

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == "\\" then return "\\\\" end
    if ch == "\b" then return "\\b" end
    if ch == "\f" then return "\\f" end
    if ch == "\n" then return "\\n" end
    if ch == "\r" then return "\\r" end
    if ch == "\t" then return "\\t" end
    if ch == "\127" then return ch end
    return string.format("\\u%04x", ch:byte())
  end) .. '"'
end

local function is_bare_identifier(name)
  return name:match("^[%a_$][%w_$]*$") ~= nil
end

local function is_container(row)
  return row.kind == "mapping" or row.kind == "sequence"
end

local Pr = {}
Pr.__index = Pr

function Pr:comments_on() return self.w.pretty end

function Pr:comment_text(c)
  if c.style == "block" then
    return c.text == "" and "/**/" or ("/* " .. c.text .. " */")
  end
  return c.text == "" and "//" or ("// " .. c.text)
end

function Pr:leading(row, depth)
  if not self:comments_on() then return end
  for _, c in ipairs(row.leading) do
    self.w:indent(depth):put(self:comment_text(c), "\n")
  end
end

function Pr:trailing(row)
  if not self:comments_on() then return end
  local c = row.trailing[1]
  if c then self.w:put(" ", self:comment_text(c)) end
end

function Pr:key(row)
  local w = self.w
  local k = row.kind
  if k == "string" then
    if self.json5 and not row.ext_kind and is_bare_identifier(row.text or "") then
      w:put(row.text)
    else
      w:put(quote(row.text or ""))
    end
  elseif k == "null" then
    w:put(quote("null"))
  elseif k == "bool" or k == "int" or k == "float" then
    w:put(quote(row.text or ""))
  elseif k == "alias" then
    error("an alias must be resolved before it is written as JSON", 0)
  else
    error("a JSON key must be a string", 0)
  end
end

function Pr:node(row, depth)
  local w = self.w
  local k = row.kind
  if k == "null" then
    w:put("null")
  elseif k == "bool" then
    w:put(row.text)
  elseif k == "int" or k == "float" then
    if row.ext_kind == "char_literal" then
      w:put(row.text)
    else
      w:put(N.text(row.text or "", self.spelling))
    end
  elseif k == "string" then
    if row.ext_kind == "number_special" and self.json5 then
      w:put(row.text)
    else
      w:put(quote(row.text or ""))
    end
  elseif k == "sequence" or k == "mapping" then
    self:container(row, depth)
  elseif k == "keyvalue" then
    self:key(row.key)
    w:put(w.pretty and ": " or ":")
    self:node(row.value, depth)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as JSON", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function Pr:container(row, depth)
  local w = self.w
  local open, close = "[", "]"
  if row.kind == "mapping" then open, close = "{", "}" end
  local dangling = self:comments_on() and row.dangling or {}
  if #row.items == 0 and #dangling == 0 then
    w:put(open, close)
    self:trailing(row)
    return
  end
  w:put(open)
  self:trailing(row)
  w:nl()
  for i, item in ipairs(row.items) do
    local lead = item.kind == "keyvalue" and item.key or item
    local trail = item.kind == "keyvalue" and item.value or item
    self:leading(lead, depth + 1)
    w:indent(depth + 1)
    self:node(item, depth + 1)
    if i < #row.items then w:put(",") end
    if not is_container(trail) then self:trailing(trail) end
    w:nl()
  end
  for _, c in ipairs(dangling) do
    w:indent(depth + 1):put(self:comment_text(c), "\n")
  end
  w:indent(depth):put(close)
end

function M.print(dialect, t, options)
  local w = fig.writer(options)
  local json5 = dialect == "lua-json5"
  local p = setmetatable({ w = w, json5 = json5, spelling = json5 and N.JSON5 or N.JSON }, Pr)
  local root = t.byid(0)
  p:leading(root, 0)
  p:node(root, 0)
  if not is_container(root) then p:trailing(root) end
  w:put("\n")
  return w:string()
end

-- A key's name as JSON5 and JSONC write one, for a key the editor inserts or
-- renames: quoted and escaped, as the compiled dialects write it, though JSON5
-- could leave an identifier bare.
M.renderers = { "key_name" }

function M.render(which, args)
  if which == "key_name" then return quote(args.key) end
  error("no renderer `" .. which .. "`", 0)
end

return M
