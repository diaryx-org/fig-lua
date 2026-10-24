-- ZON, in Lua: the twin of fig's compiled `zon` format, row for row.
--
-- ZON is a data format, and this script reads it as one. The compiled
-- format hands its source to `std.zig.Ast.parse(.zon)` and walks the tree
-- Zig's own parser built, but what the two sides are held to is not that
-- parser: it is the node table — every fixture in `tests/fixtures/zon`,
-- row for row, comments and spans included — and the printer's bytes with
-- it. So what is written below is ZON's own grammar, small, rather than as
-- much of Zig as decides what ZON is.
--
--   value     ::= '.{' container '}' | scalar | '(' value ')'
--   container ::= [ field (',' field)* [','] ] | [ value (',' value)* [','] ]
--   field     ::= '.' name '=' value
--   name      ::= ident | '@"' … '"'
--   scalar    ::= number | '"' … '"' | '\\' line… | "'" char "'" | '.' name
--               | 'true' | 'false' | 'null' | 'inf' | 'nan'
--
-- `.{ .a = 1 }` is a mapping, `.{ 1, 2 }` a sequence, `.{}` an empty
-- mapping; a container spans `.{` through `}`, an entry its field name
-- (without the dot) through its value. A number keeps its lexeme verbatim
-- — `0xFF`, `1_000`, `- 1` with the space, since `-` is a prefix operator
-- — and is a float when it has a `.` or its radix's exponent; `inf`,
-- `-inf` and `nan` are floats. A string decodes Zig's escapes, and a `\\`
-- multiline string joins its lines with `\n`, spanning the first `\\` to
-- the last line's end. `.name` is an `enum_literal` string, `'c'` a
-- `char_literal` int whose text is the decimal codepoint, and a `.@"…"`
-- name decodes as a string. Parentheses group and leave no trace: the node
-- is the one inside them, and a comment in there is dropped, as the
-- compiled walk drops it.
--
-- Comments are `//` to the end of the line, bound by the grammar module's
-- policy with `closing_line`: one on the line a value ends is that value's
-- trailing comment — unless the value is a container spanning lines, which
-- takes it as its last dangling one; one on the line a `.{` opens is that
-- container's trailing comment; anything else waits for the next field
-- name or element and leads it, or dangles on the container that closes
-- over it. Two places hold nothing for a comment to belong to, and drop
-- it: between a field name and its value, and below the document.
--
-- Everything else is a refusal, and the refusals are the format's, worded
-- here: an operator, a bare identifier, a `@builtin`, a `[N]T{…}`, a
-- keyword-led expression, a `///` doc comment, a `/* … */`, a second
-- document. The compiled format says `InvalidZon` or `UnsupportedZon` with
-- no offset at all; this says what was wrong and where, which is each
-- side's own business.
--
-- Every offset is a byte offset.

local G = require("fig.grammar")

local M = {}

-- ── bytes ─────────────────────────────────────────────────────────────────
-- The lexical rules read bytes by offset rather than moving the scanner, so
-- that a literal is measured before the cursor commits to it.

local IDENT = "[A-Za-z_][A-Za-z0-9_]*"

local function byte_at(sc, i) return sc.src:byte(i + 1) or -1 end
local chr = string.char
local function is_digit(b) return b >= 48 and b <= 57 end
local function is_hex(b) return is_digit(b) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102) end
local function is_ident_start(b) return b == 95 or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) end
-- What a string or a character literal may not hold: a newline is its own
-- refusal, and every other control byte has an escape instead.
local function is_control(b) return b < 32 or b == 127 end
-- The bytes of a codepoint, and what a decoder's buffer spells: a Lua
-- string is bytes already, so its buffer is its text as it stands.
local utf8_bytes = utf8.char
local function from_bytes(s) return s end

-- ── comments ──────────────────────────────────────────────────────────────

local slashes = G.comment("//")

-- `//` to the end of the line. `///` and `//!` are Zig's doc comments, and
-- a ZON document is data: there is nothing in it for them to document.
local function line_comment(sc)
  local s = sc.pos
  if byte_at(sc, s) ~= 47 or byte_at(sc, s + 1) ~= 47 then return nil end
  local c = byte_at(sc, s + 2)
  if c == 33 or (c == 47 and byte_at(sc, s + 3) ~= 47) then
    sc:fail("a `" .. sc:slice(s, s + 3) .. "` doc comment is not ZON; a ZON comment is `//`", s)
  end
  return slashes(sc)
