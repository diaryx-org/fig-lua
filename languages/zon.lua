-- ZON, in Lua: the twin of fig's compiled `zon` format, row for row.
--
-- `fig lang check lua-zon --against zon <files…>` holds this script to the
-- compiled parser's node table on every file given, and this script is
-- written against `fig lang table -i zon`, which prints that table. The
-- compiled parser hand-rolls nothing: ZON is a subset of Zig, so it hands
-- the source to `std.zig.Ast.parse(.zon)` and walks the tree Zig's own
-- parser built (fig's `src/languages/zon/parser.zig`). This script is
-- therefore three things in one: as much of Zig's tokenizer and expression
-- parser as decides what ZON is, that walk, and the printer.
--
-- The shape, as the compiled walk builds it:
--
--   * one expression, then the end of the input; `.{ .a = 1 }` is a
--     mapping, `.{ 1, 2 }` a sequence, `.{}` an empty mapping; a container
--     spans `.{` through `}`, an entry its field name (without the dot)
--     through its value;
--   * a number keeps its lexeme (`0xFF`, `1_000`, `- 1` with the space —
--     Zig's `-` is a prefix operator) and is a float when it has a `.` or
--     an exponent; `inf`, `-inf` and `nan` are floats; `true`, `false`
--     and `null` are what they say; a string decodes Zig's escapes, and a
--     `\\` multiline string joins its lines with `\n`, spanning the first
--     `\\` to the last line's end; `.name` is an `enum_literal` string,
--     `'c'` a `char_literal` int whose text is the decimal codepoint;
--     `.@"quoted"` names decode as strings;
--   * comments are recovered from the gaps between nodes — `std.zig.Ast`
--     drops them — so one on the line of the value just finished trails
--     it (or dangles on a container whose `}` that line closes), one on
--     its own line leads the next key or element, or dangles on the
--     container it ends; a `// head` after a `.{` trails the container;
--     what follows the document on later lines is dropped, and so is a
--     comment inside parentheses.
--
-- The refusals are the compiled parser's two: `InvalidZon` for what Zig's
-- parser refuses (its warnings included — a missing comma, `1 +2`), a
-- string or char literal that does not decode, or a document that is not
-- one expression; `UnsupportedZon` for Zig that ZON is not — an
-- identifier, an operator, a call, a typed `T{…}`. Neither carries an
-- offset. Zig's whole expression grammar is not here: what lies outside
-- ZON is skipped by shape (operators, suffixes, calls, balanced brackets,
-- a keyword-led expression to its terminator) and called unsupported when
-- the shape closes; where that skip would need the rest of Zig to know
-- better, this may say `UnsupportedZon` for what Zig would refuse.
--
-- Everything is checked in document order, as the walk meets it, so the
-- first of an unsupported node and an undecodable literal is what a file
-- with both is refused for.

local M = {}

M.name = "lua-zon"
M.caps = { read = true, edit = true, serialize = true }
M.lossless = { null = true, enum_literal = true, char_literal = true }
M.syntax = {
  comments = { style = "slashes", line = { open = "//" }, trailing = { open = "//" } },
  kv_sep = " = ",
  key_style = "zon_field",
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
M.renderers = {}

local INVALID, UNSUPPORTED = "InvalidZon", "UnsupportedZon"

local function invalid() fig.fail(INVALID) end
local function unsupported() fig.fail(UNSUPPORTED) end

-- ── Zig's tokenizer, the part that matters ────────────────────────────────
-- Tokens are `{ tag=, s=, e= }` over 0-based byte offsets. Zig's tokenizer
-- never fails: an `invalid` token is what a byte it cannot place becomes,
-- and Zig's parser then refuses it. So does this one, as `InvalidZon`.

local KEYWORDS = {}
for kw in ([[addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue
  defer else enum errdefer error export extern fn for if inline noalias noinline nosuspend opaque or orelse
  packed pub resume return linksection struct suspend switch test threadlocal try union unreachable var
  volatile while]]):gmatch("%S+") do
  KEYWORDS[kw] = true
end

local function is_ident_start(b)
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end
local function is_ident_byte(b)
  return is_ident_start(b) or (b >= 48 and b <= 57)
end
-- What continues a number after its first digit: letters other than the
-- exponent ones, digits and `_`.
local function is_number_byte(b)
  return (b >= 48 and b <= 57) or b == 95 or (b >= 65 and b <= 90 and b ~= 69 and b ~= 80)
    or (b >= 97 and b <= 122 and b ~= 101 and b ~= 112)
end
local function is_exponent(b) return b == 101 or b == 69 or b == 112 or b == 80 end
-- A control byte Zig refuses inside a literal or comment.
local function is_control(b)
  return (b >= 1 and b <= 9) or (b >= 11 and b <= 31) or b == 127
end

-- The operators, longest spelling first, as Zig lexes them.
local OPERATORS = {
  "<<=", ">>=", "<<|", "<<|=", "...", ".**", "*%=", "*|=", "+%=", "+|=", "-%=", "-|=",
  "==", "!=", "<=", ">=", "<<", ">>", "&=", "*=", "*%", "*|", "**", "%=", "+=", "+%", "+|", "++",
  "-=", "-%", "-|", "->", "/=", "|=", "||", "^=", "..", ".*", ".?", "=>",
  "(", ")", "[", "]", "{", "}", ";", ",", "?", ":", "%", "*", "+", "<", ">", "^", "~", ".", "-", "/", "&", "|", "=", "!",
}
table.sort(OPERATORS, function(a, b) return #a > #b end)

local function tokenize(src)
  local n = #src
  local i = 0
  local tokens = {}
  local function at(k) return src:byte(k + 1) or 0 end
  local function emit(tag, s, e) tokens[#tokens + 1] = { tag = tag, s = s, e = e } end
  -- An invalid token runs to the end of its line, as Zig's does; what it
  -- covers no longer matters, since the parser refuses it.
  local function invalid_token(s)
    while i < n and at(i) ~= 10 do i = i + 1 end
    emit("invalid", s, i)
  end
  -- The body of a `"…"` or `'…'` literal after its opener; the closing
  -- quote is consumed. A newline or a control byte inside is invalid.
  local function quoted_body(q)
    while true do
      if i >= n then return false end
      local c = at(i)
      if c == 10 then return false end
      if c == 92 then
        i = i + 1
        if i >= n or at(i) == 10 then return false end
        if is_control(at(i)) then return false end
        i = i + 1
      elseif c == q then
        i = i + 1
        return true
      elseif is_control(c) then
        return false
      else
        i = i + 1
      end
    end
  end
  while i < n do
    local c = at(i)
    local s = i
    if c == 32 or c == 10 or c == 9 or c == 13 then
      i = i + 1
    elseif c == 34 then
      i = i + 1
      if quoted_body(34) then emit("string_literal", s, i) else invalid_token(s) end
    elseif c == 39 then
      i = i + 1
      if quoted_body(39) then emit("char_literal", s, i) else invalid_token(s) end
    elseif is_ident_start(c) then
      while i < n and is_ident_byte(at(i)) do i = i + 1 end
      local word = src:sub(s + 1, i)
      emit(KEYWORDS[word] and ("keyword_" .. word) or "identifier", s, i)
    elseif c == 64 then -- @
      i = i + 1
      local d = at(i)
      if d == 34 then
        i = i + 1
        if quoted_body(34) then emit("identifier", s, i) else invalid_token(s) end
      elseif is_ident_start(d) then
        while i < n and is_ident_byte(at(i)) do i = i + 1 end
        emit("builtin", s, i)
      else
        invalid_token(s)
      end
    elseif c == 92 then -- `\\` multiline string line
      i = i + 1
      if at(i) ~= 92 then
        invalid_token(s)
      else
        local ok = true
        while i < n do
          local d = at(i)
          if d == 10 then break end
          if d == 13 then
            if at(i + 1) ~= 10 then ok = false end
            break
          end
          if is_control(d) then
            ok = false
            break
          end
          i = i + 1
        end
        if ok then emit("multiline_string_literal_line", s, i) else invalid_token(s) end
      end
    elseif c == 47 and at(i + 1) == 47 then -- `//`
      i = i + 2
      local tag = "comment"
      if at(i) == 33 then
        tag = "container_doc_comment"
      elseif at(i) == 47 and at(i + 1) ~= 47 then
        tag = "doc_comment"
      end
      local ok = true
      while i < n do
        local d = at(i)
        if d == 10 then break end
        if d == 13 then
          if at(i + 1) ~= 10 then ok = false end
          break
        end
        if is_control(d) then
          ok = false
          break
        end
        i = i + 1
      end
      if not ok then
        invalid_token(s)
      elseif tag ~= "comment" then
        emit(tag, s, i)
      end
    elseif c >= 48 and c <= 57 then
      i = i + 1
      -- `int`: digits, letters and `_`; an exponent letter may take a sign;
      -- a `.` followed by any of those turns it into a float.
      local state = "int"
      while i < n do
        local d = at(i)
        if is_number_byte(d) then
          i = i + 1
        elseif is_exponent(d) then
          i = i + 1
          if at(i) == 45 or at(i) == 43 then
            i = i + 1
            state = "float"
          end
        elseif d == 46 and state == "int" then
          local e = at(i + 1)
          if is_number_byte(e) then
            i = i + 2
            state = "float"
          elseif is_exponent(e) then
            i = i + 1
            state = "float"
          else
            break
          end
        else
          break
        end
      end
      emit("number_literal", s, i)
    elseif c == 46 and at(i + 1) == 42 and at(i + 2) == 42 then
      i = i + 3
      invalid_token(s) -- `.**`, which Zig lexes as its own invalid token
    else
      local matched
      for _, op in ipairs(OPERATORS) do
        if src:sub(i + 1, i + #op) == op then
          matched = op
          break
        end
      end
      if matched then
        i = i + #matched
        emit(matched, s, i)
      else
        invalid_token(s)
      end
    end
  end
  emit("eof", n, n)
  return tokens
end

-- ── Zig's parser, the ZON of it ───────────────────────────────────────────
-- Builds an intermediate tree of `{ kind=, first=, span=, … }`: `first` is
-- where the node's first token begins (a `(` or `-` included), `span` what
-- the compiled walk reports. What Zig would parse and the walk refuse is
-- an `unsupported` node, kept so that the walk meets it in order.

local P = {}
P.__index = P

function P:peek(k) return self.tokens[self.pos + (k or 0)] end
function P:tag(k) return self:peek(k).tag end
function P:next()
  local t = self.tokens[self.pos]
  if self.pos < #self.tokens then self.pos = self.pos + 1 end
  return t
end
function P:eat(tag)
  if self:tag() == tag then return self:next() end
  return nil
end
function P:expect(tag)
  if self:tag() ~= tag then invalid() end
  return self:next()
end
function P:text(t) return self.src:sub(t.s + 1, t.e) end

local BINARY = {}
for _, op in ipairs({ "keyword_or", "keyword_and", "==", "!=", "<", ">", "<=", ">=", "&", "^", "|", "keyword_orelse",
  "keyword_catch", "<<", "<<|", ">>", "+", "-", "++", "+%", "-%", "+|", "-|", "||", "*", "/", "%", "**", "*%", "*|" }) do
  BINARY[op] = true
end
local PREFIX = { ["!"] = true, ["-"] = true, ["~"] = true, ["-%"] = true, ["&"] = true, keyword_try = true }
local CLOSERS = { ["("] = ")", ["["] = "]", ["{"] = "}" }

-- Skip a balanced bracket run starting at the opener under the cursor.
function P:skip_balanced()
  local open = self:next()
  local close = CLOSERS[open.tag]
  local depth = 1
  while depth > 0 do
    local t = self:next()
    if t.tag == "eof" or t.tag == "invalid" then invalid() end
    if CLOSERS[t.tag] then depth = depth + 1 elseif t.tag == close then depth = depth - 1 end
  end
end

-- An expression outside ZON, skipped by shape: prefix operators, a
-- primary, suffixes, then binary operators with their right-hand sides.
-- The cursor ends where the expression does; the caller makes it an
-- `unsupported` node.
function P:skip_expr()
  while PREFIX[self:tag()] do self:next() end
  local t = self:peek()
  local tag = t.tag
  if tag == "number_literal" or tag == "string_literal" or tag == "char_literal" or tag == "identifier"
    or tag == "keyword_unreachable" or tag == "keyword_anytype" then
    self:next()
  elseif tag == "multiline_string_literal_line" then
    while self:tag() == "multiline_string_literal_line" do self:next() end
  elseif tag == "builtin" then
    self:next()
    if self:tag() ~= "(" then invalid() end
    self:skip_balanced()
  elseif tag == "." then
    if self:tag(1) == "identifier" then
      self:next()
      self:next()
    elseif self:tag(1) == "{" then
      self:next()
      self:skip_balanced()
    else
      invalid()
    end
  elseif tag == "(" or tag == "[" or tag == "{" then
    self:skip_balanced()
    if tag == "[" then self:skip_expr() end -- the element type
  elseif tag == "*" or tag == "**" or tag == "?" then
    self:next()
    self:skip_expr()
  elseif tag == "keyword_error" then
    self:next()
    if self:tag() == "." then
      self:next()
      self:expect("identifier")
    elseif self:tag() == "{" then
      self:skip_balanced()
    else
      invalid()
    end
  elseif tag:sub(1, 8) == "keyword_" then
    -- `if`, `switch`, `struct`, `fn`, `comptime`, a labelled block…: to
    -- the terminator that ends this expression at its own level.
    self:next()
    while true do
      local k = self:tag()
      if k == "eof" or k == "," or k == ")" or k == "]" or k == "}" then break end
      if k == "invalid" then invalid() end
      if CLOSERS[k] then self:skip_balanced() else self:next() end
    end
    return
  else
    invalid()
  end
  self:skip_suffixes_and_binary()
end

local function is_ws_byte(b) return b == 32 or b == 10 or b == 9 or b == 13 or b == 11 or b == 12 end

-- Whether a suffix or a binary operator follows the primary just parsed.
function P:continues()
  local k = self:tag()
  return (k == "." and self:tag(1) == "identifier") or k == ".*" or k == ".?" or k == "[" or k == "(" or k == "{"
    or BINARY[k] == true
end

-- After a primary: its suffixes, then a binary operator and its right-hand
-- side. Zig's whitespace rule around an operator is a warning, and a
-- warning is a refusal.
function P:skip_suffixes_and_binary()
  while true do
    local k = self:tag()
    if k == "." and self:tag(1) == "identifier" then
      self:next()
      self:next()
    elseif k == ".*" or k == ".?" then
      self:next()
    elseif k == "[" or k == "(" or k == "{" then
      self:skip_balanced()
    else
      break
    end
  end
  if BINARY[self:tag()] then
    local op = self:next()
    local before = self.src:byte(op.s) or 32
    local after = self.src:byte(op.e + 1) or 32
    if op.tag == "&" and after == 38 then invalid() end
    if is_ws_byte(before) ~= is_ws_byte(after) then invalid() end
    if op.tag == "keyword_catch" and self:tag() == "|" then
      self:next()
      self:expect("identifier")
      self:expect("|")
    end
    self:skip_expr()
  end
end

-- The expression under the cursor: a ZON node, or `unsupported`.
function P:expr()
  local t = self:peek()
  local tag = t.tag
  local first = t.s
  if tag == "-" then
    -- Negation: Zig's prefix `-`. The walk keeps a number's lexeme with
    -- the sign, `-inf` as a float, and refuses anything else — a second
    -- negation, a parenthesis, an identifier.
    self:next()
    local operand = self:expr()
    if operand.kind == "number" and not operand.negated and not operand.grouped then
      return { kind = "number", first = first, span = { first, operand.span[2] }, negated = true }
    elseif operand.kind == "ident" and operand.name == "inf" and not operand.grouped then
      return { kind = "number", first = first, span = { first, operand.span[2] }, text = "-inf", float = true, negated = true }
    end
    return { kind = "unsupported", first = first }
  end
  local node
  if tag == "number_literal" then
    self:next()
    node = { kind = "number", first = first, span = { t.s, t.e } }
  elseif tag == "string_literal" then
    self:next()
    node = { kind = "string", first = first, span = { t.s, t.e } }
  elseif tag == "multiline_string_literal_line" then
    local lines = {}
    while self:tag() == "multiline_string_literal_line" do lines[#lines + 1] = self:next() end
    node = { kind = "multiline", first = first, span = { t.s, lines[#lines].e }, lines = lines }
  elseif tag == "char_literal" then
    self:next()
    node = { kind = "char", first = first, span = { t.s, t.e } }
  elseif tag == "identifier" then
    self:next()
    node = { kind = "ident", first = first, span = { t.s, t.e }, name = self:text(t) }
  elseif tag == "(" then
    self:next()
    local inner = self:expr()
    self:expect(")")
    -- Grouped: the walk descends transparently; the span is the inner
    -- node's, but the comment scan starts at the `(`.
    node = inner
    node.first = first
    node.grouped = true
  elseif tag == "." and self:tag(1) == "identifier" then
    self:next()
    local name = self:next()
    node = { kind = "enum", first = first, span = { name.s, name.e }, tok = name }
  elseif tag == "." and self:tag(1) == "{" then
    node = self:init_list()
  elseif tag == "eof" or tag == "invalid" or tag == "doc_comment" or tag == "container_doc_comment"
    or tag == ")" or tag == "]" or tag == "}" or tag == "," then
    invalid()
  else
    self:skip_expr()
    return { kind = "unsupported", first = first }
  end
  -- A suffix or an operator after a ZON primary is Zig, not ZON.
  if self:continues() then
    self:skip_suffixes_and_binary()
    return { kind = "unsupported", first = first }
  end
  return node
end

-- `.{ … }`: field inits make a mapping, expressions a sequence, nothing
-- an empty mapping. A `.name = ` after an expression, or an expression
-- after a field, is Zig's error.
function P:init_list()
  local dot = self:next()
  local brace = self:next()
  local node = { kind = "container", first = dot.s, brace = brace.s, items = {} }
  local function closed()
    node.span = { dot.s, self.tokens[self.pos - 1].e }
    return node
  end
  local function is_field_init()
    return self:tag() == "." and self:tag(1) == "identifier" and self:tag(2) == "="
  end
  if is_field_init() then
    node.mapping = true
    while true do
      self:next() -- .
      local name = self:next()
      self:next() -- =
      node.items[#node.items + 1] = { name = name, value = self:expr() }
      local k = self:tag()
      if k == "," then
        self:next()
      elseif k == "}" then
        self:next()
        return closed()
      else
        invalid() -- a missing comma is Zig's warning, and a warning refuses
      end
      if self:eat("}") then return closed() end
      if not is_field_init() then invalid() end
    end
  end
  node.mapping = self:tag() == "}"
  while true do
    if self:eat("}") then return closed() end
    node.items[#node.items + 1] = { value = self:expr() }
    local k = self:tag()
    if k == "," then
      self:next()
    elseif k == "}" then
      self:next()
      return closed()
    else
      invalid()
    end
  end
end

local function parse_tree(src)
  local tokens = tokenize(src)
  for _, t in ipairs(tokens) do
    if t.tag == "invalid" then invalid() end
  end
  local p = setmetatable({ src = src, tokens = tokens, pos = 1 }, P)
  local root = p:expr()
  if p:tag() ~= "eof" then invalid() end
  return root
end

-- ── decoding, as `std.zig.string_literal` does it ─────────────────────────

local function utf8_encode(cp)
  if cp >= 0xD800 and cp <= 0xDFFF then return nil end
  if cp > 0x10FFFF then return nil end
  return utf8.char(cp)
end

-- The escape at `raw[i]` (a `\`): its value (a byte, or a codepoint when
-- `\u`) and the index after it, or nil when it does not decode.
local function escape_at(raw, i)
  local ch = raw:sub(i + 1, i + 1)
  if ch == "n" then return "\n", i + 2 end
  if ch == "r" then return "\r", i + 2 end
  if ch == "t" then return "\t", i + 2 end
  if ch == "\\" then return "\\", i + 2 end
  if ch == "'" then return "'", i + 2 end
  if ch == '"' then return '"', i + 2 end
  if ch == "x" then
    local hex = raw:sub(i + 2, i + 3)
    if not hex:match("^%x%x$") then return nil end
    return string.char(tonumber(hex, 16)), i + 4
  end
  if ch == "u" then
    if raw:sub(i + 2, i + 2) ~= "{" then return nil end
    local j = i + 3
    local hex = raw:match("^%x+", j)
    if not hex then return nil end
    j = j + #hex
    if raw:sub(j, j) ~= "}" then return nil end
    local cp = tonumber(hex, 16)
    if not cp or cp > 0x10FFFF then return nil end
    return cp, j + 1
  end
  return nil
end

-- A `"…"` literal, quotes included, decoded; nil when Zig would refuse it.
local function decode_string(raw)
  local out = {}
  local i = 2
  local n = #raw - 1
  while i <= n do
    local c = raw:sub(i, i)
    if c == "\\" then
      local v, j = escape_at(raw, i)
      if v == nil then return nil end
      if type(v) == "number" then
        v = utf8_encode(v)
        if v == nil then return nil end
      end
      out[#out + 1] = v
      i = j
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- A `'…'` literal: its codepoint, or nil.
local function decode_char(raw)
  if #raw < 3 then return nil end
  local inner = raw:sub(2, -2)
  if inner:sub(1, 1) == "\\" then
    local v, j = escape_at(inner, 1)
    if v == nil or j ~= #inner + 1 then return nil end
    -- A `\u{…}` here is any codepoint up to 0x10FFFF, a surrogate
    -- included: nothing encodes it, so nothing refuses it.
    if type(v) == "number" then return v end
    return v:byte()
  end
  local b = inner:byte(1)
  local len = b < 0x80 and 1 or (b >= 0xC0 and b < 0xE0) and 2 or (b >= 0xE0 and b < 0xF0) and 3 or (b >= 0xF0 and b < 0xF8) and 4 or nil
  if len == nil or #inner ~= len then return nil end
  local ok, cp = pcall(utf8.codepoint, inner, 1)
  if not ok then return nil end
  return cp
end

-- ── the walk, as `parser.zig` does it ─────────────────────────────────────
-- Comments come from the source gaps between nodes: `absorb(pos)` scans
-- `[scan_pos, pos)`, which holds only punctuation, whitespace and comments.

local W = {}
W.__index = W

local function is_float_lexeme(raw)
  if raw:find(".", 1, true) then return true end
  local body = raw:sub(1, 1) == "-" and raw:sub(2) or raw
  if body:match("^0[xX]") then return body:find("[pP]") ~= nil end
  return raw:find("[eE]") ~= nil
end

function W:absorb(pos)
  local src = self.src
  local i = self.scan_pos
  while i < pos do
    local c = src:byte(i + 1)
    if c == 10 then
      self.last_value = nil
      i = i + 1
    elseif c == 47 and src:byte(i + 2) == 47 then
      local s = i + 2
      local j = s
      while j < #src and src:byte(j + 1) ~= 10 do j = j + 1 end
      local text = src:sub(s + 1, j):match("^[ \t\r]*(.-)[ \t\r]*$")
      if self.last_value then
        local last = self.last_value
        if (last.kind == "mapping" or last.kind == "sequence") and last.span[1] < i
          and src:sub(last.span[1] + 1, i):find("\n", 1, true) then
          last:comment("dangling", text)
        else
          last:comment("trailing", text)
        end
        self.last_value = nil
      else
        self.pending[#self.pending + 1] = text
      end
      i = j
    else
      i = i + 1
    end
  end
  if i > self.scan_pos then self.scan_pos = i end
end

function W:claim(node, slot)
  if #self.pending == 0 then return end
  for _, t in ipairs(self.pending) do node:comment(slot, t) end
  self.pending = {}
end

-- A `// head` right after a container's `.{`, ending its line.
function W:open_trailing(built, node)
  local src = self.src
  local i = node.brace + 1
  while i < #src do
    local c = src:byte(i + 1)
    if c == 10 then return end
    if c == 32 or c == 9 or c == 13 then
      i = i + 1
    elseif c == 47 then
      if src:byte(i + 2) ~= 47 then return end
      local s = i + 2
      local j = s
      while j < #src and src:byte(j + 1) ~= 10 do j = j + 1 end
      built:comment("trailing", src:sub(s + 1, j):match("^[ \t\r]*(.-)[ \t\r]*$"))
      if j > self.scan_pos then self.scan_pos = j end
      return
    else
      return
    end
  end
end

function W:walk(node)
  local kind = node.kind
  if kind == "unsupported" then unsupported() end
  if kind == "container" then
    local built
    if node.mapping then
      built = fig.mapping(node.span, { duplicates = "keep" })
      self:open_trailing(built, node)
      for _, item in ipairs(node.items) do
        self:absorb(item.name.s)
        local raw = self.src:sub(item.name.s + 1, item.name.e)
        local name = raw
        if raw:sub(1, 2) == '@"' then
          name = decode_string(raw:sub(2))
          if name == nil then invalid() end
        end
        local key = fig.scalar("string", { item.name.s, item.name.e }, name)
        self:claim(key, "leading")
        self.scan_pos = item.name.e
        local value = self:walk(item.value)
        self.last_value = value
        self.scan_pos = value.span[2]
        built:put(fig.entry(key, value, { item.name.s, value.span[2] }))
      end
    else
      built = fig.sequence(node.span)
      self:open_trailing(built, node)
      for _, item in ipairs(node.items) do
        self:absorb(item.value.first)
        local value = self:walk(item.value)
        self:claim(value, "leading")
        self.last_value = value
        self.scan_pos = value.span[2]
        built:add(value)
      end
    end
    self:absorb(node.span[2])
    self:claim(built, "dangling")
    return built
  end
  local span = node.span
  if kind == "number" then
    local text = node.text or self.src:sub(span[1] + 1, span[2])
    local float = node.float or is_float_lexeme(text)
    return fig.scalar(float and "float" or "int", span, text)
  elseif kind == "ident" then
    local name = node.name
    if name == "true" or name == "false" then return fig.scalar("bool", span, name) end
    if name == "null" then return fig.scalar("null", span) end
    if name == "inf" or name == "nan" then return fig.scalar("float", span, name) end
    unsupported()
  elseif kind == "string" then
    local text = decode_string(self.src:sub(span[1] + 1, span[2]))
    if text == nil then invalid() end
    return fig.scalar("string", span, text)
  elseif kind == "multiline" then
    local parts = {}
    for _, line in ipairs(node.lines) do parts[#parts + 1] = self.src:sub(line.s + 3, line.e) end
    return fig.scalar("string", span, table.concat(parts, "\n"))
  elseif kind == "char" then
    local cp = decode_char(self.src:sub(span[1] + 1, span[2]))
    if cp == nil then invalid() end
    return fig.scalar("int", span, tostring(cp), { ext_kind = "char_literal" })
  elseif kind == "enum" then
    local raw = self.src:sub(span[1] + 1, span[2])
    local name = raw
    if raw:sub(1, 2) == '@"' then
      name = decode_string(raw:sub(2))
      if name == nil then invalid() end
    end
    return fig.scalar("string", span, name, { ext_kind = "enum_literal" })
  end
  unsupported()
end

function M.parse(_dialect, input)
  local tree = parse_tree(input)
  local w = setmetatable({ src = input, scan_pos = 0, pending = {}, last_value = nil }, W)
  w:absorb(tree.first)
  local root = w:walk(tree)
  w:claim(root, "leading")
  w.last_value = root
  w.scan_pos = root.span[2]
  w:absorb(#input)
  return root
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: every container broken one member per
-- line at four spaces a level with a trailing comma, `.{}` when empty;
-- comments where they were bound — a container's own trailing comment
-- after its `.{`, a member's leading above it, trailing after its comma,
-- dangling before the `}`. Without `pretty`, everything inline and no
-- comments at all.

local INDENT = "    "

local function is_bare_identifier(name)
  if name == "" then return false end
  if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then return false end
  return not KEYWORDS[name]
end

local STRING_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function string_inner(value)
  return (value:gsub('[%c"\\]', function(c)
    if STRING_ESCAPES[c] then return STRING_ESCAPES[c] end
    local b = c:byte()
    if b == 127 then return c end
    return string.format("\\x%02x", b)
  end))
end

local function write_string(w, value)
  w:put('"', string_inner(value), '"')
end

local function write_dot_name(w, name)
  w:put(".")
  if is_bare_identifier(name) then
    w:put(name)
  else
    w:put('@"', string_inner(name), '"')
  end
end

local function write_char_literal(w, text)
  local cp = text:match("^%d+$") and tonumber(text)
  if not cp then return w:put(text) end
  w:put("'")
  if cp == 39 then
    w:put("\\'")
  elseif cp == 92 then
    w:put("\\\\")
  elseif cp == 10 then
    w:put("\\n")
  elseif cp == 13 then
    w:put("\\r")
  elseif cp == 9 then
    w:put("\\t")
  elseif (cp >= 0x20 and cp <= 0x26) or (cp >= 0x28 and cp <= 0x5b) or (cp >= 0x5d and cp <= 0x7e) then
    w:put(string.char(cp))
  else
    w:put(string.format("\\u{%x}", cp))
  end
  w:put("'")
end

local Pr = {}
Pr.__index = Pr

function Pr:comments_on() return self.pretty end

function Pr:indent(depth)
  for _ = 1, depth do self.w:put(INDENT) end
end

function Pr:slash_lines(text, depth)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    self:indent(depth)
    local t = line:match("^[ \t]*(.-)[ \t]*$")
    self.w:put(t == "" and "//" or ("// " .. t), "\n")
  end
end

function Pr:leading(row, depth)
  if not self:comments_on() then return end
  for _, c in ipairs(row.leading) do self:slash_lines(c.text, depth) end
end

function Pr:trailing(row)
  if not self:comments_on() then return end
  local c = row.trailing[1]
  if not c then return end
  self.w:put(" //")
  if c.text ~= "" then self.w:put(" ", (c.text:gsub("\n", " "))) end
end

local function is_container(row)
  return row.kind == "mapping" or row.kind == "sequence"
end

function Pr:node(row, depth)
  local w = self.w
  local k = row.kind
  if k == "null" then
    w:put("null")
  elseif k == "bool" then
    w:put(row.text)
  elseif k == "int" or k == "float" then
    if row.ext_kind == "char_literal" then write_char_literal(w, row.text) else w:put(row.text) end
  elseif k == "string" then
    if row.ext_kind == "enum_literal" then write_dot_name(w, row.text or "") else write_string(w, row.text or "") end
  elseif k == "mapping" or k == "sequence" then
    self:container(row, depth)
  elseif k == "keyvalue" then
    if row.key.kind ~= "string" then error("a ZON field name must be a string", 0) end
    write_dot_name(w, row.key.text or "")
    w:put(" = ")
    self:node(row.value, depth)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as ZON", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function Pr:container(row, depth)
  local w = self.w
  local dangling = self:comments_on() and row.dangling or {}
  if #row.items == 0 and #dangling == 0 then
    w:put(".{}")
    self:trailing(row)
    return
  end
  if not self.pretty then
    w:put(".{ ")
    for i, item in ipairs(row.items) do
      if i > 1 then w:put(", ") end
      self:node(item, depth + 1)
    end
    w:put(" }")
    return
  end
  w:put(".{")
  self:trailing(row)
  w:put("\n")
  for _, item in ipairs(row.items) do
    local lead = item.kind == "keyvalue" and item.key or item
    local trail = item.kind == "keyvalue" and item.value or item
    self:leading(lead, depth + 1)
    self:indent(depth + 1)
    self:node(item, depth + 1)
    w:put(",")
    if not is_container(trail) then self:trailing(trail) end
    w:put("\n")
  end
  for _, c in ipairs(dangling) do self:slash_lines(c.text, depth + 1) end
  self:indent(depth)
  w:put("}")
end

function M.print(_dialect, t, options)
  local w = fig.writer(options)
  local pretty = true
  if options and options.pretty == false then pretty = false end
  local p = setmetatable({ w = w, pretty = pretty }, Pr)
  local root = t.byid(0)
  p:leading(root, 0)
  p:node(root, 0)
  if not is_container(root) then p:trailing(root) end
  w:put("\n")
  return w:string()
end

return M
