-- JSON, in Lua: the twin of fig's compiled `json` format — the strict
-- dialect, RFC 8259 — row for row.
--
-- `fig lang check lua-json --against json <files…>` holds this script to
-- the compiled parser's node table on every file given, and this script
-- is written against `fig lang table -i json`, which prints that table.
-- What the compiled format accepts is stated in fig's
-- `src/languages/json/`, and this follows it:
--
--   * a document is one value, whitespace (space, tab, `\n`, `\r`) around
--     it, a byte-order mark before it; nothing may follow;
--   * a value is `null`, `true`, `false`, a number, a string, `[...]` or
--     `{...}`; the containers take `,` between elements and no trailing
--     comma; an object's key is a string;
--   * a number is `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` — a
--     leading zero is refused with its own message — and its kind is
--     `float` when it has a fraction or an exponent, `int` otherwise; the
--     lexeme is kept verbatim as the row's text;
--   * a string decodes `\" \\ \/ \b \f \n \r \t` and `\uXXXX`, a surrogate
--     pair as one character; a string with an unpaired surrogate escape
--     is kept as written, every escape in it undecoded; a raw control
--     character inside, a newline among them, is refused;
--   * a repeated key keeps both entries, as the compiled parser does
--     (it warns; a warning has no row).
--
-- Strict JSON has no comments, so the comment table is always empty and
-- `syntax.comments` names no delimiter: the comment ops refuse rather
-- than write a `//` that the dialect could not read back. Spans are byte
-- offsets, 0-based, `[start, end)`; a container's span includes its
-- brackets and a string's its quotes.

local G = require("fig.grammar")

local M = {}

M.name = "lua-json"
M.caps = { read = true, edit = true, serialize = true }
-- JSON holds `null` natively and nothing beyond the core kinds; every
-- extended scalar rides in a `$fig` envelope.
M.lossless = { null = true }
M.syntax = {
  comments = { style = "slashes" },
  kv_sep = ": ",
  key_style = "json_quoted",
  empty_map_literal = "{}",
}
M.dialects = {
  -- The compiled format owns `.json`, and a compiled format's extension
  -- wins, so this is reached by `--lang lua-json`.
  { name = "lua-json", extensions = { "json" }, splice = "json_string", empty_doc_seed = "{}\n" },
}
M.samples = {
  '{"a": 1, "b": [true, null, "s"], "c": {"d": 2.5}}\n',
  "[]\n",
}
M.renderers = {}

-- ── errors, as the compiled parser words them ─────────────────────────────
-- Nearly everything is `UnexpectedToken`: the compiled tokenizer runs
-- first and its refusals are what a document meets, so the parser's more
-- specific messages (a missing colon, an unquoted key) are not reached.

local MESSAGES = {
  UnexpectedToken = "unexpected token here; check for a missing comma, colon, key, or closing bracket/brace",
  UnexpectedEndOfInput = "the document ended before this value/token was complete",
  UnclosedString = "unclosed string; a JSON string cannot span multiple lines — add the closing quote, or escape the newline as `\\n`",
  LeadingZero = "a number cannot have a leading zero; write the digits without the padding, or quote it as a string to keep the padding (e.g. a zip code)",
}

-- ── scalars ───────────────────────────────────────────────────────────────

