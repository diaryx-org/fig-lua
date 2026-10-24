-- YAML, in Lua: the twin of fig's compiled `yaml` format — YAML 1.2
-- with the 1.1 tag repository as a second dialect.
--
-- The contract is the format and the table, not the compiled parser's
-- code: `fig lang table -i yaml` prints the node table a document makes,
-- and this script is held to it row for row — kinds, text, spans,
-- anchors, tags, markers, separators, comments with their slot and
-- style, and the `%TAG` directives. `fig lang check lua-yaml --against
-- yaml <files…>` is that check on any file. The printer is held to the
-- compiled printer's bytes: block style, a flow form where a collection
-- fits the width.
--
-- What the format is — the indentation structure, the flow collections,
-- the block scalars with their indicators, anchors, tags, directives —
-- is stated here in full, because that is the format. What is not the
-- format is not: this refuses every document the compiled format
-- refuses, but in its own words and at its own offsets.
--
-- The shape of the table:
--
--   * a block mapping spans its first key through its last value; a
--     block sequence its first `-` (recorded as each item's `marker`)
--     through its last item; a flow collection its brackets; a `key:
--     value` entry spans the key through the value with the `:` as its
--     `sep` (none for an explicit `? key` entry, whose value `:` is on a
--     line of its own); an empty value is a null spanning nothing after
--     the `:`; a node's span begins at its first property (`&a !t x` is
--     one node);
--   * plain scalars resolve by the 1.2 core schema (`null`, `true`,
--     numbers; everything else a string), or by the 1.1 tag repository
--     for the `lua-yaml-1.1` dialect; a quoted or block scalar is a
--     string, decoded; an int or float keeps its lexeme;
--   * a tag is kept verbatim (`!!str`, `!foo`, `!e!bar`) with its span;
--     an anchor its name and span; an alias is a node of its own,
--     naming the anchor, which must be defined earlier;
--   * a comment leads the next key, item or value, trails the value on
--     its line (or the entry, when the value is a block below), or
--     dangles on the root at the end; a comment above a collection
--     leads its first key or item;
--   * a `%TAG` directive is recorded (`directives`) and its handle may
--     be used by a tag; a `%YAML` directive is checked and dropped; a
--     second document is refused.
--


local M = {}

M.name = "lua-yaml"
M.caps = { read = true, edit = true, serialize = true, references = true }
-- The core schema has a `null` and none of the extended scalars.
M.lossless = { null = true }
M.syntax = {
  comments = { line = { open = "#" }, trailing = { open = "#" } },
  merge_key = "<<",
  kv_sep = ": ",
  empty_map_literal = "",
  single_line_block_mapping = true,
}
M.dialects = {
  -- The compiled format owns `.yaml`/`.yml`, and a compiled format's
  -- extension wins, so this is reached by `--lang lua-yaml`. The 1.1
  -- dialect differs only in how a plain scalar resolves; the compiled
  -- format selects it with `--spec 1.1`, which a runtime dialect has no
  -- row for, so it is a second dialect, reached by name.
  { name = "lua-yaml", extensions = { "yaml", "yml" }, splice = "literal", empty_doc_seed = "" },
  { name = "lua-yaml-1.1", extensions = {}, splice = "literal", empty_doc_seed = "" },
}
M.samples = {
  "a: 1\nb:\n  - x\n  - y\nc:\n  d: true\n",
  "{a: 1, b: [2, 3]}\n",
}
M.renderers = {}

local DT = require("fig.datetime")
local N = require("fig.number")

local byte, sub, find, concat = string.byte, string.sub, string.find, table.concat

-- The byte at 0-based offset `i` of `s`, or nil past its end.
local function at(s, i) return byte(s, i + 1) end

local SP, TAB, NL, CR = 32, 9, 10, 13
local HASH, COLON, DASH, QUEST, COMMA = 35, 58, 45, 63, 44
local LBRACK, RBRACK, LBRACE, RBRACE = 91, 93, 123, 125
local SQ, DQ, PIPE, GT, BANG, AMP, STAR, PCT, DOT = 39, 34, 124, 62, 33, 38, 42, 37, 46
local BSLASH, LT = 92, 60

local function is_blank(c) return c == SP or c == TAB end

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- YAML is read a line at a time, because its structure is indentation.
-- Every token is `{kind=, s=, e=}` over 0-based offsets; an
-- `indent`/`dedent`/`newline` is structural, the rest is content, and
-- `block_scalar` is the raw body of a block scalar.

local T = {}
T.__index = T

local function tokenizer(src)
  return setmetatable({
    src = src, n = #src, i = 0, tokens = {},
    pending_block = nil, flow_depth = 0, flow_open_indent = 0, flow_root = false,
  }, T)
end