end

local trivia = G.trivia({ space = G.ws1, comment = line_comment })

-- ── escapes ───────────────────────────────────────────────────────────────

local SIMPLE = { [110] = 10, [114] = 13, [116] = 9, [92] = 92, [39] = 39, [34] = 34 }
local BRACES = "`\\u` takes a codepoint in braces, as `\\u{1F600}`"

-- The escape at `i` (a `\`): the bytes it stands for, the codepoint it
-- spells, and where it ends. Zig's set is `\n \r \t \\ \' \"`, `\xNN` for a
-- raw byte, and `\u{…}` for a codepoint — which a string may not spell as a
-- surrogate, no text holding one, and a character literal may.
local function escape_at(sc, i, in_char)
  local c = byte_at(sc, i + 1)
  local simple = SIMPLE[c]
  if simple then return chr(simple), simple, i + 2 end
  if c == 120 then
    local hex = sc:slice(i + 2, i + 4)
    if not hex:match("^%x%x$") then sc:fail("`\\x` takes two hex digits, as `\\x41`", i) end
    local b = tonumber(hex, 16)
    return chr(b), b, i + 4
  end
  if c == 117 then
    if byte_at(sc, i + 2) ~= 123 then sc:fail(BRACES, i) end
    local j = i + 3
    while is_hex(byte_at(sc, j)) do j = j + 1 end
    if j == i + 3 or byte_at(sc, j) ~= 125 then sc:fail(BRACES, i) end
    local cp = tonumber(sc:slice(i + 3, j), 16)
    if cp > 0x10FFFF then sc:fail("`\\u{…}` is past the last codepoint, `10FFFF`", i) end
    if not in_char and fig.is_surrogate(cp) then sc:fail("`\\u{…}` is a surrogate, which no text holds", i) end
    return utf8_bytes(cp), cp, j + 1
  end
  sc:fail("`\\" .. ((c >= 32 and c < 127) and chr(c) or "") .. "` is not a ZON escape", i)
end

-- ── scalars ───────────────────────────────────────────────────────────────

-- `"…"`: Zig's escapes, and one line. A tab, or any other control byte,
-- has an escape and is not itself a string character.
local function string_literal(sc)
  if byte_at(sc, sc.pos) ~= 34 then return nil end
  local s = sc.pos
  local i = s + 1
  local out = {}
  while true do
    local c = byte_at(sc, i)
    if c == 34 then
      i = i + 1
      break
    end
    if c < 0 or c == 10 then sc:fail('unclosed string; expected a closing `"` on this line', s) end
    if is_control(c) then sc:fail("a control byte is not a ZON string character; write it as an escape", i) end
    if c == 92 then
      local bytes, _, next = escape_at(sc, i, false)
      out[#out + 1] = bytes
      i = next
    else
      out[#out + 1] = chr(c)
      i = i + 1
    end
  end
  sc.pos = i
  return fig.scalar("string", { s, i }, from_bytes(table.concat(out)))
end

-- `'c'`: exactly one character, escaped or not, as the decimal codepoint it
-- spells — a `char_literal` int, the kind the wire keeps it in.
local function char_literal(sc)
  if byte_at(sc, sc.pos) ~= 39 then return nil end
  local s = sc.pos
  local cp, i
  if byte_at(sc, s + 1) == 92 then
    _, cp, i = escape_at(sc, s + 1, true)
  else
    i = s + 1
    while byte_at(sc, i) >= 0 and byte_at(sc, i) ~= 39 and byte_at(sc, i) ~= 10 do i = i + 1 end
    local inner = sc:slice(s + 1, i)
    if utf8.len(inner) ~= 1 then sc:fail("a `'…'` character literal holds one character", s) end
    cp = utf8.codepoint(inner, 1)
  end
  if byte_at(sc, i) ~= 39 then sc:fail("a `'…'` character literal holds one character", s) end
  sc.pos = i + 1
  return fig.scalar("int", { s, sc.pos }, tostring(cp), { ext_kind = "char_literal" })
end

-- `\\line`, one or more: each line's text after its `\\`, joined with a
-- newline. The span runs from the first `\\` to the end of the last line,
-- the line ending itself left out.
local function multiline(sc)
  if byte_at(sc, sc.pos) ~= 92 or byte_at(sc, sc.pos + 1) ~= 92 then return nil end
  local s = sc.pos
  local lines = {}
  while true do
    local from = sc.pos + 2
    local i = from
    while byte_at(sc, i) >= 0 and byte_at(sc, i) ~= 10 do i = i + 1 end
    local stop = byte_at(sc, i - 1) == 13 and i - 1 or i
    lines[#lines + 1] = sc:slice(from, stop)
    sc.pos = i
    local after = sc.pos
    G.ws(sc)
    if byte_at(sc, sc.pos) ~= 92 or byte_at(sc, sc.pos + 1) ~= 92 then
      sc.pos = after
      return fig.scalar("string", { s, stop }, table.concat(lines, "\n"))
    end
  end
end

-- A Zig number lexeme: a digit, then digits, letters and `_`, with a `.`
-- only before another of those and a sign only after an exponent letter.
-- The text is the lexeme as written, the sign and its space included.
local function number_value(sc, s)
  sc:advance()
  while true do
    local c = byte_at(sc, sc.pos)
    if is_digit(c) or is_ident_start(c) then
      sc:advance()
      local sign = byte_at(sc, sc.pos)
      if (c == 101 or c == 69 or c == 112 or c == 80) and (sign == 43 or sign == 45) then sc:advance() end
    elseif c == 46 and (is_digit(byte_at(sc, sc.pos + 1)) or is_ident_start(byte_at(sc, sc.pos + 1))) then
      sc:advance()
    else
      break
    end
  end
  local raw = sc:slice(s, sc.pos)
  local body = (raw:gsub("^%-%s*", ""))
  local exponent = body:match("^0[xX]") and "[pP]" or "[eE]"
  local float = raw:find(".", 1, true) ~= nil or body:find(exponent) ~= nil
  return fig.scalar(float and "float" or "int", { s, sc.pos }, raw)
end

-- `-` negates a literal: a number, or `inf`. ZON has no other prefix, and
-- no operator at all.
local function negated(sc)
  local s = sc.pos
  sc:advance()
  G.ws(sc)
  if is_digit(byte_at(sc, sc.pos)) then return number_value(sc, s) end
  local ms, me = sc:match(IDENT)
  -- A negated `inf` is spelled `-inf` whatever the space between them: it
  -- is a value with one name, not a lexeme.
  if ms and sc:slice(ms, me) == "inf" then return fig.scalar("float", { s, sc.pos }, "-inf") end
  sc:fail("`-` negates a number in ZON; ZON holds values, not expressions", s)
end

-- `true`, `false`, `null`, `inf` and `nan` are ZON's words. A bare
-- identifier — `foo`, `undefined`, `if` — is Zig, and Zig is not ZON.
local function word(sc)
  local s, e = sc:match(IDENT)
  local w = sc:slice(s, e)
  if w == "true" or w == "false" then return fig.scalar("bool", { s, e }, w) end
  if w == "null" then return fig.scalar("null", { s, e }) end
  if w == "inf" or w == "nan" then return fig.scalar("float", { s, e }, w) end
  sc:fail("`" .. w .. "` is not a ZON value; ZON holds numbers, strings, `.name`, `true`, `false` and `null`", s)
end

-- A name, the span the wire reports for a field or an enum literal — the
-- `.` before it is not in the span: `foo`, or `@"any text"`.
local function name(sc)
  local s = sc.pos
  if byte_at(sc, s) == 64 then
    sc:advance()
    local q = string_literal(sc)
    if q == nil then sc:fail('expected a `"…"` name after `@`', s) end
    return fig.scalar("string", { s, q.span[2] }, q.text)
  end
  local ms, me = sc:match(IDENT)
  if ms == nil then return nil end
  return fig.scalar("string", { ms, me }, sc:slice(ms, me))
end

-- ── containers ────────────────────────────────────────────────────────────

-- A container's opener, `.{`, and a `//` comment on its line, which the
-- container takes as its trailing comment once it exists — held on a stack
-- until then, because containers nest. The context's `last` is cleared so
-- that nothing outside catches a comment written inside.
local function opener(sc, ctx)
  local s = sc.pos
  if byte_at(sc, s) ~= 46 or byte_at(sc, s + 1) ~= 123 then return nil end
  sc:advance(2)
  local p = sc.pos
  G.hs(sc)
  local c = line_comment(sc)
  if c == nil then sc.pos = p end
  ctx.heads[#ctx.heads + 1] = c or false
  ctx.last = nil
  return { s, sc.pos }
end

-- After a value: a comma, or the `}` that closes the container — a trailing
-- comma is optional. What stands there instead says what the input meant.
local OPERATORS = "+-*/%<>!&|^~?:"

local function separator(sc, ctx)
  trivia(sc, ctx)
  if sc:lit(",") then return end
  local c = byte_at(sc, sc.pos)
  if c == 125 then return end
  if c < 0 then sc:fail("unclosed `.{`; expected `}` before the end of the input") end
  if c == 61 then
    sc:fail("a `.name = value` field cannot follow a value; a ZON container holds fields or values, not both")
  end
  if OPERATORS:find(chr(c), 1, true) then
    sc:fail("ZON holds values, not expressions; `" .. chr(c) .. "` is not ZON")
  end
  sc:fail("expected `,` or `}` after this value")
end

local value

local mapping_rule = G.map({
  open = opener,
  close = G.lit("}"),
  trivia = trivia,
  entry = G.entry({
    prefix = G.lit("."),
    -- The comments waiting are the field name's, taken before the value is
    -- read: a container value would otherwise give them to its first
    -- member, which is what a comment written inside one means.
    key = function(sc, ctx)
      local k = name(sc)
      if k ~= nil then ctx:flush(k, "leading") end
      return k
    end,
    -- A comment between a field name and its value belongs to neither and
    -- is dropped, as the compiled walk drops it: the walk never looks at
    -- the gap the `=` sits in.
    between = function(sc) return trivia(sc, nil) end,
    sep = G.lit("="),
    value = function(sc, ctx) return value(sc, ctx) end,
    missing_sep = "expected `=` after this field name",
    missing_value = "expected a value after `=`",
  }),
  after = separator,
  duplicates = "keep",
  expected = "expected a `.name = value` field or `}` here",
  unclosed = "unclosed `.{`; expected `}` before the end of the input",
})

local sequence_rule = G.sequence({
  open = opener,
  close = G.lit("}"),
  trivia = trivia,
  item = function(sc, ctx) return value(sc, ctx) end,
  after = separator,
  expected = "expected a value or `}` here",
  unclosed = "unclosed `.{`; expected `}` before the end of the input",
})

-- Whether the `.{` here holds fields rather than positional values: a
-- `.name =` after it, past whatever trivia. An empty `.{}` is a mapping too
-- — which is why `.{}` is the empty document's seed.
local function holds_fields(sc)
  local p = sc.pos
  sc:advance(2)
  trivia(sc, nil)
  local fields = byte_at(sc, sc.pos) == 125
  if not fields and byte_at(sc, sc.pos) == 46 and byte_at(sc, sc.pos + 1) ~= 123 then
    sc:advance()
    if name(sc) ~= nil then
      G.ws(sc)
      fields = byte_at(sc, sc.pos) == 61 and byte_at(sc, sc.pos + 1) ~= 61
    end
  end
  sc.pos = p
  return fields
end

local function container(sc, ctx)
  local built = (holds_fields(sc) and mapping_rule or sequence_rule)(sc, ctx)
  local head = ctx.heads[#ctx.heads]
  ctx.heads[#ctx.heads] = nil
  if head then built:comment("trailing", head.text, head.style) end
  return built
end

-- ── values ────────────────────────────────────────────────────────────────

-- What a byte that opens no value means. `nil` where a closer stands, so
-- that the container's own rule reports the shape it wanted.
local function not_a_value(sc, c)
  if c < 0 or c == 125 or c == 41 or c == 44 then return nil end
  if c == 64 then sc:fail("a `@builtin` is not ZON; ZON holds values, not code") end
  if c == 91 or c == 123 then
    sc:fail("ZON writes every container as `.{ … }`; `" .. chr(c) .. "` is not ZON")
  end
  if c == 47 and byte_at(sc, sc.pos + 1) == 42 then
    sc:fail("`/* … */` is not a ZON comment; a ZON comment is `//` to the end of the line")
  end
  sc:fail("ZON holds values, not expressions; `" .. chr(c) .. "` is not ZON")
end

value = function(sc, ctx)
  local c = byte_at(sc, sc.pos)
  if c == 40 then
    -- Parentheses group and are not in the tree: the node is the one
    -- inside them, and a comment in there is dropped.
    sc:advance()
    trivia(sc, nil)
    local inner = value(sc, ctx)
    if inner == nil then sc:fail("expected a value after `(`") end
    trivia(sc, nil)
    if not sc:lit(")") then sc:fail("expected `)` after this value") end
    return inner
  end
  if c == 46 then
    if byte_at(sc, sc.pos + 1) == 123 then return container(sc, ctx) end
    local s = sc.pos
    sc:advance()
    local n = name(sc)
    if n == nil then sc:fail("expected a name after `.`", s) end
    return fig.scalar("string", n.span, n.text, { ext_kind = "enum_literal" })
  end
  if c == 45 then return negated(sc) end
  if c == 34 then return string_literal(sc) end
  if c == 39 then return char_literal(sc) end
  if c == 92 then return multiline(sc) end
  if is_digit(c) then return number_value(sc, sc.pos) end
  if is_ident_start(c) then return word(sc) end
  return not_a_value(sc, c)
end

-- The document: one value, and nothing after it. Comments before a
-- container root go to its first field name or element — the container's
-- own rule flushes them — and a scalar root takes them as leading.
function M.parse(_dialect, input)
  local sc = fig.scanner(input)
  local ctx = G.context(sc, { closing_line = true })
  ctx.heads = {}
  trivia(sc, ctx)
  local root = value(sc, ctx)
  if root == nil then
    sc:fail(sc:eof() and "no document here; expected a value" or "expected a value here")
  end
  ctx:flush(root, "leading")
  ctx.last = root
  trivia(sc, ctx)
  if not sc:eof() then sc:fail("unexpected content after the document; a ZON file holds one value") end
  -- What is left waiting is a comment written below the document, on a
  -- line of its own, with nothing after it to lead: it is dropped, as the
  -- compiled walk drops it.
  return fig.rows(root)
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: every container broken one member per line
-- at four spaces a level with a trailing comma, `.{}` when empty; comments
-- where they were bound — a container's own trailing comment after its
-- `.{`, a member's leading above it, its trailing after the comma, its
-- dangling before the `}`. Without `pretty`, everything inline and no
-- comments at all.

-- Zig's keywords, which a field name may not be spelled bare — `.@"error"`
-- rather than `.error`. `true`, `false` and `null` are not among them.
local KEYWORDS = {}
for kw in ([[addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue
  defer else enum errdefer error export extern fn for if inline noalias noinline nosuspend opaque or orelse
  packed pub resume return linksection struct suspend switch test threadlocal try union unreachable var
  volatile while]]):gmatch("%S+") do
  KEYWORDS[kw] = true
end
local BARE = "^[A-Za-z_][A-Za-z0-9_]*$"
local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local CHAR_ESCAPES = { [39] = "\\'", [92] = "\\\\", [10] = "\\n", [13] = "\\r", [9] = "\\t" }

local function is_container(row) return row.kind == "mapping" or row.kind == "sequence" end

-- A string's characters as the compiled printer escapes them: the five it
-- spells, any other control character as `\xNN`, everything else itself.
local function escaped(s)
  return (s:gsub('["\\%c\127]', function(c) return ESCAPES[c] or string.format("\\x%02x", c:byte()) end))
end

local function key_name(key)
  if key:match(BARE) and not KEYWORDS[key] then return "." .. key end
  return '.@"' .. escaped(key) .. '"'
end

local function write_name(w, key)
  w:put(key_name(key))
end

-- A character literal from the codepoint its text spells: the escapes it
-- has, a printable ASCII character as itself, anything else as `\u{…}`.
local function write_char(w, text)
  if not text:match("^%d+$") then return w:put(text) end
  local cp = tonumber(text)
  local printable = (cp >= 0x20 and cp <= 0x7E) and chr(cp) or string.format("\\u{%x}", cp)
  w:put("'", CHAR_ESCAPES[cp] or printable, "'")
end

local function write_trailing(w, row)
  local c = w.pretty and row.trailing[1] or nil
  if not c then return end
  w:put(" //")
  if c.text ~= "" then w:put(" ", (c.text:gsub("\n", " "))) end
end

local write_node, write_container

write_node = function(w, row, depth)
  local k = row.kind
  if k == "null" then
    w:put("null")
  elseif k == "bool" then
    w:put(row.text)
  elseif k == "int" and row.ext_kind == "char_literal" then
    write_char(w, row.text)
  elseif k == "int" or k == "float" then
    w:put(row.text)
  elseif k == "string" and row.ext_kind == "enum_literal" then
    write_name(w, row.text or "")
  elseif k == "string" then
    w:put('"', escaped(row.text or ""), '"')
  elseif is_container(row) then
    write_container(w, row, depth)
  elseif k == "keyvalue" then
    if row.key.kind ~= "string" then error("a ZON field name must be a string", 0) end
    write_name(w, row.key.text or "")
    w:put(" = ")
    write_node(w, row.value, depth)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as ZON", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

write_container = function(w, row, depth)
  local dangling = w.pretty and row.dangling or {}
  if #row.items == 0 and #dangling == 0 then
    w:put(".{}")
    write_trailing(w, row)
    return
  end
  if not w.pretty then
    w:put(".{ ")
    for i, item in ipairs(row.items) do
      if i > 1 then w:put(", ") end
      write_node(w, item, depth + 1)
    end
    w:put(" }")
    return
  end
  w:put(".{")
  write_trailing(w, row)
  w:put("\n")
  for _, item in ipairs(row.items) do
    local lead = item.kind == "keyvalue" and item.key or item
    local trail = item.kind == "keyvalue" and item.value or item
    w:comments(lead.leading, "//", depth + 1)
    w:indent(depth + 1)
    write_node(w, item, depth + 1)
    w:put(",")
    -- A container writes its own trailing comment, beside its `.{` or
    -- after the `.{}` it is — which is before the comma, not after it.
    if not is_container(trail) then write_trailing(w, trail) end
    w:put("\n")
  end
  w:comments(dangling, "//", depth + 1)
  w:indent(depth)
  w:put("}")
end

function M.print(_dialect, t, options)
  local w = fig.writer({ pretty = options and options.pretty, indent = 4 })
  local root = t.byid(0)
  if w.pretty then w:comments(root.leading, "//", 0) end
  write_node(w, root, 0)
  if not is_container(root) then write_trailing(w, root) end
  w:put("\n")
  return w:string()
end

-- ── the language ──────────────────────────────────────────────────────────

M.name = "lua-zon"
M.caps = { read = true, edit = true, serialize = true }
M.lossless = { null = true, enum_literal = true, char_literal = true }
M.syntax = {
  comments = { line = { open = "//" }, trailing = { open = "//" } },
  kv_sep = " = ",
  -- The byte before every key, which the editor removes with the key:
  -- `.` (the wire carries a sigil as its byte).
  key_sigil = 46,
  empty_map_literal = ".{}",
  bare_document_mapping = false,
  flow_map_open = ".{",
  flow_map_close = "}",
}
M.dialects = {
  -- The compiled format owns `.zon`, and a compiled format's extension
  -- wins, so this is reached by `--lang lua-zon`.
  { name = "lua-zon", extensions = { "zon" }, splice = "literal", empty_doc_seed = ".{}\n" },
}
M.samples = {
  '.{ .a = 1, .b = .{ .c = "d" }, .e = .{ 1, 2 } }\n',
}
-- A key's name as ZON writes one, for a key the editor inserts or
-- renames: a struct field, `.name`, or `.@"has space"` when
-- it is not a bare identifier.
M.renderers = { "key_name" }

function M.render(which, args)
  if which == "key_name" then return key_name(args.key) end
  error("no renderer `" .. which .. "`", 0)
end

return M