local SIMPLE_ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- A string. Scanned by hand rather than with `G.quoted`, because a `\u`
-- escape is not a fixed replacement and a raw control character is a
-- refusal, not a byte.
local function string_value(sc)
  local s = sc.pos
  if sc:byte() ~= 34 then return nil end
  local src, n = sc.src, sc.n
  local out = {}
  local raw = false
  local i = s + 1
  while true do
    if i >= n then sc:fail(MESSAGES.UnclosedString, n) end
    local c = src:byte(i + 1)
    if c == 34 then
      i = i + 1
      break
    elseif c == 92 then
      local e = src:sub(i + 2, i + 2)
      if e == "u" then
        local hex = src:sub(i + 3, i + 6)
        if not hex:match("^%x%x%x%x$") then
          local bad = hex:find("[^%x]") or (#hex + 1)
          if i + 1 + bad >= n then sc:fail(MESSAGES.UnclosedString, n) end
          sc:fail(MESSAGES.UnexpectedToken, i + 1 + bad)
        end
        local cp = tonumber(hex, 16)
        if cp >= 0xD800 and cp <= 0xDBFF and src:sub(i + 7, i + 8) == "\\u" then
          local lo = src:sub(i + 9, i + 12)
          local lcp = lo:match("^%x%x%x%x$") and tonumber(lo, 16)
          if lcp and lcp >= 0xDC00 and lcp <= 0xDFFF then
            out[#out + 1] = utf8.char(0x10000 + ((cp - 0xD800) << 10) + (lcp - 0xDC00))
            i = i + 12
            goto continue
          end
        end
        -- Unpaired: the compiled parser gives up decoding and keeps the
        -- whole string as written.
        if cp >= 0xD800 and cp <= 0xDFFF then raw = true else out[#out + 1] = utf8.char(cp) end
        i = i + 6
      elseif SIMPLE_ESCAPES[e] then
        out[#out + 1] = SIMPLE_ESCAPES[e]
        i = i + 2
      elseif e == "" then
        sc:fail(MESSAGES.UnclosedString, n)
      else
        sc:fail(MESSAGES.UnexpectedToken, i + 1)
      end
    elseif c < 32 then
      sc:fail(MESSAGES.UnexpectedToken, i)
    else
      out[#out + 1] = string.char(c)
      i = i + 1
    end
    ::continue::
  end
  sc.pos = i
  return fig.scalar("string", { s, i }, raw and src:sub(s + 2, i - 1) or table.concat(out))
end

-- A number: the lexeme verbatim, its kind by whether it has a fraction
-- or an exponent.
local function number(sc)
  local s = sc.pos
  local c = sc:byte()
  if not (c and (c == 45 or (c >= 48 and c <= 57))) then return nil end
  if c == 45 then
    sc:advance()
    c = sc:byte()
    if not (c and c >= 48 and c <= 57) then
      if sc:eof() then sc:fail(MESSAGES.UnexpectedEndOfInput) end
      sc:fail(MESSAGES.UnexpectedToken)
    end
  end
  if c == 48 then
    sc:advance()
    local d = sc:byte()
    if d and d >= 48 and d <= 57 then sc:fail(MESSAGES.LeadingZero) end
  else
    sc:match("%d+")
  end
  local kind = "int"
  if sc:byte() == 46 then
    sc:advance()
    if not sc:match("%d+") then
      if sc:eof() then sc:fail(MESSAGES.UnexpectedEndOfInput) end
      sc:fail(MESSAGES.UnexpectedToken)
    end
    kind = "float"
  end
  local e = sc:byte()
  if e == 101 or e == 69 then
    sc:advance()
    local sign = sc:byte()
    if sign == 43 or sign == 45 then sc:advance() end
    if not sc:match("%d+") then
      if sc:eof() then sc:fail(MESSAGES.UnexpectedEndOfInput) end
      sc:fail(MESSAGES.UnexpectedToken)
    end
    kind = "float"
  end
  return fig.scalar(kind, { s, sc.pos }, sc:slice(s, sc.pos))
end

-- `null`, `true`, `false`, whole words; anything else that begins like
-- one is the compiled tokenizer's unexpected token.
local function literal(sc)
  local s = sc.pos
  local ws, we = sc:match("[a-z]+")
  if not ws then return nil end
  local word = sc:slice(ws, we)
  if word == "null" then return fig.scalar("null", { s, we }, nil) end
  if word == "true" or word == "false" then return fig.scalar("bool", { s, we }, word) end
  sc:fail(MESSAGES.UnexpectedToken, s)
end

-- ── containers ────────────────────────────────────────────────────────────

local trivia = G.trivia({ space = G.ws1 })

local value

-- After an element: `,` and then another element, or the close. The
-- compiled parser refuses a trailing comma where the next element should
-- be, so the comma is consumed here and the container's loop finds the
-- close and refuses it as the missing element.
local function separator(close)
  return function(sc, ctx)
    trivia(sc, ctx)
    if sc:lit(",") then
      trivia(sc, ctx)
      if close(sc) then sc:fail(MESSAGES.UnexpectedToken, sc.pos - 1) end
      return
    end
    local p = sc.pos
    if close(sc) then
      sc.pos = p
      return
    end
    if sc:eof() then return end
    sc:fail(MESSAGES.UnexpectedToken)
  end
end

local mapping = G.map({
  open = G.lit("{"),
  close = G.lit("}"),
  trivia = trivia,
  entry = G.entry({
    key = string_value,
    between = G.ws,
    sep = G.lit(":"),
    value = function(sc, ctx) return value(sc, ctx) end,
    missing_sep = MESSAGES.UnexpectedToken,
    missing_value = MESSAGES.UnexpectedToken,
  }),
  after = separator(G.lit("}")),
  duplicates = "keep",
  expected = MESSAGES.UnexpectedToken,
  unclosed = MESSAGES.UnexpectedToken,
})

local sequence = G.sequence({
  open = G.lit("["),
  close = G.lit("]"),
  trivia = trivia,
  item = function(sc, ctx) return value(sc, ctx) end,
  after = separator(G.lit("]")),
  expected = MESSAGES.UnexpectedToken,
  unclosed = MESSAGES.UnexpectedToken,
})

value = G.choice({ mapping, sequence, string_value, number, literal })

M.parse = G.document({
  bom = true,
  root = value,
  trivia = trivia,
  missing = MESSAGES.UnexpectedToken,
  trailing = MESSAGES.UnexpectedToken,
})

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: `pretty` (the default) puts one element
-- per line at `indent` spaces a level, `"key": value`, an empty container
-- as `{}` or `[]`; compact writes no whitespace at all. Strings escape the
-- quote, the backslash and the control characters — the C0 short forms
-- where JSON has them, `\u00xx` otherwise — and pass everything else
-- through as UTF-8. Strict JSON has nowhere to put a comment, so a tree's
-- comments are dropped.

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == "\\" then return "\\\\" end
    if ch == "\b" then return "\\b" end
    if ch == "\f" then return "\\f" end
    if ch == "\n" then return "\\n" end
    if ch == "\r" then return "\\r" end
    if ch == "\t" then return "\\t" end
    return string.format("\\u%04x", ch:byte())
  end) .. '"'
end

local function write_node(w, row, depth)
  local k = row.kind
  if k == "null" then
    w:put("null")
  elseif k == "bool" or k == "int" or k == "float" then
    w:put(row.text)
  elseif k == "string" then
    w:put(quote(row.text or ""))
  elseif k == "sequence" or k == "mapping" then
    local open, close = "[", "]"
    if k == "mapping" then open, close = "{", "}" end
    if #row.items == 0 then return w:put(open, close) end
    w:put(open):nl()
    for i, child in ipairs(row.items) do
      w:indent(depth + 1)
      if k == "mapping" then
        if child.key.kind ~= "string" then error("a JSON key must be a string", 0) end
        w:put(quote(child.key.text or ""), w.pretty and ": " or ":")
        write_node(w, child.value, depth + 1)
      else
        write_node(w, child, depth + 1)
      end
      if i < #row.items then w:put(",") end
      w:nl()
    end
    w:indent(depth):put(close)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as JSON", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function M.print(_dialect, t, options)
  local w = fig.writer(options)
  write_node(w, t.byid(0), 0)
  w:put("\n")
  return w:string()
end

return M