function T:add(kind, s, e)
  self.tokens[#self.tokens + 1] = { kind = kind, s = s, e = e }
end

-- The exclusive end of a line's content given the position of its `\n`
-- (or the source's end): a trailing `\r` is trimmed.
local function trim_cr(src, start, nl)
  if nl > start and at(src, nl - 1) == CR then return nl - 1 end
  return nl
end

-- A plain scalar never ends in a blank: trailing spaces and tabs before a
-- comment or the line's end are not its text (`a: 1\t# c` is `1`).
local function trim_right_blanks(src, start, e)
  while e > start and is_blank(at(src, e - 1)) do e = e - 1 end
  return e
end

local function whitespace_end(src, start, line_end)
  local e = start
  while e < line_end and is_blank(at(src, e)) do e = e + 1 end
  return e
end

-- True when the byte after `i` is blank or `i` is the last byte of the line.
local function followed_by_blank(src, i, line_end)
  return i + 1 >= line_end or is_blank(at(src, i + 1))
end

-- True when `col` is the content column of one of the `- ` that begin the
-- line whose first dash is at `entry_dash`, in column `dash_col`: the column
-- just past the first dash, and for a compact nested sequence (`- - - a`)
-- past each later one. Content after the last dash ends the walk.
local function entry_content_column(src, entry_dash, dash_col, col)
  if not entry_dash then return false end
  local c = entry_dash
  local line_start = c - dash_col
  local line_end = find(src, "\n", c + 1, true)
  line_end = line_end and line_end - 1 or #src
  while c < line_end and at(src, c) == DASH and followed_by_blank(src, c, line_end) do
    c = c + 1
    while c < line_end and at(src, c) == SP do c = c + 1 end
    if c == line_end then return false end
    if c - line_start == col then return true end
  end
  return false
end

-- A `:` is a value indicator when followed by blank/EOL, or in flow by a
-- flow indicator.
local function colon_is_indicator(src, i, line_end, flow)
  if followed_by_blank(src, i, line_end) then return true end
  if not flow then return false end
  local c = at(src, i + 1)
  return c == COMMA or c == RBRACK or c == RBRACE
end

local function scalar_end(src, start, line_end, flow)
  local e = start
  while e < line_end do
    local c = at(src, e)
    if c == COLON then
      if colon_is_indicator(src, e, line_end, flow) then break end
    elseif c == HASH then
      if e > start and is_blank(at(src, e - 1)) then break end
    elseif c == COMMA or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE then
      if flow then break end
    end
    e = e + 1
  end
  return e
end

-- Just past a tag beginning at `start`: the verbatim `!<...>` to its `>`,
-- or a shorthand to blank/EOL/flow indicator. nil for a malformed
-- verbatim tag.
local function tag_end(src, start, line_end)
  local e = start + 1
  if e < line_end and at(src, e) == LT then
    e = e + 1
    local verbatim_start = e
    while e < line_end and at(src, e) ~= GT do e = e + 1 end
    if e >= line_end or e == verbatim_start then return nil end
    return e + 1
  end
  while e < line_end do
    local c = at(src, e)
    if c == SP or c == TAB or c == COMMA or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE then break end
    e = e + 1
  end
  return e
end

local function anchor_name_end(src, start, line_end)
  local e = start
  while e < line_end do
    local c = at(src, e)
    if c == SP or c == TAB or c == COMMA or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE then break end
    e = e + 1
  end
  return e
end

local function tag_separated(src, e, line_end, flow)
  if e >= line_end then return true end
  local c = at(src, e)
  if c == SP or c == TAB then return true end
  if c == COMMA or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE then return flow end
  return false
end

-- Just past a block header's indicators, or nil when what follows them is
-- not a comment.
local function block_header_end(src, start, line_end)
  local i = start + 1
  local seen_chomp, seen_indent = false, false
  while i < line_end do
    local c = at(src, i)
    if c == 43 or c == DASH then
      if seen_chomp then return nil end
      seen_chomp = true
    elseif c >= 49 and c <= 57 then
      if seen_indent then return nil end
      seen_indent = true
    else
      break
    end
    i = i + 1
  end
  local indicators_end = i
  while i < line_end and is_blank(at(src, i)) do i = i + 1 end
  if i < line_end then
    if at(src, i) ~= HASH or i == indicators_end then return nil end
  end
  return indicators_end
end

local function explicit_indent(src, start, header_end)
  for i = start + 1, header_end - 1 do
    local c = at(src, i)
    if c >= 49 and c <= 57 then return c - 48 end
  end
  return nil
end

local function plain_continuation_start(c)
  return not (c == HASH or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE or c == COMMA
    or c == SQ or c == DQ or c == AMP or c == STAR or c == BANG or c == PIPE or c == GT
    or c == 64 or c == 96 or c == PCT)
end

-- The line at `pos`: where its content begins (past the leading
-- spaces), where it ends (before its `\r\n` or `\n`), and where the next
-- line begins.
function T:line_at(pos)
  local src = self.src
  local nl = find(src, "\n", pos + 1, true)
  local e = trim_cr(src, pos, nl and (nl - 1) or self.n)
  local content_start = pos
  while content_start < e and at(src, content_start) == SP do content_start = content_start + 1 end
  return { start = pos, content_start = content_start, e = e, newline_end = nl or self.n }
end

function T:get_line()
  if self.i >= self.n then return nil end
  local line = self:line_at(self.i)
  self.i = line.newline_end
  return line
end

function T:line_all_ws(line)
  local src = self.src
  for i = line.content_start, line.e - 1 do
    if not is_blank(at(src, i)) then return false end
  end
  return true
end

-- A `---`/`...` occupying its own column-0 line.
function T:doc_marker(line)
  local src = self.src
  local cs = line.content_start
  if line.e - cs < 3 then return nil end
  local c = at(src, cs)
  if c ~= DASH and c ~= DOT then return nil end
  if at(src, cs + 1) ~= c or at(src, cs + 2) ~= c then return nil end
  if cs + 3 ~= line.e and not is_blank(at(src, cs + 3)) then return nil end
  return c == DASH and "doc_start" or "doc_end"
end

function T:doc_marker_at(pos)
  local src = self.src
  if pos + 3 > self.n then return false end
  local c = at(src, pos)
  if c ~= DASH and c ~= DOT then return false end
  if at(src, pos + 1) ~= c or at(src, pos + 2) ~= c then return false end
  local after = at(src, pos + 3)
  return after == nil or after == NL or after == CR or is_blank(after)
end

function T:line_is_property_only(line)
  if self.flow_depth > 0 then return false end
  local src = self.src
  local i = line.content_start
  local saw = false
  while i < line.e do
    local c = at(src, i)
    if c == SP or c == TAB then
      i = i + 1
    elseif c == HASH then
      return saw
    elseif c == AMP then
      local e = anchor_name_end(src, i + 1, line.e)
      if e == i + 1 then return false end
      i = e
      saw = true
    elseif c == BANG then
      local e = tag_end(src, i, line.e)
      if not e then return false end
      i = e
      saw = true
    else
      return false
    end
  end
  return saw
end

function T:tab_indented_structure(line)
  local src = self.src
  local cs = line.content_start
  if cs >= line.e or at(src, cs) ~= TAB then return false end
  local ws = cs
  while ws < line.e and is_blank(at(src, ws)) do ws = ws + 1 end
  if ws >= line.e then return false end
  local fc = at(src, ws)
  if fc == DASH and (ws + 1 >= line.e or is_blank(at(src, ws + 1))) then return true end
  local se = scalar_end(src, ws, line.e, false)
  return se < line.e and at(src, se) == COLON
end

-- What is left of the line `pos` falls in, as a line of its own.
function T:remainder_line(pos)
  local line = self:line_at(pos)
  line.content_start = pos
  return line
end

function T:column_of(pos)
  local src = self.src
  local i = pos
  while i > 0 and at(src, i - 1) ~= NL do i = i - 1 end
  return pos - i
end

function T:preceded_only_by_trivia()
  for _, t in ipairs(self.tokens) do
    local k = t.kind
    if not (k == "doc_start" or k == "newline" or k == "whitespace" or k == "comment"
      or k == "tag" or k == "anchor" or k == "directive") then
      return false
    end
  end
  return true
end

-- The owning key/dash column of a block header on a line of its own.
function T:deferred_owner_indent()
  local toks = self.tokens
  local idx = #toks
  while idx > 0 do
    local k = toks[idx].kind
    if k == "whitespace" or k == "newline" or k == "comment" or k == "indent" or k == "dedent"
      or k == "tag" or k == "anchor" then
      idx = idx - 1
    elseif k == "colon" then
      local j = idx - 1
      while j > 0 do
        local kk = toks[j].kind
        if kk == "whitespace" or kk == "comment" then j = j - 1 else break end
      end
      if j == 0 then return nil end
      return self:column_of(toks[j].s)
    elseif k == "dash" then
      return self:column_of(toks[idx].s)
    else
      return nil
    end
  end
  return nil
end

function T:json_key_colon()
  if self.flow_depth == 0 then return false end
  local toks = self.tokens
  local idx = #toks
  while idx > 0 do
    local k = toks[idx].kind
    if k == "whitespace" or k == "newline" or k == "comment" then idx = idx - 1 else break end
  end
  if idx == 0 then return false end
  local prev = toks[idx]
  if prev.kind == "flow_seq_end" or prev.kind == "flow_map_end" then return true end
  if prev.kind == "scalar" then
    local c = at(self.src, prev.s)
    return prev.e > prev.s and (c == DQ or c == SQ)
  end
  return false
end

function T:open_flow(line)
  self.flow_open_indent = line.content_start - line.start
  self.flow_root = self:preceded_only_by_trivia()
end

function T:add_scalar(s, e)
  local te = trim_right_blanks(self.src, s, e)
  if te > s then self:add("scalar", s, te) end
end

-- The trimmed end of a plain scalar inside flow, which may fold across
-- lines.
function T:flow_plain_end(start)
  local src, n = self.src, self.n
  local i = start
  local last_content = start
  while i < n do
    local c = at(src, i)
    if c == NL then
      if self:doc_marker_at(i + 1) then break end
      i = i + 1
      while i < n and (at(src, i) == SP or at(src, i) == TAB) do i = i + 1 end
      if i < n and at(src, i) == HASH then break end
    elseif c == COMMA or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE then
      break
    elseif c == CR then
      i = i + 1
    elseif c == COLON then
      local nx = at(src, i + 1)
      if nx == nil or nx == SP or nx == TAB or nx == NL or nx == CR or nx == COMMA or nx == RBRACK or nx == RBRACE then break end
      i = i + 1
      last_content = i
    elseif c == HASH then
      if i > start and is_blank(at(src, i - 1)) then break end
      i = i + 1
      last_content = i
    else
      i = i + 1
      if not is_blank(c) then last_content = i end
    end
  end
  return last_content
end

-- Whether a block plain scalar continues onto more-indented lines; the
-- trimmed end of the last such line and that line, or nil. Sets `i` past
-- the last continuation line.
function T:gather_plain_continuation(line, floor)
  local src, n = self.src, self.n
  local probe = line.newline_end
  local result = nil
  while probe < n do
    local ln = self:line_at(probe)
    local line_start, spaces, e, newline_end = ln.start, ln.content_start, ln.e, ln.newline_end
    local ws = line_start
    while ws < e and is_blank(at(src, ws)) do ws = ws + 1 end
    if ws == e then
      probe = newline_end
    else
      if floor ~= nil and spaces - line_start <= floor then break end
      local fc = at(src, ws)
      if fc == HASH then break end
      if (fc == DASH or fc == QUEST or fc == COLON) and (ws + 1 >= e or is_blank(at(src, ws + 1))) then break end
      local se = scalar_end(src, ws, e, false)
      if se ~= e then
        if at(src, se) == HASH then
          result = { content_end = trim_right_blanks(src, ws, se), last_line = ln }
        end
        break
      end
      result = { content_end = trim_right_blanks(src, ws, e), last_line = ln }
      probe = newline_end
    end
  end
  if result then self.i = result.last_line.newline_end end
  return result
end

-- A plain scalar from `start`; returns the (possibly advanced) line and
-- the cursor after it. `at_content_start` is false afterwards.
function T:handle_plain(start, line)
  local src = self.src
  local flow = self.flow_depth > 0
  if flow then
    local fend = self:flow_plain_end(start)
    if fend > start then self:add("scalar", start, fend) end
    if fend > line.e then
      line = self:remainder_line(fend)
      self.i = line.newline_end
    end
    return line, fend
  end
  local e = scalar_end(src, start, line.e, false)
  if e == line.e and plain_continuation_start(at(src, start)) then
    local indent = line.content_start - line.start
    local floor
    if self:preceded_only_by_trivia() and start == line.content_start then
      floor = nil
    elseif start == line.content_start then
      floor = indent > 0 and indent - 1 or 0
    else
      floor = indent
    end
    local g = self:gather_plain_continuation(line, floor)
    if g then
      self:add("scalar", start, g.content_end)
      return g.last_line, g.last_line.e
    end
  end
  self:add_scalar(start, e)
  return line, e
end

-- The end of a quoted scalar beginning at `start`, across line breaks;
-- each continuation line is checked against `floor`.
function T:multiline_quoted_end(start, floor)
  local src, n = self.src, self.n
  local double = at(src, start) == DQ
  local i = start + 1
  while i < n do
    local c = at(src, i)
    if c == NL then
      local line_start = i + 1
      if self:doc_marker_at(line_start) then fig.fail("this quoted string is never closed; a document marker line ends it", start) end
      local spaces = line_start
      while spaces < n and at(src, spaces) == SP do spaces = spaces + 1 end
      local ws = line_start
      while ws < n and is_blank(at(src, ws)) do ws = ws + 1 end
      local wc = at(src, ws)
      local blank = ws >= n or wc == NL or wc == CR
      if not blank and floor ~= nil and spaces - line_start <= floor then fig.fail("a quoted string continued on the next line must stay indented past its block", spaces) end
      i = i + 1
    elseif double then
      if c == BSLASH then
        if at(src, i + 1) == NL then i = i + 1 else i = i + 2 end
      elseif c == DQ then
        return i + 1
      else
        i = i + 1
      end
    else
      if c == SQ then
        if at(src, i + 1) == SQ then
          i = i + 2
        else
          return i + 1
        end
      else
        i = i + 1
      end
    end
  end
  fig.fail("this quoted string is never closed", start)
end

function T:flush_pending_block()
  local info = self.pending_block
  if not info then return end
  self.pending_block = nil
  self:consume_block_body(info)
end

-- The indented body of a block scalar, as one `block_scalar` token.
function T:consume_block_body(info)
  local src, n = self.src, self.n
  local body_start = self.i
  local content_indent = info.explicit_indent and (info.header_indent + info.explicit_indent) or nil
  local max_leading_blank = 0
  local min_blank_tab = nil
  local last_end = body_start
  while self.i < n do
    local ln = self:line_at(self.i)
    local line_start, spaces, e, newline_end = ln.start, ln.content_start, ln.e, ln.newline_end
    local ws = line_start
    while ws < e and is_blank(at(src, ws)) do ws = ws + 1 end
    local blank = ws == e
    local indent = spaces - line_start
    if blank then
      if content_indent == nil then
        if ws > spaces and (info.root or indent > info.header_indent) then
          if max_leading_blank > indent then fig.fail("a blank line in this block scalar is indented past its first content line", line_start) end
          content_indent = indent
        else
          if ws > spaces then
            local tab_col = spaces - line_start
            if min_blank_tab == nil or tab_col < min_blank_tab then min_blank_tab = tab_col end
          end
          if indent > max_leading_blank then max_leading_blank = indent end
        end
      end
    else
      if info.root and indent == 0 and self:doc_marker_at(line_start) then break end
      if content_indent ~= nil then
        if indent < content_indent then break end
      else
        if not info.root and indent <= info.header_indent then break end
        if max_leading_blank > indent then fig.fail("a blank line in this block scalar is indented past its first content line", line_start) end
        if min_blank_tab ~= nil and min_blank_tab < indent then fig.fail("a tab indents this block scalar; YAML indentation is spaces", line_start) end
        content_indent = indent
      end
    end
    self.i = newline_end
    last_end = newline_end
  end
  if content_indent == nil and min_blank_tab ~= nil then fig.fail("a tab indents this block scalar; YAML indentation is spaces", body_start) end
  if last_end > body_start then self:add("block_scalar", body_start, last_end) end
end

function T:tokenize_line_content(line_in)
  local src = self.src
  local line = line_in
  local cursor = line.content_start
  local at_content_start = true
  local block_owner_indent = line.content_start - line.start
  local node_start = line.content_start
  local flow
  -- Whatever is not an indicator here is the start of a plain scalar.
  local function plain()
    line, cursor = self:handle_plain(cursor, line)
    at_content_start = false
  end

  while cursor < line.e do
    local c = at(src, cursor)
    if at_content_start and c ~= SP and c ~= TAB then node_start = cursor end
    flow = self.flow_depth > 0

    if c == SP or c == TAB then
      local e = whitespace_end(src, cursor, line.e)
      self:add("whitespace", cursor, e)
      cursor = e
    elseif c == HASH then
      if cursor == line.content_start or is_blank(at(src, cursor - 1)) then
        self:add("comment", cursor, line.e)
        return
      end
      plain()
    elseif c == COLON then
      if colon_is_indicator(src, cursor, line.e, flow) or self:json_key_colon() then
        if not flow and node_start >= line.start then block_owner_indent = node_start - line.start end
        self:add("colon", cursor, cursor + 1)
        cursor = cursor + 1
        at_content_start = true
      else
        plain()
      end
    elseif c == LBRACK or c == LBRACE then
      if self.flow_depth == 0 then self:open_flow(line) end
      self:add(c == LBRACK and "flow_seq_start" or "flow_map_start", cursor, cursor + 1)
      self.flow_depth = self.flow_depth + 1
      cursor = cursor + 1
      at_content_start = false
    elseif c == RBRACK or c == RBRACE then
      self:add(c == RBRACK and "flow_seq_end" or "flow_map_end", cursor, cursor + 1)
      if self.flow_depth > 0 then self.flow_depth = self.flow_depth - 1 end
      cursor = cursor + 1
      at_content_start = false
    elseif c == COMMA then
      if flow then
        self:add("comma", cursor, cursor + 1)
        cursor = cursor + 1
        at_content_start = false
      else
        plain()
      end
    elseif c == SQ or c == DQ then
      local floor
      if self:preceded_only_by_trivia() or cursor == line.content_start then
        floor = nil
      else
        floor = line.content_start - line.start
      end
      local e = self:multiline_quoted_end(cursor, floor)
      if e > line.e then
        self:add("scalar", cursor, e)
        line = self:remainder_line(e)
        self.i = line.newline_end
        cursor = e
        at_content_start = false
      else
        self:add_scalar(cursor, e)
        cursor = e
        at_content_start = false
      end
    elseif c == PIPE or c == GT then
      if not flow then
        local hdr_end = block_header_end(src, cursor, line.e)
        if hdr_end then
          local root = self:preceded_only_by_trivia()
          local owner
          if cursor == line.content_start then
            owner = self:deferred_owner_indent() or block_owner_indent
          else
            owner = block_owner_indent
          end
          self:add("block_header", cursor, hdr_end)
          local rest = hdr_end
          while rest < line.e and is_blank(at(src, rest)) do rest = rest + 1 end
          if rest < line.e and at(src, rest) == HASH then self:add("comment", rest, line.e) end
          self.pending_block = { header_indent = owner, explicit_indent = explicit_indent(src, cursor, hdr_end), root = root }
          return
        end
        fig.fail("a `|` or `>` header takes one indentation digit, one `+` or `-`, then a comment", cursor)
      end
      plain()
    elseif c == DASH then
      if not flow and at_content_start and followed_by_blank(src, cursor, line.e) then
        if cursor > line.content_start and at(src, cursor - 1) == TAB then fig.fail("a tab indents this `-` item; YAML indentation is spaces", cursor) end
        block_owner_indent = cursor - line.start
        self:add("dash", cursor, cursor + 1)
        cursor = cursor + 1
        at_content_start = true
      else
        plain()
      end
    elseif c == QUEST then
      if (flow or at_content_start) and followed_by_blank(src, cursor, line.e) then
        self:add("explicit_key", cursor, cursor + 1)
        cursor = cursor + 1
      else
        plain()
      end
    elseif c == BANG then
      if flow or at_content_start then
        local e = tag_end(src, cursor, line.e)
        if e then
          if not tag_separated(src, e, line.e, flow) then fig.fail("a tag must be followed by a space, a newline, or a flow indicator", e) end
          self:add("tag", cursor, e)
          cursor = e
        else
          fig.fail("this is not a tag: a `!<...>` tag needs a name and a closing `>`", cursor)
        end
      else
        plain()
      end
    elseif c == AMP then
      if flow or at_content_start then
        local e = anchor_name_end(src, cursor + 1, line.e)
        if e == cursor + 1 or not tag_separated(src, e, line.e, flow) then fig.fail("an `&` anchor needs a name, then a space", cursor) end
        self:add("anchor", cursor, e)
        cursor = e
      else
        plain()
      end
    elseif c == STAR then
      if flow or at_content_start then
        local e = anchor_name_end(src, cursor + 1, line.e)
        if e == cursor + 1 or not tag_separated(src, e, line.e, flow) then fig.fail("a `*` alias needs a name, then a space", cursor) end
        self:add("alias", cursor, e)
        cursor = e
        at_content_start = false
      else
        plain()
      end
    else
      plain()
    end
  end

  if line.start ~= line_in.start and line.newline_end > line.e then
    self:add("newline", line.e, line.newline_end)
  end
end

function T:tokenize()
  local src = self.src
  local indent_stack = { { indent = 0, prop_only = false } }
  local current_indent = 0

  -- A leading UTF-8 BOM is not content: the first line starts after it,
  -- so its indentation and its first key are read as without one.
  if self.i == 0 and src:sub(1, 3) == "\239\187\191" then self.i = 3 end

  while true do
    local line = self:get_line()
    if not line then break end
    if line.content_start == line.e or self:line_all_ws(line) then goto continue end

    if self.flow_depth > 0 then
      if line.content_start == line.start then
        local kind = self:doc_marker(line)
        if kind then
          local cs = line.content_start
          self:add(kind, cs, cs + 3)
          if line.newline_end > line.e then self:add("newline", line.e, line.newline_end) end
          goto continue
        end
      end
      local indent = line.content_start - line.start
      local first = at(src, line.content_start)
      if not self.flow_root and first ~= RBRACK and first ~= RBRACE and indent <= self.flow_open_indent then
        fig.fail("a line inside a flow collection must be indented past the line that opened it", line.content_start)
      end
      self:tokenize_line_content(line)
      if self.i == line.newline_end and line.newline_end > line.e then
        self:add("newline", line.e, line.newline_end)
      end
      goto continue
    end

    if at(src, line.content_start) == HASH then
      self:add("comment", line.content_start, line.e)
      if line.newline_end > line.e then self:add("newline", line.e, line.newline_end) end
      goto continue
    end

    do
      local indent = line.content_start - line.start
      local prop_only = self:line_is_property_only(line)
      if indent > current_indent then
        indent_stack[#indent_stack + 1] = { indent = indent, prop_only = prop_only }
        self:add("indent", line.start, line.content_start)
        current_indent = indent
      elseif indent < current_indent then
        while indent < current_indent do
          local popped = table.remove(indent_stack)
          current_indent = indent_stack[#indent_stack].indent
          if popped.prop_only and indent > current_indent then
            indent_stack[#indent_stack + 1] = { indent = indent, prop_only = prop_only }
            current_indent = indent
            break
          end
          self:add("dedent", line.content_start, line.content_start)
        end
        local last = indent_stack[#indent_stack]
        if indent ~= current_indent and indent > current_indent and entry_content_column(src, last.entry_dash, last.indent, indent) then
          indent_stack[#indent_stack + 1] = { indent = indent, prop_only = prop_only }
          current_indent = indent
        end
        if indent ~= current_indent then fig.fail("this line's indentation matches no block open above it", line.content_start) end
      end

      -- Where a block-sequence entry begins on its level, so a later dedent
      -- can return to the content column of any `- ` on its line.
      if at(src, line.content_start) == DASH and followed_by_blank(src, line.content_start, line.e) then
        indent_stack[#indent_stack].entry_dash = line.content_start
      end

      if indent == 0 then
        local kind = self:doc_marker(line)
        if kind then
          local cs = line.content_start
          self:add(kind, cs, cs + 3)
          local rest = cs + 3
          while rest < line.e and is_blank(at(src, rest)) do rest = rest + 1 end
          if rest < line.e then
            self:tokenize_line_content({ start = rest, content_start = rest, e = line.e, newline_end = line.newline_end })
          end
          if self.i == line.newline_end then
            if line.newline_end > line.e then self:add("newline", line.e, line.newline_end) end
            self:flush_pending_block()
          end
          goto continue
        end
      end

      if indent == 0 and at(src, line.content_start) == PCT then
        self:add("directive", line.content_start, line.e)
        if line.newline_end > line.e then self:add("newline", line.e, line.newline_end) end
        goto continue
      end

      if self:tab_indented_structure(line) then fig.fail("a tab indents this line; YAML indentation is spaces", line.content_start) end

      self:tokenize_line_content(line)
      if self.i == line.newline_end then
        if line.newline_end > line.e then self:add("newline", line.e, line.newline_end) end
        self:flush_pending_block()
      end
    end
    ::continue::
  end

  while #indent_stack > 1 do
    table.remove(indent_stack)
    self:add("dedent", self.i, self.i)
  end
  self:add("end_of_file", self.i, self.i)
  return self.tokens
end


-- ── scalars ───────────────────────────────────────────────────────────────
-- Decoding and resolution: quoted strings with their folds and escapes,
-- block scalars with their chomping, and the plain-scalar schema of each
-- dialect.

local function eql_any(s, list)
  for _, x in ipairs(list) do
    if s == x then return true end
  end
  return false
end

-- Folds a run of line breaks in a flow (quoted or plain) scalar where
-- `inner[i]` (0-based) is a newline; returns the index past the run.
local function fold_flow_break(out, inner, i)
  while #out > 0 do
    local last = out[#out]
    if last ~= " " and last ~= "\t" then break end
    out[#out] = nil
  end
  i = i + 1
  local breaks = 1
  while true do
    while i < #inner and (at(inner, i) == SP or at(inner, i) == TAB) do i = i + 1 end
    if i < #inner and at(inner, i) == CR and at(inner, i + 1) == NL then i = i + 1 end
    if i < #inner and at(inner, i) == NL then
      breaks = breaks + 1
      i = i + 1
    else
      break
    end
  end
  if breaks == 1 then
    out[#out + 1] = " "
  else
    for _ = 1, breaks - 1 do out[#out + 1] = "\n" end
  end
  return i
end

local function fold_plain_scalar(source)
  local out = {}
  local i = 0
  local n = #source
  while i < n do
    local c = at(source, i)
    if c == CR and at(source, i + 1) == NL then
      i = i + 1
    elseif c == NL then
      i = fold_flow_break(out, source, i)
    else
      out[#out + 1] = string.char(c)
      i = i + 1
    end
  end
  return concat(out)
end

local function single_quoted(source)
  if #source < 2 or at(source, 0) ~= SQ or at(source, #source - 1) ~= SQ then fig.fail("this single-quoted string is never closed") end
  local inner = sub(source, 2, -2)
  if not find(inner, "'", 1, true) and not find(inner, "\n", 1, true) then return inner end
  local out = {}
  local i = 0
  local n = #inner
  while i < n do
    local c = at(inner, i)
    if c == CR and at(inner, i + 1) == NL then
      i = i + 1
    elseif c == NL then
      i = fold_flow_break(out, inner, i)
    elseif c ~= SQ then
      out[#out + 1] = string.char(c)
      i = i + 1
    else
      if at(inner, i + 1) ~= SQ then fig.fail("a `'` inside a single-quoted string must be doubled") end
      out[#out + 1] = "'"
      i = i + 2
    end
  end
  return concat(out)
end

local function utf8_of(cp)
  if fig.is_surrogate(cp) or cp > 0x10FFFF then
    fig.fail("an escape names no character: a surrogate, or a codepoint past U+10FFFF")
  end
  return utf8.char(cp)
end

-- The codepoint the `digits` hex digits at `start` spell.
local function hex_escape(inner, start, digits)
  local h = sub(inner, start + 1, start + digits)
  if #h ~= digits or not h:match("^%x+$") then
    fig.fail("an escape needs " .. digits .. " hex digits after it")
  end
  return tonumber(h, 16)
end

local SIMPLE_ESCAPES = {
  [48] = "\0", [97] = "\a", [98] = "\b", [116] = "\t", [TAB] = "\t", [110] = "\n", [118] = "\v",
  [102] = "\f", [114] = "\r", [101] = "\27", [SP] = " ", [DQ] = '"', [47] = "/", [BSLASH] = "\\",
}
local CODEPOINT_ESCAPES = { [78] = 0x85, [95] = 0xA0, [76] = 0x2028, [80] = 0x2029 }

local function double_quoted(source)
  if #source < 2 or at(source, 0) ~= DQ or at(source, #source - 1) ~= DQ then fig.fail("this double-quoted string is never closed") end
  local inner = sub(source, 2, -2)
  if not find(inner, "\\", 1, true) and not find(inner, "\n", 1, true) then return inner end
  local out = {}
  local i = 0
  local n = #inner
  while i < n do
    local c = at(inner, i)
    if c == CR and at(inner, i + 1) == NL then
      i = i + 1
    elseif c == NL then
      i = fold_flow_break(out, inner, i)
    elseif c ~= BSLASH then
      out[#out + 1] = string.char(c)
      i = i + 1
    else
      i = i + 1
      if i >= n then fig.fail("a `\\` at the end of a double-quoted string escapes nothing") end
      if at(inner, i) == CR and at(inner, i + 1) == NL then i = i + 1 end
      if at(inner, i) == NL then
        i = i + 1
        while i < n and (at(inner, i) == SP or at(inner, i) == TAB) do i = i + 1 end
      else
        local e = at(inner, i)
        local simple = SIMPLE_ESCAPES[e]
        if simple then
          out[#out + 1] = simple
        elseif CODEPOINT_ESCAPES[e] then
          out[#out + 1] = utf8_of(CODEPOINT_ESCAPES[e])
        elseif e == 120 then
          out[#out + 1] = utf8_of(hex_escape(inner, i + 1, 2))
          i = i + 2
        elseif e == 117 then
          out[#out + 1] = utf8_of(hex_escape(inner, i + 1, 4))
          i = i + 4
        elseif e == 85 then
          out[#out + 1] = utf8_of(hex_escape(inner, i + 1, 8))
          i = i + 8
        else
          fig.fail("unknown escape in a double-quoted string")
        end
        i = i + 1
      end
    end
  end
  return concat(out)
end

-- The physical lines of `s`, `\r\n` read as one break, the segment a
-- trailing newline would create dropped by the caller.
local function lines_of(s)
  local out = {}
  local i = 0
  local n = #s
  while true do
    local nl = find(s, "\n", i + 1, true)
    local e = nl and (nl - 1) or n
    local le = e
    if le > i and at(s, le - 1) == CR then le = le - 1 end
    out[#out + 1] = sub(s, i + 1, le)
    if not nl then break end
    i = nl
  end
  return out
end

local function is_all_ws(line)
  return line:match("^[ \t]*$") ~= nil
end

local function dedent_line(line, n)
  local k = 0
  while k < n and k < #line and at(line, k) == SP do k = k + 1 end
  return sub(line, k + 1)
end

local function autodetect_indent(body)
  for _, line in ipairs(lines_of(body)) do
    if not is_all_ws(line) then
      local k = 0
      while k < #line and at(line, k) == SP do k = k + 1 end
      return k
    end
  end
  return 0
end

local function decode_block_scalar(header, parent_indent, body)
  local literal = at(header, 0) == PIPE
  local chomp = "clip"
  local explicit = nil
  for i = 1, #header - 1 do
    local c = at(header, i)
    if c == DASH then chomp = "strip"
    elseif c == 43 then chomp = "keep"
    elseif c >= 49 and c <= 57 then explicit = c - 48 end
  end
  local content_indent = explicit and (parent_indent + explicit) or autodetect_indent(body)
  local ends_nl = #body > 0 and at(body, #body - 1) == NL
  local work = ends_nl and sub(body, 1, -2) or body
  local lines = lines_of(work)
  local total_lines = #lines
  local last_content = nil
  for idx, line in ipairs(lines) do
    if not is_all_ws(line) then last_content = idx - 1 end
  end
  local out = {}
  if last_content ~= nil then
    local emitted, prev_blank, prev_more = false, false, false
    for idx, line in ipairs(lines) do
      if idx - 1 > last_content then break end
      local blank = is_all_ws(line)
      local text = blank and "" or dedent_line(line, content_indent)
      local more = #text > 0 and at(text, 0) == SP
      if literal then
        if emitted then out[#out + 1] = "\n" end
        out[#out + 1] = text
      elseif not emitted then
        out[#out + 1] = text
      elseif blank then
        out[#out + 1] = "\n"
      else
        if prev_blank then
          -- the blank line already emitted the break
        elseif prev_more or more then
          out[#out + 1] = "\n"
        else
          out[#out + 1] = " "
        end
        out[#out + 1] = text
      end
      emitted = true
      prev_blank = blank
      prev_more = more and not blank
    end
    local trailing_blanks = total_lines - 1 - last_content
    local present_breaks = trailing_blanks + (ends_nl and 1 or 0)
    local keep
    if chomp == "strip" then keep = 0
    elseif chomp == "clip" then keep = math.min(present_breaks, 1)
    else keep = present_breaks end
    for _ = 1, keep do out[#out + 1] = "\n" end
  elseif chomp == "keep" then
    local present_breaks = math.max(total_lines - 1, 0) + (ends_nl and 1 or 0)
    for _ = 1, present_breaks do out[#out + 1] = "\n" end
  end
  return concat(out)
end

local function is_inf_nan(source)
  local body = source
  local c = at(source, 0)
  if c == 43 or c == DASH then body = sub(source, 2) end
  if eql_any(body, { ".inf", ".Inf", ".INF" }) then return true end
  return eql_any(source, { ".nan", ".NaN", ".NAN" })
end

-- The 1.2 core schema's numbers: a hex or octal lexeme, or decimal
-- digits with an optional fraction and an optional exponent — "int",
-- "float" or nil.

-- Whether `body` is a mantissa with a fraction or an exponent, and so a
-- float rather than an int.
local function core_float(body)
  local mantissa, exponent = body:match("^(.-)([eE][-+]?%d+)$")
  if not exponent then mantissa = body end
  if mantissa:match("^%d+%.%d*$") or mantissa:match("^%.%d+$") then return true end
  return exponent ~= nil and mantissa:match("^%d+$") ~= nil
end

local function classify_number(source)
  if is_inf_nan(source) then return "float" end
  if source:match("^0x%x+$") or source:match("^0o[0-7]+$") then return "int" end
  local body = source:match("^[-+](.*)$") or source
  if body:match("^%d+$") then return "int" end
  if core_float(body) then return "float" end
  return nil
end

-- ── YAML 1.1 resolution ───────────────────────────────────────────────────

local function bool_1_1(source)
  if eql_any(source, { "y", "Y", "yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON" }) then return true end
  if eql_any(source, { "n", "N", "no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF" }) then return false end
  return nil
end

-- A run of `cls` digits with `_` separators anywhere between them, at
-- least one digit: 1.1 spells `0b1010_1010` and `0x_FF` alike.
local function digit_run(s, cls)
  return s:match("^[" .. cls .. "_]*[" .. cls .. "][" .. cls .. "_]*$") ~= nil
end

-- 1.1's base-10 float: an optional integer part, a `.`, and an exponent
-- whose sign is not optional.
local function is_1_1_base10_float(s)
  local mantissa = s:match("^(.-)[eE][-+]%d+$")
  if not mantissa then
    if find(s, "e", 1, true) or find(s, "E", 1, true) then return false end
    mantissa = s
  end
  return mantissa:match("^%d[%d_]*%.[%d_]*$") ~= nil or mantissa:match("^%.[%d_]*$") ~= nil
end

-- 1.1's sexagesimal: `1:30`, `190:20:30.15` — groups of at most two
-- digits under sixty after the first. A leading zero on the first group
-- makes it an octal instead, unless a fraction follows.
local function classify_1_1_base60(s)
  local dot = find(s, ".", 1, true)
  if dot and not sub(s, dot + 1):match("^[%d_]*$") then return nil end
  local body = dot and sub(s, 1, dot - 1) or s
  local head, rest = body:match("^(%d[%d_]*)(:.*)$")
  if not head then return nil end
  if not dot and at(head, 0) == 48 then return nil end
  for g in rest:gmatch(":([^:]*)") do
    if not (g:match("^%d$") or g:match("^[0-5]%d$")) then return nil end
  end
  return dot and "float" or "int"
end

local function classify_1_1_number(source)
  if #source == 0 then return nil end
  if is_inf_nan(source) then return "float" end
  local s = source:match("^[-+](.*)$") or source
  if find(s, ":", 1, true) then return classify_1_1_base60(s) end
  if s:match("^0[xX]") then return digit_run(sub(s, 3), "%x") and "int" or nil end
  if s:match("^0[bB]") then return digit_run(sub(s, 3), "01") and "int" or nil end
  if find(s, ".", 1, true) then return is_1_1_base10_float(s) and "float" or nil end
  if #s >= 2 and at(s, 0) == 48 then return digit_run(sub(s, 2), "0-7") and "int" or nil end
  return s:match("^%d[%d_]*$") and "int" or nil
end

-- 1.1's timestamp, which is `fig.datetime`'s with two of its dialect
-- switches off: a bare `12:30:00` is sexagesimal here, not a time, and
-- the seconds of a datetime are not optional.
local TIMESTAMP_1_1 = { time_only = false, minute_precision = false }

-- ── the parser ────────────────────────────────────────────────────────────
-- A container stack over the token stream. Nodes are the prelude's tree
-- nodes, given their properties, markers and separators, and laid out by
-- `fig.rows`.

local P = {}
P.__index = P

local function new_parser(src, tokens, version)
  return setmetatable({
    src = src, tokens = tokens, index = 1, version = version,
    nodes = {}, anchors = {}, stack = {}, tag_directives = {},
    -- the properties and the comments waiting for the node they belong to
    pending_tag = nil, pending_anchor = nil, container_tag = nil, container_anchor = nil,
    pending_leading = {}, last_value_id = nil, root = nil,
    -- where the line stands: a `:` seen, a container parked while its
    -- properties are read, an `indent` that must open a new one
    colon_line = false, parking_container = false, force_new_container = false,
    value_only_indents = 0,
    -- the document: `---`, `...`, and the directives above them
    doc_started = false, doc_ended = false, on_doc_start_line = false,
    directives_pending = false, yaml_directive_seen = false,
  }, P)
end

-- Refuse the document, in this script's own words — at an offset when
-- one is at hand.
local fail = fig.fail

function P:peek() return self.tokens[self.index] end

function P:text(tok) return sub(self.src, tok.s + 1, tok.e) end

function P:column_of(pos)
  local src = self.src
  local start = pos
  while start > 0 and at(src, start - 1) ~= NL do start = start - 1 end
  return pos - start
end

function P:advance()
  local tok = self.tokens[self.index]
  self.index = self.index + 1
  local k = tok.kind
  if k == "comment" then
    self:capture_comment(tok)
  elseif k == "newline" then
    self.last_value_id = nil
    self.colon_line = false
  elseif k == "colon" then
    self.colon_line = true
  end
  return tok
end

function P:skip_trivia_no_newline()
  while true do
    local k = self:peek().kind
    if k == "whitespace" or k == "comment" then self:advance() else return end
  end
end

function P:skip_flow_trivia()
  while true do
    local k = self:peek().kind
    if k == "whitespace" or k == "newline" or k == "comment" or k == "indent" or k == "dedent" then
      self:advance()
    else
      return
    end
  end
end

function P:skip_flow_inline_trivia()
  while true do
    local k = self:peek().kind
    if k == "whitespace" or k == "comment" then self:advance() else return end
  end
end

-- ── comments ──

local function comment_text(raw)
  return fig.trim_comment(at(raw, 0) == HASH and sub(raw, 2) or raw)
end

function P:current() return self.stack[#self.stack] end

function P:awaits_block_value()
  local c = self:current()
  return c ~= nil and c.kind == "mapping" and c.pending_key ~= nil
end

function P:capture_comment(tok)
  local c = { style = "line", text = comment_text(self:text(tok)) }
  if self.last_value_id ~= nil then
    self.nodes[self.last_value_id + 1].trailing = { c }
    self.last_value_id = nil
  elseif self.colon_line and self:awaits_block_value() then
    self:current().pending_value_trailing = c
  else
    self.pending_leading[#self.pending_leading + 1] = c
  end
end

function P:claim_leading(id)
  if #self.pending_leading == 0 then return end
  self.nodes[id + 1].leading = self.pending_leading
  self.pending_leading = {}
end

function P:claim_dangling(id)
  if #self.pending_leading == 0 then return end
  self.nodes[id + 1].dangling = self.pending_leading
  self.pending_leading = {}
end

-- ── nodes ──

-- A node of `kind` over `span`, taking the pending properties; `extra` is
-- its text and (for a container) its children list.
function P:add_node(kind, s, e, extra)
  local id = #self.nodes
  local n = fig.node(kind, { s, e }, extra)
  n.id = id
  local tag, anchor = self.pending_tag, self.pending_anchor
  self.pending_tag, self.pending_anchor = nil, nil
  -- An implicit empty (`k: !!str`, `- &a`) is anchored at the separator,
  -- before its properties: it covers them instead, as a written value does,
  -- so a replace takes them rather than writing in front of them (`x !!str`).
  local after
  if s == e then
    if tag and tag.s >= s then after = { tag.s, tag.e } end
    if anchor and anchor.s >= s then
      after = after and { math.min(after[1], anchor.s), math.max(after[2], anchor.e) } or { anchor.s, anchor.e }
    end
  end
  if tag then
    if tag.s < n.span[1] then n.span[1] = tag.s end
    n.tag = tag.text
    n.tag_span = { tag.s, tag.e }
  end
  if anchor then
    if anchor.s < n.span[1] then n.span[1] = anchor.s end
    n.anchor = anchor.name
    n.anchor_span = { anchor.s, anchor.e }
    self.anchors[#self.anchors + 1] = { name = anchor.name, node = id }
  end
  if after then n.span = after end
  self.nodes[id + 1] = n
  if not self.parking_container then self:claim_leading(id) end
  return id
end

function P:node(id) return self.nodes[id + 1] end

function P:add_null(s, e) return self:add_node("null", s, e) end

function P:span_of(id) return self.nodes[id + 1].span end

-- ── properties ──

function P:validate_tag_handle(text, pos)
  if #text < 2 then return end
  local c1 = at(text, 1)
  if c1 == LT or c1 == BANG then return end
  local close = find(text, "!", 2, true)
  if not close then return end
  local handle = sub(text, 1, close)
  for _, d in ipairs(self.tag_directives) do
    if d.handle == handle then return end
  end
  fail("tag handle `" .. handle .. "` was never declared by a `%TAG` directive", pos)
end

function P:stash_tag(text, s, e)
  self:validate_tag_handle(text, s)
  if self.pending_tag then
    if self.container_tag then fail("a node takes one tag", s) end
    self.container_tag = self.pending_tag
    self.pending_tag = nil
  end
  self.pending_tag = { text = text, s = s, e = e }
end

function P:stash_anchor(name, s, e)
  if self.pending_anchor then
    if self.container_anchor then fail("a node takes one anchor", s) end
    self.container_anchor = self.pending_anchor
    self.pending_anchor = nil
  end
  self.pending_anchor = { name = name, s = s, e = e }
end

function P:consume_pending_properties()
  while true do
    self:skip_trivia_no_newline()
    local t = self:peek()
    if t.kind == "tag" then
      self:advance()
      self:stash_tag(self:text(t), t.s, t.e)
    elseif t.kind == "anchor" then
      self:advance()
      self:stash_anchor(sub(self.src, t.s + 2, t.e), t.s, t.e)
    else
      break
    end
  end
end

function P:pending_prop_on_line_of(pos)
  local src = self.src
  local function same_line(from, to)
    return from <= to and not find(sub(src, from + 1, to), "\n", 1, true)
  end
  if self.pending_anchor and same_line(self.pending_anchor.e, pos) then return true end
  if self.pending_tag and same_line(self.pending_tag.e, pos) then return true end
  return false
end

function P:hold_key_line_props()
  if not self:pending_prop_on_line_of(self:peek().s) then return {} end
  local held = { anchor = self.pending_anchor, tag = self.pending_tag }
  self.pending_anchor, self.pending_tag = nil, nil
  return held
end

function P:release_key_line_props(held)
  if held.anchor then self.pending_anchor = held.anchor end
  if held.tag then self.pending_tag = held.tag end
end

-- ── containers ──

function P:container_by_id(id)
  for _, c in ipairs(self.stack) do
    if c.id == id then return c end
  end
  error("no open container " .. tostring(id))
end

function P:current_container_indent()
  if #self.stack == 0 then return 0 end
  return self:column_of(self:span_of(self:current().id)[1])
end

function P:open_container(kind, start)
  self.parking_container = true
  local extra = kind == "mapping" and { entries = {} } or { items = {} }
  local id
  if self.container_anchor or self.container_tag then
    local child_anchor, child_tag = self.pending_anchor, self.pending_tag
    self.pending_anchor, self.pending_tag = self.container_anchor, self.container_tag
    self.container_anchor, self.container_tag = nil, nil
    id = self:add_node(kind, start, start, extra)
    self.pending_anchor, self.pending_tag = child_anchor, child_tag
  else
    id = self:add_node(kind, start, start, extra)
  end
  self.parking_container = false
  self.stack[#self.stack + 1] = {
    id = id, kind = kind, first_child = nil, pending_key = nil, pending_value_span = 0,
    pending_value_trailing = nil, pending_sequence_item_span = nil, pending_sequence_item = false,
    current_marker = nil, pending_sep_span = nil, continues_sequence_item = false,
    shares_parent_indent = false, explicit_awaiting_value = false, building_explicit_key = false,
    explicit_key_col = 0,
  }
  return id
end

-- A container opened for the node in hand that continues the sequence
-- item or the explicit key above it, rather than standing on its own.
function P:open_nested(kind, start)
  local id = self:open_container(kind, start or self:peek().s)
  self:container_by_id(id).continues_sequence_item = true
  return id
end

function P:close_container(span_end)
  if #self.stack == 0 then fail("nothing is open here to close", span_end) end
  local c = table.remove(self.stack)
  if c.first_child == nil then self:span_of(c.id)[2] = span_end end
  return c.id
end

function P:ensure_container(kind)
  if not self.force_new_container and #self.stack > 0 then
    local current = self:current()
    if current.kind == kind then return current.id end
    if kind == "mapping" and current.kind == "sequence" then
      local has_enclosing_mapping = false
      for i = 1, #self.stack - 1 do
        if self.stack[i].kind == "mapping" then has_enclosing_mapping = true end
      end
      if not has_enclosing_mapping then fail("a `key:` here would belong to no mapping: the item it is in already holds a value", self:peek().s) end
      self:close_pending_empty_value()
      local id = self:close_container(self:span_of(current.id)[2])
      self:finish_value(id)
      return self:ensure_container(kind)
    end
  end
  local shares_parent = kind == "sequence" and not self.force_new_container
    and #self.stack > 0 and self:current().kind == "mapping"
  self.force_new_container = false
  local id = self:open_container(kind, self:peek().s)
  if shares_parent then self:container_by_id(id).shares_parent_indent = true end
  return id
end

function P:current_awaits_value()
  local c = self:current()
  if not c then return false end
  if c.kind == "mapping" then return c.pending_key ~= nil end
  return c.pending_sequence_item
end

function P:attach_child(parent, child_id)
  local pnode = self:node(parent.id)
  local child = self:node(child_id)
  if parent.kind == "sequence" then
    pnode.items[#pnode.items + 1] = child
  else
    pnode.entries[#pnode.entries + 1] = child
  end
  parent.first_child = parent.first_child or child_id
  pnode.span[2] = child.span[2]
end

function P:attach_deferred_value(value_id)
  if self.force_new_container then
    self.value_only_indents = self.value_only_indents + 1
    self.force_new_container = false
  end
  self:finish_value(value_id)
end

function P:finish_value(value_id)
  self.last_value_id = value_id
  if #self.stack == 0 then
    if self.root ~= nil then fail("a second top-level value; a document holds one", self:span_of(value_id)[1]) end
    self.root = value_id
    return
  end
  local parent = self:current()
  if parent.kind == "sequence" then
    self:attach_child(parent, value_id)
    parent.pending_sequence_item = false
    parent.pending_sequence_item_span = nil
    if parent.current_marker then
      self:node(value_id).marker = parent.current_marker
      parent.current_marker = nil
    end
  else
    if parent.building_explicit_key then
      parent.building_explicit_key = false
      parent.pending_key = value_id
      parent.pending_value_span = self:span_of(value_id)[2]
      parent.explicit_awaiting_value = true
      return
    end
    local key_id = parent.pending_key
    if key_id == nil then fail("a value with no key", self:span_of(value_id)[1]) end
    parent.pending_key = nil
    parent.explicit_awaiting_value = false
    if parent.pending_value_trailing then
      self:node(value_id).trailing = { parent.pending_value_trailing }
      parent.pending_value_trailing = nil
    end
    local key, value = self:node(key_id), self:node(value_id)
    local prev = self.parking_container
    self.parking_container = true
    local pair_id = self:add_node("keyvalue", key.span[1], value.span[2], { key = key, value = value })
    self.parking_container = prev
    if parent.pending_sep_span then
      self:node(pair_id).sep = parent.pending_sep_span
      parent.pending_sep_span = nil
    end
    self:attach_child(parent, pair_id)
  end
end

function P:close_pending_empty_value()
  local parent = self:current()
  if not parent then return end
  if parent.kind == "sequence" then
    if parent.pending_sequence_item then
      local s = parent.pending_sequence_item_span or 0
      self:finish_value(self:add_null(s, s))
    end
  elseif parent.pending_key ~= nil then
    parent.explicit_awaiting_value = false
    self:finish_value(self:add_null(parent.pending_value_span, parent.pending_value_span))
  end
end

function P:close_sequence_item_continuation()
  if self.force_new_container then return end
  while #self.stack > 0 and self:current().continues_sequence_item do
    self:current().continues_sequence_item = false
    self:close_pending_empty_value()
    local id = self:close_container(self:span_of(self:current().id)[2])
    self:finish_value(id)
  end
end

-- Hands a line beginning at column `col` to the open compact item container
-- (`continues_sequence_item`) that begins at that column, closing the ones
-- nested deeper than it on its dash line: in `- - - a\n  - d` the `- d` is
-- an item of the middle sequence, so the innermost closes, and the middle one
-- takes the line as its own content by clearing its flag. Containers left of
-- `col`, and any container that is not a compact item, are left open. True
-- when a compact item begins at `col`.
function P:land_continuations(col)
  while #self.stack > 0 do
    local c = self:current()
    if not c.continues_sequence_item then return false end
    local c_col = self:column_of(self:span_of(c.id)[1])
    if c_col < col then return false end
    c.continues_sequence_item = false
    if c_col == col then return true end
    self:close_pending_empty_value()
    local id = self:close_container(self:span_of(self:current().id)[2])
    self:finish_value(id)
  end
  return false
end

function P:close_open_complex_key()
  if #self.stack < 2 then return end
  local parent = self.stack[#self.stack - 1]
  if not parent.building_explicit_key then return end
  if self:column_of(self:peek().s) > parent.explicit_key_col then return end
  self:current().continues_sequence_item = false
  self:close_pending_empty_value()
  local id = self:close_container(self:span_of(self:current().id)[2])
  self:finish_value(id)
end

function P:clear_pending_sequence_item(sequence_id)
  local parent = self:container_by_id(sequence_id)
  parent.pending_sequence_item = false
  parent.pending_sequence_item_span = nil
end

-- ── scalars and aliases ──

function P:scalar_kind(source)
  if #source >= 2 and at(source, 0) == SQ then return "string", single_quoted(source) end
  if #source >= 2 and at(source, 0) == DQ then return "string", double_quoted(source) end
  if find(source, "\n", 1, true) then return "string", fold_plain_scalar(source) end
  if self.version == "1.1" then
    if eql_any(source, { "null", "Null", "NULL", "~" }) then return "null", nil end
    local b = bool_1_1(source)
    if b ~= nil then return "bool", b and "true" or "false" end
    local num = classify_1_1_number(source)
    if num then return num, source end
    local ts = DT.classify(source, TIMESTAMP_1_1)
    if ts then return "string", source, ts end
    return "string", source
  end
  if eql_any(source, { "null", "Null", "NULL", "~" }) then return "null", nil end
  if eql_any(source, { "true", "True", "TRUE" }) then return "bool", "true" end
  if eql_any(source, { "false", "False", "FALSE" }) then return "bool", "false" end
  local num = classify_number(source)
  if num then return num, source end
  return "string", source
end

function P:parse_scalar()
  local t = self:peek()
  if t.kind ~= "scalar" then fail("expected a scalar here", t.s) end
  self:advance()
  local kind, text, ext = self:scalar_kind(self:text(t))
  return self:add_node(kind, t.s, t.e, { text = text, ext_kind = ext })
end

function P:parse_alias()
  if self.pending_anchor or self.pending_tag then fail("an alias carries no anchor or tag of its own", self:peek().s) end
  local t = self:advance()
  return self:add_node("alias", t.s, t.e, { text = sub(self.src, t.s + 2, t.e) })
end

function P:parse_key_node()
  if self:peek().kind == "alias" then return self:parse_alias() end
  return self:parse_scalar()
end

function P:is_mapping_start()
  local t = self:peek()
  if t.kind == "scalar" then
    if find(sub(self.src, t.s + 1, t.e), "\n", 1, true) then return false end
  elseif t.kind ~= "alias" then
    return false
  end
  local la = self.index + 1
  while la <= #self.tokens do
    local k = self.tokens[la].kind
    if k == "whitespace" or k == "comment" then
      la = la + 1
    elseif k == "colon" then
      return true
    else
      return false
    end
  end
  return false
end

function P:parse_block_scalar()
  local header = self:advance()
  local header_source = self:text(header)
  while true do
    local k = self:peek().kind
    if k == "whitespace" or k == "comment" then self:advance() else break end
  end
  if self:peek().kind == "newline" then self:advance() end
  local parent_indent = self:current_container_indent()
  local span_end = header.e
  local value = ""
  if self:peek().kind == "block_scalar" then
    local body = self:advance()
    span_end = body.e
    value = decode_block_scalar(header_source, parent_indent, self:text(body))
  end
  return self:add_node("string", header.s, span_end, { text = value })
end

function P:require_value_end()
  while self:peek().kind == "whitespace" do self:advance() end
  local k = self:peek().kind
  if not (k == "newline" or k == "comment" or k == "dedent" or k == "end_of_file") then fail("a value must end its line; nothing may follow it but a comment", self:peek().s) end
end

function P:tab_between(from, to)
  if from > to or to > #self.src then return false end
  return find(sub(self.src, from + 1, to), "\t", 1, true) ~= nil
end

-- ── flow ──

local function invalid_flow_scalar(source)
  if #source == 0 then return true end
  local c = at(source, 0)
  if c == HASH then return true end
  if not (c == DASH or c == QUEST or c == COLON) then return false end
  if #source == 1 then return true end
  local c1 = at(source, 1)
  return c1 == SP or c1 == TAB
end

function P:parse_flow_node()
  self:skip_flow_trivia()
  while true do
    local t = self:peek()
    if t.kind == "tag" then
      self:advance()
      self:stash_tag(self:text(t), t.s, t.e)
    elseif t.kind == "anchor" then
      self:advance()
      self:stash_anchor(sub(self.src, t.s + 2, t.e), t.s, t.e)
    else
      break
    end
    self:skip_flow_trivia()
  end
  local k = self:peek().kind
  if self.pending_tag or self.pending_anchor then
    if k == "comma" or k == "colon" or k == "flow_map_end" or k == "flow_seq_end" then
      local a = self:peek().s
      return self:add_null(a, a)
    end
  end
  if k == "flow_seq_start" then return self:parse_flow_sequence() end
  if k == "flow_map_start" then return self:parse_flow_mapping() end
  if k == "alias" then return self:parse_alias() end
  if k == "scalar" then
    if invalid_flow_scalar(self:text(self:peek())) then fail("a plain scalar inside a flow collection cannot begin this way", self:peek().s) end
    return self:parse_scalar()
  end
  fail("expected a value inside this flow collection", self:peek().s)
end

function P:wrap_flow_pair(key_id, value_id)
  local key, value = self:node(key_id), self:node(value_id)
  local pair_id = self:add_node("keyvalue", key.span[1], value.span[2], { key = key, value = value })
  local map_id = self:add_node("mapping", key.span[1], value.span[2], { entries = { self:node(pair_id) } })
  return map_id
end

function P:parse_flow_sequence_item()
  local explicit = self:peek().kind == "explicit_key"
  if explicit then
    self:advance()
    self:skip_flow_trivia()
  end
  local k = self:peek().kind
  local key_id
  if k == "colon" then
    key_id = self:add_null(self:peek().s, self:peek().e)
  elseif k == "comma" or k == "flow_seq_end" then
    if not explicit then fail("expected a value before this `,` or `]`", self:peek().s) end
    key_id = self:add_null(self:peek().s, self:peek().e)
  else
    key_id = self:parse_flow_node()
  end
  if explicit then self:skip_flow_trivia() else self:skip_flow_inline_trivia() end
  if self:peek().kind ~= "colon" then
    if not explicit then return key_id end
    local a = self:span_of(key_id)[2]
    return self:wrap_flow_pair(key_id, self:add_null(a, a))
  end
  self:advance()
  self:skip_flow_trivia()
  local vk = self:peek().kind
  local value_id
  if vk == "comma" or vk == "flow_seq_end" then
    local a = self:span_of(key_id)[2]
    value_id = self:add_null(a, a)
  else
    value_id = self:parse_flow_node()
  end
  return self:wrap_flow_pair(key_id, value_id)
end

function P:parse_flow_sequence()
  local open = self:advance()
  local seq_id = self:add_node("sequence", open.s, open.e, { items = {} })
  local seq = self:node(seq_id)
  self:skip_flow_trivia()
  while self:peek().kind ~= "flow_seq_end" do
    if self:peek().kind == "end_of_file" then fail("this flow sequence is never closed", open.s) end
    local item = self:parse_flow_sequence_item()
    seq.items[#seq.items + 1] = self:node(item)
    self:skip_flow_trivia()
    local k = self:peek().kind
    if k == "comma" then
      self:advance()
      self:skip_flow_trivia()
    elseif k ~= "flow_seq_end" then
      fail("expected `,` or `]` here", self:peek().s)
    end
  end
  local close = self:advance()
  seq.span[2] = close.e
  return seq_id
end

function P:parse_flow_mapping()
  local open = self:advance()
  local map_id = self:add_node("mapping", open.s, open.e, { entries = {} })
  local map = self:node(map_id)
  self:skip_flow_trivia()
  while self:peek().kind ~= "flow_map_end" do
    if self:peek().kind == "end_of_file" then fail("this flow mapping is never closed", open.s) end
    if self:peek().kind == "explicit_key" then
      self:advance()
      self:skip_flow_trivia()
    end
    local k = self:peek().kind
    local key_id
    if k == "colon" or k == "comma" or k == "flow_map_end" then
      key_id = self:add_null(self:peek().s, self:peek().e)
    else
      key_id = self:parse_flow_node()
    end
    self:skip_flow_trivia()
    local value_id
    if self:peek().kind == "colon" then
      self:advance()
      self:skip_flow_trivia()
      local vk = self:peek().kind
      if vk == "comma" or vk == "flow_map_end" then
        local a = self:span_of(key_id)[2]
        value_id = self:add_null(a, a)
      else
        value_id = self:parse_flow_node()
      end
    else
      local a = self:span_of(key_id)[2]
      value_id = self:add_null(a, a)
    end
    local key, value = self:node(key_id), self:node(value_id)
    local pair_id = self:add_node("keyvalue", key.span[1], value.span[2], { key = key, value = value })
    map.entries[#map.entries + 1] = self:node(pair_id)
    self:skip_flow_trivia()
    local nk = self:peek().kind
    if nk == "comma" then
      self:advance()
      self:skip_flow_trivia()
    elseif nk ~= "flow_map_end" then
      fail("expected `,` or `}` here", self:peek().s)
    end
  end
  local close = self:advance()
  map.span[2] = close.e
  return map_id
end

-- ── block entries ──

function P:parse_mapping_value(allow_compact)
  self:skip_trivia_no_newline()
  self:consume_pending_properties()
  local k = self:peek().kind
  if k == "scalar" then
    if allow_compact and self:is_mapping_start() then
      if self:tab_between(self:current().pending_value_span, self:peek().s) then fail("a tab cannot separate a key from the `:` above it", self:peek().s) end
      local child_id = self:open_container("mapping", self:peek().s)
      self:parse_mapping_entry()
      local id = self:close_container(self:span_of(child_id)[2])
      self:finish_value(id)
    else
      local value_id = self:parse_scalar()
      self:finish_value(value_id)
      self:require_value_end()
    end
  elseif k == "dash" then
    if not allow_compact then fail("a `-` item cannot begin on the line of the `:` it belongs to", self:peek().s) end
    self:open_nested("sequence")
    self:parse_sequence_entry()
  elseif k == "block_header" then
    self:finish_value(self:parse_block_scalar())
  elseif k == "alias" then
    self:finish_value(self:parse_alias())
    self:require_value_end()
  elseif k == "flow_seq_start" or k == "flow_map_start" then
    self:finish_value(self:parse_flow_node())
    self:require_value_end()
  elseif k == "newline" or k == "dedent" or k == "end_of_file" then
    -- deferred
  else
    fail("expected a value after `:`", self:peek().s)
  end
end

function P:parse_mapping_entry()
  local held = self:hold_key_line_props()
  local mapping_id = self:ensure_container("mapping")
  self:close_pending_empty_value()
  self:release_key_line_props(held)
  local key_id = self:parse_key_node()
  self:skip_trivia_no_newline()
  if self:peek().kind ~= "colon" then fail("expected `:` after this key", self:peek().s) end
  local colon = self:advance()
  local parent = self:container_by_id(mapping_id)
  parent.pending_key = key_id
  parent.pending_value_span = colon.e
  parent.pending_sep_span = { colon.s, colon.e }
  self:parse_mapping_value(false)
end

function P:parse_empty_key_entry()
  local mapping_id = self:ensure_container("mapping")
  self:close_pending_empty_value()
  local colon = self:advance()
  local key_id = self:add_null(colon.s, colon.s)
  local parent = self:container_by_id(mapping_id)
  parent.pending_key = key_id
  parent.pending_value_span = colon.e
  parent.pending_sep_span = { colon.s, colon.e }
  self:parse_mapping_value(false)
end

function P:parse_explicit_key()
  local marker = self:advance()
  local mapping_id = self:ensure_container("mapping")
  self:close_pending_empty_value()
  self:skip_trivia_no_newline()
  self:consume_pending_properties()
  local m = self:container_by_id(mapping_id)
  if self:peek().kind == "newline" then
    m.building_explicit_key = true
    m.explicit_key_col = self:column_of(marker.s)
    return
  end
  local k = self:peek().kind
  local key_id
  if k == "scalar" then
    if self:is_mapping_start() then
      if self:tab_between(marker.e, self:peek().s) then fail("a tab cannot separate `?` from its key", self:peek().s) end
      m.building_explicit_key = true
      m.explicit_key_col = self:column_of(marker.s)
      self:open_nested("mapping")
      self:parse_mapping_entry()
      return
    end
    key_id = self:parse_scalar()
  elseif k == "flow_seq_start" or k == "flow_map_start" then
    local node_id = self:parse_flow_node()
    self:skip_trivia_no_newline()
    if self:peek().kind == "colon" then
      m.building_explicit_key = true
      m.explicit_key_col = self:column_of(marker.s)
      local key_map_id = self:open_nested("mapping", self:span_of(node_id)[1])
      local colon = self:advance()
      local km = self:container_by_id(key_map_id)
      km.pending_key = node_id
      km.pending_value_span = colon.e
      km.pending_sep_span = { colon.s, colon.e }
      self:parse_mapping_value(false)
      return
    end
    key_id = node_id
  elseif k == "block_header" then
    key_id = self:parse_block_scalar()
  elseif k == "alias" then
    key_id = self:parse_alias()
  elseif k == "dash" then
    m.building_explicit_key = true
    m.explicit_key_col = self:column_of(marker.s)
    self:open_nested("sequence")
    self:parse_sequence_entry()
    return
  elseif k == "colon" then
    m.building_explicit_key = true
    m.explicit_key_col = self:column_of(marker.s)
    self:open_nested("mapping")
    self:parse_empty_key_entry()
    return
  elseif k == "newline" or k == "dedent" or k == "end_of_file" then
    key_id = self:add_null(marker.e, marker.e)
  else
    fail("expected a key after `?`", self:peek().s)
  end
  local parent = self:container_by_id(mapping_id)
  parent.pending_key = key_id
  parent.pending_value_span = self:span_of(key_id)[2]
  parent.pending_sep_span = nil
  parent.explicit_awaiting_value = true
end

function P:parse_sequence_entry()
  local dash = self:advance()
  local sequence_id = self:ensure_container("sequence")
  if self:current().id == sequence_id then self:close_pending_empty_value() end
  self:clear_pending_sequence_item(sequence_id)
  self:container_by_id(sequence_id).current_marker = { dash.s, dash.e }
  self:skip_trivia_no_newline()
  self:consume_pending_properties()
  local k = self:peek().kind
  if k == "newline" or k == "dedent" or k == "end_of_file" then
    self:current().pending_sequence_item = true
    self:current().pending_sequence_item_span = dash.e
  elseif k == "scalar" then
    if self:is_mapping_start() then
      local held = self:hold_key_line_props()
      self:open_nested("mapping")
      self:release_key_line_props(held)
      self:parse_mapping_entry()
    else
      self:finish_value(self:parse_scalar())
    end
  elseif k == "block_header" then
    self:finish_value(self:parse_block_scalar())
  elseif k == "alias" then
    if self:is_mapping_start() then
      self:open_nested("mapping")
      self:parse_mapping_entry()
    else
      self:finish_value(self:parse_alias())
    end
  elseif k == "flow_seq_start" or k == "flow_map_start" then
    self:finish_value(self:parse_flow_node())
  elseif k == "explicit_key" then
    self:open_nested("mapping")
    self:parse_explicit_key()
  elseif k == "colon" then
    self:open_nested("mapping")
    self:parse_empty_key_entry()
  elseif k == "dash" then
    self:open_nested("sequence")
    self:parse_sequence_entry()
  else
    fail("expected a value after `-`", self:peek().s)
  end
end

-- ── directives ──

local function is_directive_space(c) return c == SP or c == TAB or c == CR end

local function skip_directive_space(line, i)
  while i < #line and is_directive_space(at(line, i)) do i = i + 1 end
  return i
end

local function is_yaml_version(s)
  local major, minor = s:match("^(%d+)%.(%d+)$")
  return major ~= nil and minor ~= nil
end

local function require_directive_end(line, i, base)
  local j = skip_directive_space(line, i)
  if j < #line and at(line, j) ~= HASH then
    fail("a directive takes nothing after its arguments but a comment", base + j)
  end
end

function P:parse_directive(tok)
  local line, base = self:text(tok), tok.s
  local i = 1
  local name_start = i
  while i < #line and not is_directive_space(at(line, i)) do i = i + 1 end
  local name = sub(line, name_start + 1, i)
  if #name == 0 then fail("a `%` directive needs a name", base) end
  if name == "YAML" then
    if self.yaml_directive_seen then fail("a second `%YAML` directive", base) end
    self.yaml_directive_seen = true
    i = skip_directive_space(line, i)
    local ver_start = i
    while i < #line and not is_directive_space(at(line, i)) do i = i + 1 end
    if not is_yaml_version(sub(line, ver_start + 1, i)) then fail("a `%YAML` directive takes a version like `1.2`", base + ver_start) end
    require_directive_end(line, i, base)
  elseif name == "TAG" then
    i = skip_directive_space(line, i)
    local handle_start = i
    while i < #line and not is_directive_space(at(line, i)) do i = i + 1 end
    local handle = sub(line, handle_start + 1, i)
    if #handle == 0 then fail("a `%TAG` directive takes a handle and a prefix", base + i) end
    i = skip_directive_space(line, i)
    local prefix_start = i
    while i < #line and not is_directive_space(at(line, i)) do i = i + 1 end
    if i == prefix_start then fail("a `%TAG` directive takes a handle and a prefix", base + prefix_start) end
    require_directive_end(line, i, base)
    self.tag_directives[#self.tag_directives + 1] = { handle = handle, prefix = sub(line, prefix_start + 1, i) }
  end
end

-- ── the main loop ──

-- The token kinds that would begin a second document after a `...` line.
local CONTENT_AFTER_END = {
  dash = true, explicit_key = true, colon = true, scalar = true, alias = true,
  block_header = true, flow_seq_start = true, flow_map_start = true, tag = true, anchor = true,
}

local function invalid_plain_start(source)
  if #source == 0 then return false end
  local c = at(source, 0)
  if c == COMMA then return true end
  if c == QUEST then return #source >= 2 and (at(source, 1) == SP or at(source, 1) == TAB) end
  return false
end

function P:resolve_aliases_or_fail()
  for id = 0, #self.nodes - 1 do
    local n = self.nodes[id + 1]
    if n.kind == "alias" then
      local found = false
      for _, a in ipairs(self.anchors) do
        if a.node >= id then break end
        if a.name == n.text then found = true end
      end
      if not found then fail("alias `*" .. n.text .. "` names an anchor that is not defined above it", n.span[1]) end
    end
  end
end

function P:parse()
  while true do
    self:skip_trivia_no_newline()
    local k = self:peek().kind
    if self.value_only_indents > 0 and not (k == "newline" or k == "dedent" or k == "end_of_file") then
      fail("nothing may follow a value on the line it was indented onto", self:peek().s)
    end
    if self.directives_pending and not (k == "directive" or k == "newline" or k == "doc_start") then
      fail("a directive must be followed by `---`", self:peek().s)
    end
    if self.doc_ended and CONTENT_AFTER_END[k] then
      fail("content after `...` begins a second document; this format reads one per file", self:peek().s)
    end
    if k == "indent" then
      if #self.stack > 0 and self:current().continues_sequence_item then
        local col = self:column_of(self:peek().e)
        if col > self:current_container_indent() then
          self.force_new_container = true
        elseif not self:land_continuations(col) then
          -- A column between two nested compact items (`   - d` under
          -- `- - - a`) begins no node.
          fail("this line's indentation matches no block open above it", self:peek().e)
        end
      else
        self.force_new_container = true
      end
      self:advance()
    elseif k == "dedent" then
      if self.value_only_indents > 0 then
        self.value_only_indents = self.value_only_indents - 1
        self:advance()
      elseif self.force_new_container and (self.pending_anchor or self.pending_tag) then
        self.force_new_container = false
        self:advance()
      else
        self:close_pending_empty_value()
        local dedent = self:advance()
        local dedent_col = self:column_of(dedent.s)
        while true do
          local close_parent_too = #self.stack > 0
            and (self:current().shares_parent_indent or self:current().continues_sequence_item)
          if not close_parent_too and #self.stack >= 2 then
            local parent = self.stack[#self.stack - 1]
            if parent.building_explicit_key and dedent_col < parent.explicit_key_col then close_parent_too = true end
          end
          local id = self:close_container(dedent.e)
          self:finish_value(id)
          if not close_parent_too then break end
          self:close_pending_empty_value()
        end
        -- A dedent landing exactly at an open compact item's own column
        -- returns to a sibling within that item: the next key of an item
        -- mapping (`- k:\n    v: 1\n  sib: 2`), or the next item of a nested
        -- compact sequence (`- - - a\n    - b\n  - c`).
        self:land_continuations(dedent_col)
      end
    elseif k == "newline" then
      self.on_doc_start_line = false
      self:advance()
    elseif k == "doc_start" then
      if self.doc_started or #self.nodes > 0 then fail("a second document begins here; this format reads one document per file", self:peek().s) end
      self.doc_started = true
      self.on_doc_start_line = true
      self.directives_pending = false
      self:advance()
    elseif k == "directive" then
      if self.doc_started or self.doc_ended or self.root ~= nil or #self.nodes > 0 or #self.stack > 0 then
        fail("a directive must come before the document it applies to", self:peek().s)
      end
      local tok = self:advance()
      self:parse_directive(tok)
      self.directives_pending = true
    elseif k == "doc_end" then
      self.doc_ended = true
      self:advance()
    elseif k == "dash" then
      if self.on_doc_start_line then fail("a `-` item cannot share the `---` line", self:peek().s) end
      if self:pending_prop_on_line_of(self:peek().s) then fail("an anchor or a tag cannot precede the `-` of a sequence item", self:peek().s) end
      self:close_sequence_item_continuation()
      self:parse_sequence_entry()
    elseif k == "explicit_key" then
      self:close_sequence_item_continuation()
      self:parse_explicit_key()
    elseif k == "colon" then
      self:close_open_complex_key()
      if #self.stack > 0 and self:current().building_explicit_key then
        local null_key = self:add_null(self:peek().s, self:peek().s)
        local m = self:current()
        m.building_explicit_key = false
        m.pending_key = null_key
        m.explicit_awaiting_value = true
      end
      if #self.stack > 0 and self:current().explicit_awaiting_value then
        local colon = self:advance()
        self:current().explicit_awaiting_value = false
        self:current().pending_value_span = colon.e
        self:current().pending_sep_span = { colon.s, colon.e }
        self:parse_mapping_value(true)
      else
        self:close_sequence_item_continuation()
        self:parse_empty_key_entry()
      end
    elseif k == "scalar" then
      self:close_sequence_item_continuation()
      if self:is_mapping_start() then
        if self.on_doc_start_line then fail("a mapping cannot begin on the `---` line", self:peek().s) end
        self:parse_mapping_entry()
      elseif #self.stack == 0 and self.root == nil then
        if invalid_plain_start(self:text(self:peek())) then fail("a plain scalar cannot begin with `,` or `? `", self:peek().s) end
        self:finish_value(self:parse_scalar())
      elseif self.force_new_container and self:current_awaits_value() then
        self:attach_deferred_value(self:parse_scalar())
      else
        fail("unexpected value here", self:peek().s)
      end
    elseif k == "alias" then
      self:close_sequence_item_continuation()
      if self:is_mapping_start() then
        self:parse_mapping_entry()
      elseif #self.stack == 0 and self.root == nil then
        self:finish_value(self:parse_alias())
      elseif self.force_new_container and self:current_awaits_value() then
        self:attach_deferred_value(self:parse_alias())
      else
        fail("unexpected alias here", self:peek().s)
      end
    elseif k == "block_header" then
      self:close_sequence_item_continuation()
      if #self.stack == 0 and self.root == nil then
        self:finish_value(self:parse_block_scalar())
      elseif self.force_new_container and self:current_awaits_value() then
        self:attach_deferred_value(self:parse_block_scalar())
      else
        fail("unexpected block scalar here", self:peek().s)
      end
    elseif k == "flow_seq_start" or k == "flow_map_start" then
      self:close_sequence_item_continuation()
      local node_id = self:parse_flow_node()
      self:skip_trivia_no_newline()
      if self:peek().kind == "colon" then
        local span = self:span_of(node_id)
        if find(sub(self.src, span[1] + 1, span[2]), "\n", 1, true) then fail("a flow collection spanning lines cannot be a key", span[1]) end
        local mapping_id = self:ensure_container("mapping")
        self:close_pending_empty_value()
        local colon = self:advance()
        local parent = self:container_by_id(mapping_id)
        parent.pending_key = node_id
        parent.pending_value_span = colon.e
        parent.pending_sep_span = { colon.s, colon.e }
        self:parse_mapping_value(false)
      else
        self:attach_deferred_value(node_id)
      end
    elseif k == "tag" or k == "anchor" then
      local in_container = #self.stack > 0
      self:consume_pending_properties()
      if in_container then
        local nk = self:peek().kind
        if nk == "newline" or nk == "dedent" or nk == "end_of_file" then
          if not (self.force_new_container and self:current_awaits_value()) then fail("an anchor or a tag here belongs to no node", self:peek().s) end
        end
      end
    elseif k == "end_of_file" then
      break
    else
      fail("unexpected token here", self:peek().s)
    end
  end

  while #self.stack > 0 do
    self:close_pending_empty_value()
    local id = self:close_container(self:peek().e)
    self:finish_value(id)
  end
  if self.container_anchor or self.container_tag then fail("a node takes one anchor and one tag", (self.container_anchor or self.container_tag).s) end
  self:resolve_aliases_or_fail()
  local root = self.root
  if root == nil then root = self:add_null(self:peek().s, self:peek().e) end
  self:claim_dangling(root)
  return self:node(root)
end

function M.parse(dialect, input)
  local version = dialect == "lua-yaml-1.1" and "1.1" or "1.2"
  local tokens = tokenizer(input):tokenize()
  local p = new_parser(input, tokens, version)
  local root = p:parse()
  local t = fig.rows(root)
  for _, d in ipairs(p.tag_directives) do t:directive(d.handle, d.prefix) end
  return t
end

-- ── the printer ───────────────────────────────────────────────────────────
-- Block style, two-space indentation whatever the options say, a flow
-- form for a collection value that fits `width` and carries nothing flow
-- cannot spell, a `|` block for a multi-line string, and a scalar quoted
-- exactly when the plain form would read back as something else.

-- A number is written as its own lexeme where YAML 1.2 reads that back
-- as the same number, and in decimal where it does not.
local function number_text(raw)
  return N.text(raw, N.YAML_1_2)
end

-- Whether the plain form of `s` would read back as a number. The rule is
-- the compiled printer's, which asks Zig's `parseInt` and `parseFloat`:
-- they accept `_` separators, so `1_000` and `1__0` are quoted here even
-- though YAML 1.2 reads neither as a number.

-- A run of `cls` digits with single `_` separators between them, as
-- Zig's `parseFloat` accepts: `1_000`, never `1__0` or `1_`.
local function zig_run(s, cls)
  if s == "" or find(s, "__", 1, true) or at(s, #s - 1) == 95 then return false end
  return s:match("^[" .. cls .. "][" .. cls .. "_]*$") ~= nil
end

-- Zig's `parseFloat` over `body`: a mantissa of `cls` digits with an
-- optional fraction, and an optional `expc` exponent of decimal digits.
local function zig_float(body, cls, expc)
  local mantissa, exponent = body:match("^(.-)([" .. expc .. "][-+]?[%d_]*)$")
  if exponent then
    if not zig_run((exponent:gsub("^[" .. expc .. "][-+]?", "")), "%d") then return false end
  else
    mantissa = body
  end
  local int_part, frac = mantissa:match("^([^.]*)%.([^.]*)$")
  if not int_part then int_part = mantissa end
  if int_part ~= "" and not zig_run(int_part, cls) then return false end
  if frac ~= nil and frac ~= "" and not zig_run(frac, cls) then return false end
  return int_part ~= "" or (frac ~= nil and frac ~= "")
end

local function looks_numeric(s)
  local lower = s:lower()
  if find(lower, "inf", 1, true) or find(lower, "nan", 1, true) then return false end
  local body = s:match("^[-+](.*)$") or s
  -- Zig's `parseInt`, which takes an `_` anywhere but at either end
  if body:match("^%d$") or body:match("^%d[%d_]*%d$") then return true end
  local hex = body:match("^0[xX](.*)$")
  if hex then return zig_float(hex, "%x", "pP") end
  return zig_float(body, "%d", "eE")
end

local NON_STRING_KEYWORDS = {
  "null", "Null", "NULL", "~", "true", "True", "TRUE", "false", "False", "FALSE",
  ".inf", ".Inf", ".INF", "-.inf", "-.Inf", "-.INF", "+.inf", ".nan", ".NaN", ".NAN",
}

local function resolves_to_non_string(s)
  if eql_any(s, NON_STRING_KEYWORDS) then return true end
  return looks_numeric(s)
end

local function has_control_char(s)
  return find(s, "[%z\1-\31\127]") ~= nil
end

local function needs_quoting(s)
  if #s == 0 then return true end
  if resolves_to_non_string(s) then return true end
  if at(s, 0) == SP or at(s, #s - 1) == SP then return true end
  local c = at(s, 0)
  if c == BANG or c == AMP or c == STAR or c == QUEST or c == PIPE or c == GT or c == PCT or c == 64 or c == 96
    or c == DQ or c == SQ or c == HASH or c == COMMA or c == LBRACK or c == RBRACK or c == LBRACE or c == RBRACE then
    return true
  end
  if (c == DASH or c == COLON) and (#s == 1 or at(s, 1) == SP) then return true end
  if find(s, ": ", 1, true) then return true end
  if at(s, #s - 1) == COLON then return true end
  if find(s, " #", 1, true) then return true end
  return false
end

local function contains_flow_indicator(s)
  return find(s, "[,%[%]{}]") ~= nil
end

local function single_quoted_text(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local function double_quoted_text(s)
  return '"' .. s:gsub('[%z\1-\31\127"\\]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == "\\" then return "\\\\" end
    if ch == "\n" then return "\\n" end
    if ch == "\t" then return "\\t" end
    if ch == "\r" then return "\\r" end
    return string.format("\\x%02x", ch:byte())
  end) .. '"'
end

local function scalar_text(raw)
  if has_control_char(raw) then return double_quoted_text(raw) end
  if needs_quoting(raw) then return single_quoted_text(raw) end
  return raw
end

local function flow_scalar_text(raw)
  if not has_control_char(raw) and not needs_quoting(raw) and contains_flow_indicator(raw) then
    return single_quoted_text(raw)
  end
  return scalar_text(raw)
end

local function block_scalar_ok(s)
  if not find(s, "\n", 1, true) then return false end
  if sub(s, -2) == "\n\n" then return false end
  local body = sub(s, -1) == "\n" and sub(s, 1, -2) or s
  local first_content = true
  for line in (body .. "\n"):gmatch("(.-)\n") do
    if #line > 0 then
      local c0 = at(line, 0)
      if first_content and (c0 == SP or c0 == TAB) then return false end
      first_content = false
      local cl = at(line, #line - 1)
      if cl == SP or cl == TAB then return false end
      if find(line, "[%z\1-\8\10-\31\127]") then return false end
    end
  end
  return true
end

local function tag_handle_of(text)
  if #text == 0 or at(text, 0) ~= BANG then return nil end
  if #text > 1 and at(text, 1) == LT then return nil end
  local close = find(text, "!", 2, true)
  if not close then return sub(text, 1, 1) end
  return sub(text, 1, close)
end

local Pr = {}
Pr.__index = Pr

function Pr:put(...)
  local out = self.out
  for i = 1, select("#", ...) do out[#out + 1] = select(i, ...) end
end

function Pr:indent(depth)
  if depth > 0 then self.out[#self.out + 1] = string.rep("  ", depth) end
end

-- The byte width of what `fn` writes.
function Pr:measure(fn, ...)
  local saved = self.out
  self.out = {}
  fn(self, ...)
  local w = #concat(self.out)
  self.out = saved
  return w
end

local function has_props(row) return row.anchor ~= nil or row.tag ~= nil end

local function comments_empty(row)
  return #row.leading == 0 and #row.trailing == 0 and #row.dangling == 0
end

local function leading_anchor(row)
  if row.kind == "keyvalue" then return row.key end
  return row
end

function Pr:comment_lines(list, depth)
  local w = fig.writer()
  w:comments(list, "#", depth)
  self:put(w:string())
end

function Pr:leading_comments(row, depth) self:comment_lines(row.leading, depth) end
function Pr:dangling_comments(row, depth) self:comment_lines(row.dangling, depth) end

function Pr:trailing_comment(row)
  local c = row.trailing[1]
  if not c then return end
  self:put(" #")
  if #c.text ~= 0 then self:put(" ", (c.text:gsub("\n", " "))) end
end

function Pr:props(row)
  if row.anchor then self:put("&", row.anchor, " ") end
  if row.tag then self:put(row.tag, " ") end
end

function Pr:props_own_line(row)
  local wrote = false
  if row.anchor then
    self:put("&", row.anchor)
    wrote = true
  end
  if row.tag then
    if wrote then self:put(" ") end
    self:put(row.tag)
  end
  self:put("\n")
end

function Pr:props_after_colon(row)
  if row.anchor then self:put(" &", row.anchor) end
  if row.tag then self:put(" ", row.tag) end
end

-- The text a scalar row is written as, or nil when the row is not a
-- scalar: a number respelled for YAML, a string quoted exactly when its
-- plain form would read back as something else, an `ext_kind`'s lexeme
-- as it stands. `flow` quotes a string a flow indicator would cut short.
function Pr:scalar_word(row, flow)
  local k = row.kind
  if row.ext_kind then
    if row.ext_kind == "enum_literal" then return scalar_text(row.text) end
    return row.text
  end
  if k == "null" then return "null" end
  if k == "bool" then return row.text end
  if k == "int" or k == "float" then return number_text(row.text) end
  if k == "string" then
    if flow then return flow_scalar_text(row.text) end
    return scalar_text(row.text)
  end
  return nil
end

function Pr:scalar_key(row)
  local w = self:scalar_word(row)
  if w then
    self:put(w)
  elseif row.kind == "alias" then
    self:put("*", row.text, " ")
  end
end

function Pr:key_lead(row)
  self:props(row)
  self:scalar_key(row)
end

function Pr:key_cols(row)
  return self:measure(Pr.key_lead, row)
end

function Pr:flow_eligible(row)
  if not comments_empty(row) then return false end
  if has_props(row) then return false end
  local k = row.kind
  if row.ext_kind then return false end
  if k == "null" or k == "bool" or k == "int" or k == "float" then return true end
  if k == "string" then return not find(row.text, "\n", 1, true) end
  if k == "alias" or k == "keyvalue" then return false end
  if k == "sequence" then
    for _, el in ipairs(row.items) do
      if el.kind == "mapping" then return false end
      if not self:flow_eligible(el) then return false end
    end
    return true
  end
  for _, kv in ipairs(row.items) do
    if not comments_empty(kv) then return false end
    if not comments_empty(kv.key) then return false end
    local kk = kv.key.kind
    if kv.key.ext_kind then return false end
    if kk == "string" then
      if find(kv.key.text, "\n", 1, true) then return false end
    elseif not (kk == "null" or kk == "bool" or kk == "int" or kk == "float") then
      return false
    end
    if kv.value.kind == "mapping" then return false end
    if not self:flow_eligible(kv.value) then return false end
  end
  return true
end

function Pr:flow(row)
  local k = row.kind
  local w = self:scalar_word(row, true)
  if w then
    self:put(w)
  elseif k == "sequence" then
    if #row.items == 0 then
      self:put("[]")
      return
    end
    self:put("[")
    for i, el in ipairs(row.items) do
      if i > 1 then self:put(", ") end
      self:flow(el)
    end
    self:put("]")
  elseif k == "mapping" then
    if #row.items == 0 then
      self:put("{}")
      return
    end
    self:put("{ ")
    for i, kv in ipairs(row.items) do
      if i > 1 then self:put(", ") end
      self:put(self:scalar_word(kv.key, true))
      self:put(": ")
      self:flow(kv.value)
    end
    self:put(" }")
  end
end

function Pr:flow_fits(row, prefix)
  if not self:flow_eligible(row) then return false end
  return prefix + self:measure(Pr.flow, row) <= self.width
end

function Pr:inline_value(row)
  self:props(row)
  local k = row.kind
  local w = self:scalar_word(row)
  if w then
    self:put(w)
  elseif k == "sequence" then
    self:put(#row.items == 0 and "[]" or "[...]")
  elseif k == "mapping" then
    self:put(#row.items == 0 and "{}" or "{...}")
  elseif k == "alias" then
    self:put("*", row.text)
  end
end

function Pr:block_scalar(s, indent)
  local clip = sub(s, -1) == "\n"
  self:put(clip and "|\n" or "|-\n")
  local body = clip and sub(s, 1, -2) or s
  for line in (body .. "\n"):gmatch("(.-)\n") do
    if #line == 0 then
      self:put("\n")
    else
      self:indent(indent)
      self:put(line, "\n")
    end
  end
end

function Pr:try_block_string_value(row, indent)
  if row.kind ~= "string" or row.ext_kind then return false end
  if not block_scalar_ok(row.text) then return false end
  self:props(row)
  self:block_scalar(row.text, indent)
  return true
end

function Pr:explicit_key(key, depth)
  if self:flow_fits(key, 2 * depth + 2) then
    self:put("? ")
    self:flow(key)
    self:put("\n")
  else
    self:put("?")
    self:props_after_colon(key)
    self:put("\n")
    self:node(key, depth + 1)
  end
  self:indent(depth)
end

function Pr:key_value(kv, depth, skip_indent)
  local value = kv.value
  if not skip_indent then self:indent(depth) end
  local value_prefix
  local kk = kv.key.kind
  if kk == "sequence" or kk == "mapping" then
    self:explicit_key(kv.key, depth)
    value_prefix = 2 * depth + 2
  else
    self:key_lead(kv.key)
    value_prefix = 2 * depth + self:key_cols(kv.key) + 2
  end
  local vk = value.kind
  if vk == "mapping" then
    if #value.items > 0 and self:flow_fits(value, value_prefix) then
      self:put(": ")
      self:flow(value)
      self:put("\n")
      return
    end
    self:put(":")
    self:props_after_colon(value)
    if #value.items == 0 then
      self:put(" {}\n")
    else
      self:trailing_comment(value)
      self:put("\n")
      self:mapping(value, depth + 1)
    end
  elseif vk == "sequence" then
    if #value.items > 0 and self:flow_fits(value, value_prefix) then
      self:put(": ")
      self:flow(value)
      self:put("\n")
      return
    end
    self:put(":")
    self:props_after_colon(value)
    if #value.items == 0 then
      self:put(" []\n")
    else
      self:trailing_comment(value)
      self:put("\n")
      self:sequence(value, depth)
    end
  else
    self:put(": ")
    if not self:try_block_string_value(value, depth + 1) then
      self:inline_value(value)
      self:trailing_comment(value)
      self:put("\n")
    end
  end
end

function Pr:mapping(row, depth)
  if #row.items == 0 then
    self:put("{}\n")
    return
  end
  for _, kv in ipairs(row.items) do
    self:leading_comments(leading_anchor(kv), depth)
    self:key_value(kv, depth, false)
  end
end

function Pr:sequence_mapping(row, depth)
  self:key_value(row.items[1], depth + 1, true)
  for i = 2, #row.items do
    local kv = row.items[i]
    self:leading_comments(leading_anchor(kv), depth + 1)
    self:key_value(kv, depth + 1, false)
  end
end

local function seq_item_lead_anchor(item)
  if item.kind == "mapping" and #item.items > 0 then return item.items[1].key end
  return item
end

function Pr:sequence(row, depth)
  if #row.items == 0 then
    self:put("[]\n")
    return
  end
  for _, item in ipairs(row.items) do
    self:leading_comments(seq_item_lead_anchor(item), depth)
    self:indent(depth)
    local k = item.kind
    if k == "mapping" then
      self:put("- ")
      if #item.items > 0 then
        if has_props(item) then
          self:props_own_line(item)
          self:mapping(item, depth + 1)
        else
          self:sequence_mapping(item, depth)
        end
      else
        self:props(item)
        self:put("{}\n")
      end
    elseif k == "sequence" then
      if #item.items == 0 then
        self:put("- ")
        self:props(item)
        self:put("[]\n")
      elseif has_props(item) then
        self:put("- ")
        self:props_own_line(item)
        self:sequence(item, depth + 1)
      else
        self:put("-\n")
        self:sequence(item, depth + 1)
      end
    else
      self:put("- ")
      if not self:try_block_string_value(item, depth + 1) then
        self:inline_value(item)
        self:trailing_comment(item)
        self:put("\n")
      end
    end
  end
end

function Pr:node(row, depth)
  local k = row.kind
  local w = self:scalar_word(row)
  if w then
    self:put(w, "\n")
  elseif k == "sequence" then
    self:sequence(row, depth)
  elseif k == "mapping" then
    self:mapping(row, depth)
  elseif k == "keyvalue" then
    self:key_value(row, depth, false)
  elseif k == "alias" then
    self:put("*", row.text, "\n")
  end
end

function Pr:root_node(root)
  if not has_props(root) then return self:node(root, 0) end
  if (root.kind == "sequence" or root.kind == "mapping") and #root.items > 0 then
    self:props_own_line(root)
    if root.kind == "sequence" then self:sequence(root, 0) else self:mapping(root, 0) end
    return
  end
  self:props(root)
  self:node(root, 0)
end

function Pr:handle_is_used(handle)
  for _, row in ipairs(self.t.rows) do
    if row.tag and tag_handle_of(row.tag) == handle then return true end
  end
  return false
end

function Pr:directives()
  local wrote = false
  for _, d in ipairs(self.t.directives) do
    if self:handle_is_used(d.handle) then
      self:put("%TAG ", d.handle, " ", d.prefix, "\n")
      wrote = true
    end
  end
  if wrote then self:put("---\n") end
end

function M.print(_dialect, t, options)
  fig.index(t)
  local pr = setmetatable({ t = t, out = {}, width = (options and options.width) or 80 }, Pr)
  local root = t.rows[1]
  pr:leading_comments(leading_anchor(root), 0)
  pr:directives()
  pr:root_node(root)
  pr:dangling_comments(root, 0)
  return concat(pr.out)
end

return M
