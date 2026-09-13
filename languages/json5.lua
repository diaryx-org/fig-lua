-- JSONC and JSON5, in Lua: the twins of fig's compiled `jsonc` and `json5`
-- dialects — one script, two dialects, as the compiled JSON module is one
-- parser with a dialect switch — row for row.
--
-- `fig lang check lua-jsonc --against jsonc <files…>` and `fig lang check
-- lua-json5 --against json5 <files…>` hold this script to the compiled
-- parser's node table on every file given, and this script is written
-- against `fig lang table -i jsonc` / `-i json5`, which print that table.
-- What the compiled dialects accept is stated in fig's
-- `src/languages/json/` (`tokenizer.zig`, `parser.zig`, `printer.zig`),
-- and this follows them function for function: the tokenizer runs over
-- the whole file first, then a state machine over its tokens. Strict JSON
-- is `json.lua`, written as a grammar; this is the compiled shape,
-- because the comments are what make these dialects, and the compiled
-- parser binds them by looking at the tokens around each one.
--
-- The shape, as the compiled parser builds it:
--
--   * JSONC is JSON with `//` and `/* */` comments; JSON5 adds unquoted
--     `identifier` keys (and `true`/`false`/`null` as keys), single-quoted
--     strings, the escapes `\x`, `\v`, `\0`, `\'`, any other `\c` as `c`,
--     a `\` before a line ending as a continuation, trailing commas,
--     `Infinity`/`NaN` (signed too) as `number_special` strings, `0x`
--     integers, `.5`, `5.`, `+1`, and `\v`/`\f` as whitespace;
--   * a container spans its brackets, an entry its key through its value;
--     a number keeps its lexeme and is a float when it has a `.` or an
--     exponent (a `0x` integer never); a duplicate key keeps both
--     entries;
--   * a comment that is the last thing on the line of the value just
--     finished trails it — or dangles on a container whose closing line
--     it is; one right after a `[` or `{` that ends its line trails the
--     container; any other waits and leads the next key, value or
--     container, or dangles on the container that closes with it still
--     waiting; what waits after the document is dropped. A comment's
--     text is trimmed; a block comment's style is `block`.
--
-- The refusals are the compiled parser's, in its words and at its
-- offsets: a tokenizer error where its cursor stopped, a parser error at
-- the start of the token it was dispatching (the document's end, for a
-- document that ended early). Nearly everything is `UnexpectedToken`, as
-- in strict JSON.

local M = {}

M.name = "lua-json5"
M.caps = { read = true, edit = true, serialize = true }
-- Beyond the core kinds, `null` and nothing else: every extended scalar
-- rides in a `$fig` envelope, JSON5's own `Infinity`/`NaN` included.
M.lossless = { null = true }
M.syntax = {
  comments = { style = "slashes", line = { open = "//" }, trailing = { open = "//" } },
  kv_sep = ": ",
  key_style = "json_quoted",
  empty_map_literal = "{}",
}
M.dialects = {
  -- The language's own name goes on its first dialect; the compiled
  -- dialects own `.json5` and `.jsonc`, and a compiled format's extension
  -- wins, so these are reached by `--lang lua-json5` / `--lang lua-jsonc`.
  { name = "lua-json5", extensions = { "json5" }, splice = "json_string", empty_doc_seed = "{}\n" },
  { name = "lua-jsonc", extensions = { "jsonc" }, splice = "json_string", empty_doc_seed = "{}\n" },
}
M.samples = {
  '{"a": 1, "b": [true, null, "s"], "c": {"d": 2.5}}\n',
  "// top\n[] // empty\n",
}
M.renderers = {}

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  UnexpectedToken = "unexpected token here; check for a missing comma, colon, key, or closing bracket/brace",
  UnexpectedEndOfInput = "the document ended before this value/token was complete",
  UnclosedString = "unclosed string; a JSON string cannot span multiple lines — add the closing quote, or escape the newline as `\\n`",
  LeadingZero = "a number cannot have a leading zero; write the digits without the padding, or quote it as a string to keep the padding (e.g. a zip code)",
  UnexpectedSlash = "a `/` here must start a `//` or `/* */` comment, and strict JSON has no comments at all — use a .jsonc/.json5 file, or remove it",
  UnclosedComment = "unclosed block comment; add the closing `*/`",
  InvalidUnicodeEscape = "invalid `\\u` escape; it needs exactly 4 hex digits (e.g. `\\u00e9`)",
}

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- Tokens are `{ kind=, s=, e= }` over 0-based byte offsets. A failure is
-- reported where the compiled tokenizer's cursor stopped.

local function is_digit(b) return b ~= nil and b >= 48 and b <= 57 end
local function is_hex(b) return b ~= nil and (is_digit(b) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)) end
local function is_ident_start(b)
  return b ~= nil and ((b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95 or b == 36)
end
local function is_ident_part(b) return is_ident_start(b) or is_digit(b) end
-- `std.ascii.isWhitespace`: space, tab, newline, return, vertical tab, form feed.
local function is_space(b) return b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12 end

local function tokenize(src, json5)
  local n = #src
  local i = 0
  local tokens = {}
  local function at(k) return src:byte(k + 1) end
  local function fail(message) fig.fail(message, i) end
  local function emit(kind, s, e)
    tokens[#tokens + 1] = { kind = kind, s = s, e = e }
    i = e
  end
  local function matches(word) return src:sub(i + 1, i + #word) == word end

  local function literal(word, kind)
    if not matches(word) then fail(MESSAGES.UnexpectedToken) end
    emit(kind, i, i + #word)
  end

  local function whitespace()
    local s = i
    while i < n and is_space(at(i)) do i = i + 1 end
    emit("whitespace", s, i)
  end

  local function identifier_or_keyword()
    local s = i
    while i < n and is_ident_part(at(i)) do i = i + 1 end
    local word = src:sub(s + 1, i)
    local kind = "identifier"
    if word == "true" then kind = "true_" elseif word == "false" then kind = "false_" elseif word == "null" then kind = "null_" end
    emit(kind, s, i)
  end

  local function string_token(delimiter)
    local s = i
    i = i + 1
    while i < n do
      local c = at(i)
      if c == delimiter then
        i = i + 1
        emit("string", s, i)
        return
      end
      if c == 92 then
        i = i + 1
        local escaped = at(i)
        if escaped == nil then fail(MESSAGES.UnclosedString) end
        if json5 then
          -- Any escape is consumed here and judged by the parser; a `\'`
          -- or a `\<newline>` must not end the string.
          i = i + 1
          if escaped == 13 and at(i) == 10 then i = i + 1 end
        elseif escaped == 34 or escaped == 92 or escaped == 47 or escaped == 98 or escaped == 102
          or escaped == 110 or escaped == 114 or escaped == 116 then
          i = i + 1
        elseif escaped == 117 then
          i = i + 1
          for _ = 1, 4 do
            local h = at(i)
            if h == nil then fail(MESSAGES.UnclosedString) end
            if not is_hex(h) then fail(MESSAGES.UnexpectedToken) end
            i = i + 1
          end
        else
          fail(MESSAGES.UnexpectedToken)
        end
      elseif c < 32 then
        fail(MESSAGES.UnexpectedToken)
      else
        i = i + 1
      end
    end
    fail(MESSAGES.UnclosedString)
  end

  local function digits()
    while i < n and is_digit(at(i)) do i = i + 1 end
  end

  local function number_json()
    local s = i
    if at(i) == 45 then i = i + 1 end
    local c = at(i)
    if c == nil then fail(MESSAGES.UnexpectedEndOfInput) end
    if c == 48 then
      i = i + 1
      if is_digit(at(i)) then fail(MESSAGES.LeadingZero) end
    elseif c >= 49 and c <= 57 then
      i = i + 1
      digits()
    else
      fail(MESSAGES.UnexpectedToken)
    end
    if at(i) == 46 then
      i = i + 1
      local f = at(i)
      if f == nil then fail(MESSAGES.UnexpectedEndOfInput) end
      if not is_digit(f) then fail(MESSAGES.UnexpectedToken) end
      digits()
    end
    local e = at(i)
    if e == 101 or e == 69 then
      i = i + 1
      local sign = at(i)
      if sign == 43 or sign == 45 then i = i + 1 end
      local x = at(i)
      if x == nil then fail(MESSAGES.UnexpectedEndOfInput) end
      if not is_digit(x) then fail(MESSAGES.UnexpectedToken) end
      digits()
    end
    emit("number", s, i)
  end

  -- An ES5 numeric literal: a sign, then `Infinity`, `NaN`, a `0x` integer,
  -- or a decimal with a leading or trailing point and an exponent. A
  -- leading zero before a digit stays refused.
  local function number_json5()
    local s = i
    if at(i) == 43 or at(i) == 45 then i = i + 1 end
    if matches("Infinity") then
      emit("number", s, i + 8)
      return
    end
    if matches("NaN") then
      emit("number", s, i + 3)
      return
    end
    if at(i) == 48 and (at(i + 1) == 120 or at(i + 1) == 88) then
      i = i + 2
      local hs = i
      while i < n and is_hex(at(i)) do i = i + 1 end
      if i == hs then fail(MESSAGES.UnexpectedToken) end
      emit("number", s, i)
      return
    end
    local seen = false
    if at(i) == 48 then
      i = i + 1
      seen = true
      if is_digit(at(i)) then fail(MESSAGES.LeadingZero) end
    else
      while i < n and is_digit(at(i)) do
        i = i + 1
        seen = true
      end
    end
    if at(i) == 46 then
      i = i + 1
      while i < n and is_digit(at(i)) do
        i = i + 1
        seen = true
      end
    end
    if not seen then fail(MESSAGES.UnexpectedToken) end
    local e = at(i)
    if e == 101 or e == 69 then
      i = i + 1
      local sign = at(i)
      if sign == 43 or sign == 45 then i = i + 1 end
      local xs = i
      digits()
      if i == xs then fail(MESSAGES.UnexpectedEndOfInput) end
    end
    emit("number", s, i)
  end

  local function comment()
    if i + 1 >= n then fail(MESSAGES.UnexpectedSlash) end
    local s = i
    local second = at(i + 1)
    if second == 47 then
      i = i + 2
      while i < n and at(i) ~= 10 and at(i) ~= 13 do i = i + 1 end
      emit("comment", s, i)
    elseif second == 42 then
      i = i + 2
      while i + 1 < n do
        if at(i) == 42 and at(i + 1) == 47 then
          i = i + 2
          emit("comment", s, i)
          return
        end
        i = i + 1
      end
      fail(MESSAGES.UnclosedComment)
    else
      fail(MESSAGES.UnexpectedSlash)
    end
  end

  if src:sub(1, 3) == "\239\187\191" then i = 3 end
  while i < n do
    local c = at(i)
    if json5 and is_ident_start(c) then
      identifier_or_keyword()
    elseif json5 and c == 39 then
      string_token(39)
    elseif json5 and (c == 43 or c == 46) then
      number_json5()
    elseif json5 and (c == 11 or c == 12) then
      whitespace()
    elseif c == 123 then
      emit("open_brace", i, i + 1)
    elseif c == 125 then
      emit("close_brace", i, i + 1)
    elseif c == 91 then
      emit("open_bracket", i, i + 1)
    elseif c == 93 then
      emit("close_bracket", i, i + 1)
    elseif c == 58 then
      emit("colon", i, i + 1)
    elseif c == 44 then
      emit("comma", i, i + 1)
    elseif c == 116 then
      literal("true", "true_")
    elseif c == 102 then
      literal("false", "false_")
    elseif c == 110 then
      literal("null", "null_")
    elseif c == 34 then
      string_token(34)
    elseif c == 47 then
      comment()
    elseif is_digit(c) or c == 45 then
      if json5 then number_json5() else number_json() end
    elseif c == 32 or c == 9 or c == 10 or c == 13 then
      whitespace()
    else
      fail(MESSAGES.UnexpectedToken)
    end
  end
  emit("end_of_file", n, n)
  return tokens
end

-- ── decoding ──────────────────────────────────────────────────────────────

local SIMPLE_ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- The text of a string token, quotes included. Returns the text, or nil
-- and the message the compiled parser refuses it with.
local function decode_string(slice, json5)
  local quote = slice:sub(1, 1)
  local valid_quote = quote == '"' or (json5 and quote == "'")
  if #slice < 2 or not valid_quote or slice:sub(-1) ~= quote then return nil, "UnclosedString" end
  local inner = slice:sub(2, -2)
  if not inner:find("\\", 1, true) then return inner end
  local out = {}
  local i = 1
  local n = #inner
  while i <= n do
    local c = inner:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      i = i + 1
      if i > n then return nil, "UnclosedString" end
      local e = inner:sub(i, i)
      if SIMPLE_ESCAPES[e] then
        out[#out + 1] = SIMPLE_ESCAPES[e]
      elseif e == "'" then
        if not json5 then return nil, "UnexpectedToken" end
        out[#out + 1] = "'"
      elseif e == "v" then
        if not json5 then return nil, "UnexpectedToken" end
        out[#out + 1] = "\11"
      elseif e == "0" then
        if not json5 then return nil, "UnexpectedToken" end
        out[#out + 1] = "\0"
      elseif e == "x" then
        if not json5 then return nil, "UnexpectedToken" end
        if i + 2 > n then return nil, "UnclosedString" end
        local hex = inner:sub(i + 1, i + 2)
        if not hex:match("^%x%x$") then return nil, "InvalidUnicodeEscape" end
        out[#out + 1] = utf8.char(tonumber(hex, 16))
        i = i + 2
      elseif e == "\n" then
        if not json5 then return nil, "UnexpectedToken" end
      elseif e == "\r" then
        if not json5 then return nil, "UnexpectedToken" end
        if inner:sub(i + 1, i + 1) == "\n" then i = i + 1 end
      elseif e == "u" then
        -- One UTF-16 unit in four hex digits; a surrogate pair joins;
        -- an unpaired surrogate keeps the whole string as written.
        if i + 4 > n then return nil, "UnclosedString" end
        local hex = inner:sub(i + 1, i + 4)
        if not hex:match("^%x%x%x%x$") then return nil, "InvalidUnicodeEscape" end
        local cp = tonumber(hex, 16)
        i = i + 4
        if cp >= 0xD800 and cp <= 0xDBFF then
          if i + 6 > n then return inner end
          if inner:sub(i + 1, i + 2) ~= "\\u" then return inner end
          local lo = inner:sub(i + 3, i + 6)
          if not lo:match("^%x%x%x%x$") then return nil, "InvalidUnicodeEscape" end
          local lcp = tonumber(lo, 16)
          if not (lcp >= 0xDC00 and lcp <= 0xDFFF) then return inner end
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lcp - 0xDC00)
          i = i + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          return inner
        end
        out[#out + 1] = utf8.char(cp)
      else
        if not json5 then return nil, "UnexpectedToken" end
        out[#out + 1] = e
      end
      i = i + 1
    end
  end
  return table.concat(out)
end

-- `Infinity`/`NaN`, optionally signed: a `number_special`, or nil.
local function special_number(raw)
  local body = raw
  local first = raw:sub(1, 1)
  if first == "+" or first == "-" then body = raw:sub(2) end
  if body == "Infinity" or body == "NaN" then return true end
  return false
end

local function number_kind(raw)
  local body = raw
  local first = raw:sub(1, 1)
  if first == "+" or first == "-" then body = raw:sub(2) end
  if body:match("^0[xX]") then return "int" end
  if raw:find(".", 1, true) then return "float" end
  if raw:find("[eE]") then return "float" end
  return "int"
end

-- ── the parser ────────────────────────────────────────────────────────────
-- The compiled state machine over the tokens; comments are bound as the
-- token loop meets them, by what stands around them.

local P = {}
P.__index = P

function P:fail(message, token) fig.fail(MESSAGES[message] or message, token.s) end

function P:text(t) return self.src:sub(t.s + 1, t.e) end

function P:claim_leading(node)
  if #self.pending == 0 then return end
  for _, c in ipairs(self.pending) do node:comment("leading", c.text, c.style) end
  self.pending = {}
end

function P:add_node(node)
  self:claim_leading(node)
  return node
end

function P:scalar_node(token)
  local raw = self:text(token)
  local k = token.kind
  if k == "null_" then return self:add_node(fig.scalar("null", { token.s, token.e })) end
  if k == "true_" or k == "false_" then return self:add_node(fig.scalar("bool", { token.s, token.e }, raw)) end
  if k == "string" then
    local text, err = decode_string(raw, self.json5)
    if text == nil then self:fail(err, token) end
    return self:add_node(fig.scalar("string", { token.s, token.e }, text))
  end
  if k == "number" or k == "identifier" then
    if special_number(raw) then
      return self:add_node(fig.scalar("string", { token.s, token.e }, raw, { ext_kind = "number_special" }))
    end
    if k == "identifier" then self:fail("UnexpectedToken", token) end
    return self:add_node(fig.scalar(number_kind(raw), { token.s, token.e }, raw))
  end
  self:fail("UnexpectedToken", token)
end

function P:open(kind, token)
  local node = kind == "object" and fig.mapping({ token.s, token.e }, { duplicates = "keep" }) or fig.sequence({ token.s, token.e })
  self:add_node(node)
  self.stack[#self.stack + 1] = { kind = kind, node = node, pending_key = nil }
  self.state = kind == "object" and "ExpectObjectKeyOrEnd" or "ExpectArrayValueOrEnd"
end

function P:close(token)
  if #self.stack == 0 then self:fail("UnexpectedToken", token) end
  local frame = table.remove(self.stack)
  frame.node.span[2] = token.e
  if #self.pending > 0 then
    for _, c in ipairs(self.pending) do frame.node:comment("dangling", c.text, c.style) end
    self.pending = {}
  end
  return frame.node
end

function P:begin_key(token)
  if token.kind ~= "string" and not self.json5 then self:fail("UnexpectedToken", token) end
  local text
  if token.kind == "string" then
    local err
    text, err = decode_string(self:text(token), self.json5)
    if text == nil then self:fail(err, token) end
  else
    text = self:text(token)
  end
  local key = self:add_node(fig.scalar("string", { token.s, token.e }, text))
  self.stack[#self.stack].pending_key = key
  self.state = "ExpectObjectColon"
end

function P:finish_value(value, token)
  self.last_value = value
  if #self.stack == 0 then
    self.root = value
    self.state = "ExpectEndOfFile"
    return
  end
  local frame = self.stack[#self.stack]
  if frame.kind == "array" then
    frame.node:add(value)
    self.state = "ExpectArrayCommaOrEnd"
  else
    local key = frame.pending_key
    if key == nil then self:fail("UnexpectedToken", token) end
    frame.pending_key = nil
    frame.node:put(fig.entry(key, value, { key.span[1], value.span[2] }))
    self.state = "ExpectObjectCommaOrEnd"
  end
end

local function is_value_token(kind)
  return kind == "null_" or kind == "true_" or kind == "false_" or kind == "string" or kind == "number" or kind == "identifier"
end

function P:value(token)
  local k = token.kind
  if k == "open_brace" then
    self:open("object", token)
  elseif k == "open_bracket" then
    self:open("array", token)
  elseif is_value_token(k) then
    self:finish_value(self:scalar_node(token), token)
  else
    self:fail("UnexpectedToken", token)
  end
end

local function is_key_token(kind)
  return kind == "string" or kind == "identifier" or kind == "true_" or kind == "false_" or kind == "null_"
end

function P:dispatch(token)
  local state = self.state
  local k = token.kind
  if state == "ExpectValue" or state == "ExpectObjectValue" then
    self:value(token)
  elseif state == "ExpectArrayValueOrEnd" then
    if k == "close_bracket" then self:finish_value(self:close(token), token) else self:value(token) end
  elseif state == "ExpectArrayCommaOrEnd" then
    if k == "close_bracket" then
      self:finish_value(self:close(token), token)
    elseif k == "comma" then
      self.state = self.json5 and "ExpectArrayValueOrEnd" or "ExpectValue"
    else
      self:fail("UnexpectedToken", token)
    end
  elseif state == "ExpectObjectKeyOrEnd" then
    if is_key_token(k) then
      self:begin_key(token)
    elseif k == "close_brace" then
      self:finish_value(self:close(token), token)
    else
      self:fail("UnexpectedToken", token)
    end
  elseif state == "ExpectObjectKey" then
    if is_key_token(k) then self:begin_key(token) else self:fail("UnexpectedToken", token) end
  elseif state == "ExpectObjectColon" then
    if k == "colon" then self.state = "ExpectObjectValue" else self:fail("UnexpectedToken", token) end
  elseif state == "ExpectObjectCommaOrEnd" then
    if k == "close_brace" then
      self:finish_value(self:close(token), token)
    elseif k == "comma" then
      self.state = self.json5 and "ExpectObjectKeyOrEnd" or "ExpectObjectKey"
    else
      self:fail("UnexpectedToken", token)
    end
  elseif state == "ExpectEndOfFile" then
    if k ~= "end_of_file" then self:fail("UnexpectedToken", token) end
  end
end

-- Whether the comment at `i` is the last content on its line: what follows
-- is a newline, a comma, a closer or the end. A value, a key or another
-- comment first on the same line means this one leads that instead.
function P:ends_line(i)
  local tokens = self.tokens
  for j = i + 1, #tokens do
    local t = tokens[j]
    if t.kind == "whitespace" then
      if self.src:sub(t.s + 1, t.e):find("\n", 1, true) then return true end
    elseif t.kind == "comma" or t.kind == "close_brace" or t.kind == "close_bracket" or t.kind == "end_of_file" then
      return true
    else
      return false
    end
  end
  return true
end

-- Whether the last significant token before `i`, on the same line, is a
-- `[` or `{`: a comment riding the line a container opened on.
function P:after_open_delimiter(i)
  local tokens = self.tokens
  for j = i - 1, 1, -1 do
    local t = tokens[j]
    if t.kind == "whitespace" then
      if self.src:sub(t.s + 1, t.e):find("\n", 1, true) then return false end
    elseif t.kind == "open_bracket" or t.kind == "open_brace" then
      return true
    else
      return false
    end
  end
  return false
end

-- Whether `node` is a container whose opener is on an earlier line than
-- `at`: a multi-line container whose close is on the comment's line.
function P:multiline_container(node, at)
  if node.kind ~= "mapping" and node.kind ~= "sequence" then return false end
  local open = node.span[1]
  if at <= open then return false end
  return self.src:sub(open + 1, at):find("\n", 1, true) ~= nil
end

function P:handle_comment(i)
  local token = self.tokens[i]
  local raw = self:text(token)
  local c
  if raw:sub(2, 2) == "*" then
    c = { text = raw:sub(3, -3):match("^[ \t\r\n]*(.-)[ \t\r\n]*$"), style = "block" }
  else
    c = { text = raw:sub(3):match("^[ \t\r]*(.-)[ \t\r]*$"), style = "line" }
  end
  if self.last_value and self:ends_line(i) then
    local node = self.last_value
    self.last_value = nil
    node:comment(self:multiline_container(node, token.s) and "dangling" or "trailing", c.text, c.style)
  elseif self:ends_line(i) and #self.stack > 0 and self:after_open_delimiter(i) then
    self.stack[#self.stack].node:comment("trailing", c.text, c.style)
  else
    self.pending[#self.pending + 1] = c
  end
end

local function parse(input, json5)
  local tokens = tokenize(input, json5)
  local p = setmetatable({
    src = input,
    json5 = json5,
    tokens = tokens,
    state = "ExpectValue",
    stack = {},
    pending = {},
    last_value = nil,
    root = nil,
  }, P)
  for i, token in ipairs(tokens) do
    if token.kind == "whitespace" then
      if input:sub(token.s + 1, token.e):find("\n", 1, true) then p.last_value = nil end
    elseif token.kind == "comment" then
      p:handle_comment(i)
    else
      p:dispatch(token)
    end
  end
  if p.root == nil then fig.fail(MESSAGES.UnexpectedToken, #input) end
  return p.root
end

function M.parse(dialect, input)
  return parse(input, dialect == "lua-json5")
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout, as `json.lua` has it — one element per
-- line at `indent` spaces a level when `pretty`, nothing but the tokens
-- otherwise — plus what the dialects add: comments (leading above a
-- member, trailing after its comma, a container's own after its opener,
-- dangling before its close; `pretty` only), and in JSON5 a bare
-- identifier key, `Infinity`/`NaN` as written, and the number spellings
-- JSON5 reads (`0xC8`, `.5`, `+1`). A number no JSON can read is written
-- as decimal.

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
  return name:match("^[A-Za-z_$][A-Za-z0-9_$]*$") ~= nil
end

-- Whether a format that spells `s` reads `raw` back as the same number.
local function spellable(raw, s)
  local body = raw
  local first = raw:sub(1, 1)
  if first == "+" or first == "-" then
    if first == "+" and not s.plus then return false end
    body = raw:sub(2)
  end
  if body == "" then return false end
  if not s.underscores and body:find("_", 1, true) then return false end
  if #body >= 2 and body:sub(1, 1) == "0" then
    local r = body:sub(2, 2):lower()
    if r == "x" then return s.hex == true end
    if r == "o" then return s.octal == true end
    if r == "b" then return s.binary == true end
  end
  if not s.bare_dot and (body:sub(1, 1) == "." or body:sub(-1) == ".") then return false end
  if not s.leading_zero then
    local int_end = (body:find("[%.eE]") or (#body + 1)) - 1
    if int_end > 1 and body:sub(1, 1) == "0" then return false end
  end
  return true
end

-- `raw` as a decimal lexeme every format reads: radix converted, `_` and
-- `+` dropped, bare dots padded, leading zeros stripped.
local function canonical_number(raw)
  local out = {}
  local s = raw
  if s:sub(1, 1) == "-" then
    out[#out + 1] = "-"
    s = s:sub(2)
  elseif s:sub(1, 1) == "+" then
    s = s:sub(2)
  end
  if #s >= 2 and s:sub(1, 1) == "0" and s:sub(2, 2):lower():match("[xob]") then
    local base = ({ x = 16, o = 8, b = 2 })[s:sub(2, 2):lower()]
    local digits = s:sub(3):gsub("_", "")
    local v = tonumber(digits, base)
    if v and digits ~= "" and math.type(v) == "integer" then
      out[#out + 1] = tostring(v)
    else
      out[#out + 1] = s
    end
    return table.concat(out)
  end
  local e_idx = s:find("[eE]")
  local mantissa = e_idx and s:sub(1, e_idx - 1) or s
  local exponent = e_idx and s:sub(e_idx) or ""
  local dot = mantissa:find(".", 1, true)
  local int_part = dot and mantissa:sub(1, dot - 1) or mantissa
  local int_digits = int_part:gsub("_", ""):gsub("^0+", "")
  out[#out + 1] = int_digits == "" and "0" or int_digits
  if dot then
    local frac = mantissa:sub(dot + 1):gsub("_", "")
    out[#out + 1] = "." .. (frac == "" and "0" or frac)
  end
  out[#out + 1] = (exponent:gsub("_", ""))
  return table.concat(out)
end

local JSON_SPELLING = {}
local JSON5_SPELLING = { hex = true, bare_dot = true, plus = true }

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
    if row.ext_kind == "char_literal" then
      w:put(row.text)
    else
      local raw = row.text or ""
      w:put(spellable(raw, self.json5 and JSON5_SPELLING or JSON_SPELLING) and raw or canonical_number(raw))
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
  local p = setmetatable({ w = w, json5 = dialect == "lua-json5" }, Pr)
  local root = t.byid(0)
  p:leading(root, 0)
  p:node(root, 0)
  if not is_container(root) then p:trailing(root) end
  w:put("\n")
  return w:string()
end

return M
