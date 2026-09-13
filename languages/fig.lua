-- fig, in Lua: the twin of fig's own authoring dialect — the compiled
-- `fig` format, `.figl` — row for row, region for region, mention for
-- mention, marker for marker.
--
-- `fig lang check lua-fig --against fig <files…>` holds this script to the
-- compiled parser's node table on every file given, and this script is
-- written against `fig lang table -i fig`, which prints that table. What
-- the compiled format accepts is stated in fig's `src/languages/fig/`
-- (`DESIGN.md`, `tokenizer.zig`, `parser.zig`, `printer.zig`), and this
-- follows the parser and the printer function for function.
--
-- The shape, as the compiled parser builds it:
--
--   * a line's depth is its count of leading `>` markers, relative to the
--     header that last re-anchored the baseline; a bare word opens a
--     container (a *section*), `key = value` assigns, `> *` is an element,
--     `a.b[]` appends an element and `+` appends another;
--   * the root is a mapping (or a sequence of `*` elements) spanning from
--     0 to the end of its last child; a block container spans from its
--     creating key (an element from the byte after its `*` prefix, an
--     appended element from its header line's start) to the end of its
--     last child; a flow `[…]`/`{…}` spans its brackets; a keyvalue runs
--     from its key to its value's end and records its `=` as `sep` — a
--     header's or dotted segment's is zero-width at the key's end; an
--     element records its `*` as `marker`;
--   * a block container's *regions* are the line that created it and
--     every later header line that re-opened it by its final segment;
--     its *mentions* are its key and each such re-opening's key, all of
--     kind `entry` — a fig header sits on its parent's own lines;
--   * a bare value is sniffed literal-else-string: `null`, `true`,
--     `false`, a number with its lexeme kept verbatim, a datetime; a
--     `: type =` annotation is checked and kept as a `tag` (`!!int`,
--     `!!float`, `!!bool`, `!!str`), and `enum`/`char`/`float = inf` give
--     extended kinds; a char literal's text is its decimal codepoint;
--   * a comment line waits with its own depth: when a container closes,
--     a comment at or below its child depth dangles on it, a shallower
--     one leads the next key or element; a same-line `#` after a value
--     trails the value; what waits at the end dangles on the root;
--     comments inside a flow value are discarded.
--
-- The refusals are the compiled parser's, in its words and at its
-- offsets. What is not carried: the authoring-time warnings (a leading
-- zero kept as text, an indent that disagrees with its markers), which
-- have no row.

local M = {}

M.name = "lua-fig"
M.caps = { read = true, edit = true, serialize = true }
M.syntax = {
  comments = { style = "hash", line = { open = "#" }, trailing = { open = "#" } },
  kv_sep = " = ",
  flow_kv_sep_from_siblings = true,
  flow_map_pad = " ",
  empty_map_literal = "{}",
  -- The `>` run that opens a line is depth, not whitespace: a line the
  -- engine writes repeats it; one level is one `> ` cell, an element `* `.
  structural_indent = true,
  indent_unit = "> ",
  seq_item_marker = "* ",
  section_noun = "container",
}
M.dialects = {
  -- The compiled format owns `.figl` and `.fig`, and a compiled format's
  -- extension wins, so this is reached by `--lang lua-fig`.
  { name = "lua-fig", extensions = { "figl", "fig" }, splice = "literal", empty_doc_seed = "" },
}
M.samples = { "a = 1\ndatabase\n> host = localhost\n> port = 5432\n" }
-- What follows a key: ` = value`, or a block value re-printed as a nested
-- section one marker level below the key.
M.renderers = { "tail" }

-- ── errors, as the compiled parser words them ─────────────────────────────

local E = {
  FigForeignSyntaxColon = "`:` introduces a type, not a value; write `key = value`, or `key: type = value`",
  FigFlowBareKeyColon = "a bare key cannot take a `:` pair; write `key = 1` (fig) or `\"key\": 1` (JSON)",
  FigForeignSyntaxDash = "`-` is YAML's element marker; fig elements are `*` — write `> *` then `> > host = a.com` (a scalar element is `* value`)",
  FigForeignSyntaxBracket = "`[section]` / `[[x]]` is TOML; fig section headers are bare dotted paths — write `section`, or `x[]` to append an element",
  FigElementInlineField = "an element's fields go on following lines; write `> *` then `> > host = a.com`, not `* host = a.com`",
  FigRootMarker = "root keys carry zero markers; remove the `>` (a marker line needs a parent header above it)",
  FigSkippedLevel = "this line skips a nesting level; depth may only grow one `>` at a time — add the missing parent line, or drop the extra `>`",
  FigBadMarkerSeparator = "put a space between the marker run and what follows: `> key`, not `>key`",
  FigBadKey = "empty or malformed key; a bare key cannot contain `.` `:` `=` `[` or whitespace, or begin with `>`/`-` — quote it: `\"my.key\" = x`",
  FigDuplicateKey = "duplicate key: this key already has a value here; remove one of the definitions (re-enter a header only to add NEW keys)",
  FigMixedContainerChildren = "a container holds either `key = value` entries or `*` elements, never both",
  FigMixedSequenceAddressing = "one sequence cannot mix `[]`/`[i]` addressing with `*` element lines; pick one spelling",
  FigKeyNotContainer = "this path steps into an existing non-container value; remove the extra path segment, or restructure the earlier value",
  FigIndexSkipped = "sequence indices cannot skip ahead; write the earlier element first (even `[n] = null`)",
  FigIndexAlreadySet = "this index already has a value; address a new index, or use a header-final `[]` to append",
  FigEmptyAppendTarget = "a non-final `[]` means \"the last element\", but this sequence is empty; append one first with a header-final `[]`",
  FigAppendAssignment = "a final `[]` appends a container via a header, never a `= value`; write `key[]` on its own line with `> field = value` lines below, or spell the next index out: `key[N] = value`",
  FigEmptyContainer = "this container has no children; write an inline empty value instead: `key = {}` (map) or `key = []` (sequence)",
  FigInvalidValue = "missing value; write one after `=`, or `{}`/`[]` for an empty container",
  FigTypeMismatch = "the value does not satisfy its `: type` annotation; fix the value, or drop/correct the annotation",
  FigUnknownType = "unknown type name; the built-in types are int, float, bool, string, enum, char, datetime, date, time",
  FigTrailingContent = "unexpected content after this line's value or header; quote the whole value if it is one string (a `#` comment needs a space before it)",
  FigQuotedTrailingContent = "this string ends at its matching quote, and the rest of the line is stray content; fig bare strings need no outer quotes — write `key = She said, \"Hey there!\"`, or escape the inner quotes: `\"She said, \\\"Hey there!\\\"\"`",
  FigMultilineOpenerContent = "a multiline string's content begins on the line AFTER the opening `'''`/`\"\"\"`; move this text down a line (only a `# comment` may share the opener line)",
  FigDanglingContinuation = "`+` has no `[]` append header to re-run; move it directly after its `a.b[]` group, or repeat the header",
  FigClosedFlowValue = "a value written inline as `[…]`/`{…}` is closed and cannot be extended later; write the block or header form if it needs to grow",
  FigUnclosedFlow = "this `[`/`{` value never finds its matching close; close it, or quote the whole value to make it a string",
  FigMixedFlowSeparators = "a flow object is fig (`=` pairs) or JSON (`:` pairs), never both in one object",
  FigUnclosedString = "unclosed string; add the closing quote (a single-line quote cannot span lines — use `'''` for multi-line)",
  FigBadEscape = "invalid escape; double quotes support \\n \\t \\r \\\\ \\\" \\uXXXX — use single quotes ('…') for raw text with literal backslashes",
}

-- ── lexical helpers, as `tokenizer.zig` ───────────────────────────────────

local function is_digit(c) return c >= 48 and c <= 57 end
local function is_hex(c) return is_digit(c) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102) end
local function is_octal(c) return c >= 48 and c <= 55 end
local function is_binary(c) return c == 48 or c == 49 end
local function is_alnum(c) return is_digit(c) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) end
local function is_bare_key_char(c) return is_alnum(c) or c == 95 or c == 45 end

-- A digit run at 1-based `start` with `_` separators anchored between
-- digits; the 1-based index just past it, or nil.
local function scan_underscored(s, start, pred)
  local j = start
  local prev_us = true
  while j <= #s do
    local c = s:byte(j)
    if c == 95 then
      if prev_us then return nil end
      prev_us = true
    elseif pred(c) then
      prev_us = false
    else
      break
    end
    j = j + 1
  end
  if prev_us then return nil end
  return j
end

-- TOML-style bare number: "int"/"float", or nil.
local function sniff_number(token)
  if token == "" then return nil end
  local i = 1
  local f = token:byte(1)
  if f == 43 or f == 45 then i = 2 end
  if i > #token then return nil end
  local body = token:sub(i)
  if #body >= 2 and body:byte(1) == 48 then
    local r = body:byte(2)
    local pred = (r == 120 and is_hex) or (r == 111 and is_octal) or (r == 98 and is_binary) or nil
    if pred then
      local e = scan_underscored(body, 3, pred)
      if not e or e ~= #body + 1 then return nil end
      return "int"
    end
  end
  local j = scan_underscored(token, i, is_digit)
  if not j then return nil end
  if j - i > 1 and token:byte(i) == 48 then return nil end
  local is_float = false
  if j <= #token and token:byte(j) == 46 then
    is_float = true
    j = scan_underscored(token, j + 1, is_digit)
    if not j then return nil end
  end
  if j <= #token and (token:byte(j) == 101 or token:byte(j) == 69) then
    is_float = true
    j = j + 1
    if j <= #token and (token:byte(j) == 43 or token:byte(j) == 45) then j = j + 1 end
    j = scan_underscored(token, j, is_digit)
    if not j then return nil end
  end
  if j ~= #token + 1 then return nil end
  return is_float and "float" or "int"
end

-- RFC 3339, as fig's shared `util.datetime` classifies it (minute
-- precision and a bare time both allowed here).
local function two(s, at) return tonumber(s:sub(at, at + 1)) end
local function both_digits(s, at)
  local a, b = s:byte(at), s:byte(at + 1)
  return a ~= nil and b ~= nil and is_digit(a) and is_digit(b)
end
local function days_in_month(year, month)
  if month == 2 then
    return ((year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0) and 29 or 28
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
  return day >= 1 and day <= days_in_month(year, month)
end
local function valid_time(s)
  if #s < 5 or s:sub(3, 3) ~= ":" then return false end
  if not (both_digits(s, 1) and both_digits(s, 4)) then return false end
  if two(s, 1) > 23 or two(s, 4) > 59 then return false end
  if #s == 5 then return true end
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
local function classify_datetime(raw)
  if #raw >= 3 and raw:sub(3, 3) == ":" then return valid_time(raw) and "local_time" or nil end
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
  if not valid_time(time_str) then return nil end
  return has_offset and "offset_datetime" or "local_datetime"
end

-- Literal-else-string: `{kind=…}` for a trimmed bare token.
local function sniff_bare(token)
  if token == "" then return { kind = "string", text = token } end
  if token == "null" then return { kind = "null" } end
  if token == "true" or token == "false" then return { kind = "bool", text = token } end
  local n = sniff_number(token)
  if n then return { kind = n, text = token } end
  local d = classify_datetime(token)
  if d then return { kind = "string", text = token, ext_kind = d } end
  return { kind = "string", text = token }
end

-- Whether a `'`/`"` at this point opens a quoted span: only at an element
-- start, after `[`, `{`, `,`, `:` or `=` (or nothing yet). `prev` is the
-- last non-whitespace byte, 0 at the start.
local function quote_opens_span(prev)
  return prev == 0 or prev == 91 or prev == 123 or prev == 44 or prev == 58 or prev == 61
end

-- The index just past a single-line quoted span opening at 0-based
-- `start`, or nil when it does not close before the newline.
local function skip_quoted_span(src, start)
  local q = src:byte(start + 1)
  local i = start + 1
  while i < #src and src:byte(i + 1) ~= 10 do
    local c = src:byte(i + 1)
    if q == 34 and c == 92 then
      i = i + 2
    else
      if c == q then return i + 1 end
      i = i + 1
    end
  end
  return nil
end

-- The matching close for the `[`/`{` at 0-based `start`, scanning to the
-- first newline, quoted spans skipped; nil when it never closes.
local function bracket_close_index(src, start)
  local depth = 0
  local i = start
  local prev = 0
  while i < #src and src:byte(i + 1) ~= 10 do
    local c = src:byte(i + 1)
    if c == 32 or c == 9 or c == 13 then
      i = i + 1
    elseif c == 39 or c == 34 then
      local opens = quote_opens_span(prev)
      prev = c
      if opens then
        i = skip_quoted_span(src, i)
        if not i then return nil end
      else
        i = i + 1
      end
    elseif c == 91 or c == 123 then
      depth = depth + 1
      prev = c
      i = i + 1
    elseif c == 93 or c == 125 then
      depth = depth - 1
      prev = c
      i = i + 1
      if depth == 0 then return i - 1 end
    else
      prev = c
      i = i + 1
    end
  end
  return nil
end

local function rest_is_comment_only(src, from)
  local i = from
  local saw_space = false
  while i < #src do
    local c = src:byte(i + 1)
    if c == 32 or c == 9 or c == 13 then
      saw_space = true
      i = i + 1
    else
      break
    end
  end
  if i >= #src or src:byte(i + 1) == 10 then return true end
  return saw_space and src:byte(i + 1) == 35
end

-- "flow", "bare_trailing" or "unclosed": how a `[`/`{`-led block value
-- commits.
local function classify_bracket_commit(src, start)
  local close = bracket_close_index(src, start)
  if not close then return "unclosed" end
  return rest_is_comment_only(src, close + 1) and "flow" or "bare_trailing"
end

local function flow_rest_is_terminator(src, from)
  local i = from
  while i < #src and (src:byte(i + 1) == 32 or src:byte(i + 1) == 9 or src:byte(i + 1) == 13) do i = i + 1 end
  if i >= #src then return true end
  local c = src:byte(i + 1)
  return c == 44 or c == 93 or c == 125 or c == 10 or c == 35
end

-- "flow" or "bare_trailing": the flow-element twin, across newlines.
local function classify_flow_bracket(src, start)
  local depth = 0
  local i = start
  local prev = 0
  while i < #src do
    local c = src:byte(i + 1)
    if c == 32 or c == 9 or c == 13 or c == 10 then
      i = i + 1
    elseif c == 39 or c == 34 then
      local opens = quote_opens_span(prev)
      prev = c
      if opens then
        i = skip_quoted_span(src, i)
        if not i then return "flow" end
      else
        i = i + 1
      end
    elseif c == 91 or c == 123 then
      depth = depth + 1
      prev = c
      i = i + 1
    elseif c == 93 or c == 125 then
      depth = depth - 1
      prev = c
      i = i + 1
      if depth == 0 then return flow_rest_is_terminator(src, i) and "flow" or "bare_trailing" end
    else
      prev = c
      i = i + 1
    end
  end
  return "flow"
end

-- ── the parser ────────────────────────────────────────────────────────────
-- A line loop over an intermediate tree of containers, entries and nodes,
-- converted to the wire's tree at the end, as the compiled parser does;
-- `pos` is a 0-based byte offset and is where a refusal points unless a
-- site pins another.

local P = {}
P.__index = P

local function fail(message, at) fig.fail(message, at) end

function P:peek()
  if self.pos < self.n then return self.src:byte(self.pos + 1) end
  return nil
end
function P:at(i) return self.src:byte(i + 1) end
function P:advance() if self.pos < self.n then self.pos = self.pos + 1 end end
function P:fail(name) fail(E[name], self.pos) end
function P:fail_at(at, name) fail(E[name], at) end
function P:skip_spaces_tabs()
  while self.pos < self.n do
    local c = self:at(self.pos)
    if c ~= 32 and c ~= 9 then break end
    self.pos = self.pos + 1
  end
end
function P:is_crlf_at(pos)
  return pos < self.n and self:at(pos) == 13 and (pos + 1 >= self.n or self:at(pos + 1) == 10)
end
function P:at_crlf() return self:is_crlf_at(self.pos) end
function P:at_end_of_content()
  local p = self:peek()
  return p == nil or p == 10 or p == 35 or self:at_crlf()
end
function P:at_true_line_end()
  local p = self:peek()
  return p == nil or p == 10 or self:at_crlf()
end
function P:skip_to_next_line()
  if self:at_crlf() then self.pos = self.pos + 1 end
  if self.pos < self.n and self:at(self.pos) == 10 then self.pos = self.pos + 1 end
end
function P:consume_line_end()
  while self.pos < self.n and self:at(self.pos) ~= 10 do self.pos = self.pos + 1 end
  self:skip_to_next_line()
end
function P:is_triple_at(pos, q)
  return pos + 3 <= self.n and self:at(pos) == q and self:at(pos + 1) == q and self:at(pos + 2) == q
end

-- Trim spaces, tabs and `\r` from both ends of `[s, e)`; the trimmed span.
local function trim_span(src, s, e)
  while s < e do
    local c = src:byte(s + 1)
    if c ~= 32 and c ~= 9 and c ~= 13 then break end
    s = s + 1
  end
  while e > s do
    local c = src:byte(e)
    if c ~= 32 and c ~= 9 and c ~= 13 then break end
    e = e - 1
  end
  return s, e
end

-- ── containers, entries, nodes ──

local function new_container()
  return { kind = "undecided", closed = false, born_of_append = false, entries = {}, index = {}, elements = {}, style = "undecided", reentries = {}, reentry_names = {} }
end

local function new_node(value, span)
  return { value = value, span = span or { 0, 0 }, leading = {}, dangling = {} }
end

function P:open(c)
  if c.closed then self:fail("FigClosedFlowValue") end
  return c
end

function P:as_mapping(c)
  if c.kind == "undecided" then c.kind = "mapping" end
  if c.kind == "sequence" then self:fail("FigMixedContainerChildren") end
  return c
end

function P:as_sequence(c)
  if c.kind == "undecided" then c.kind = "sequence" end
  if c.kind == "mapping" then self:fail("FigMixedContainerChildren") end
  return c
end

function P:mark_element(c)
  if c.style == "undecided" then c.style = "element" elseif c.style == "addressed" then self:fail("FigMixedSequenceAddressing") end
end

function P:mark_addressed(c)
  if c.style == "undecided" then c.style = "addressed" elseif c.style == "element" then self:fail("FigMixedSequenceAddressing") end
end

local function add_entry(m, entry)
  m.entries[#m.entries + 1] = entry
  m.index[entry.key] = entry
end

-- ── quoted strings ──

-- `'…'`: raw. Returns text and the index past the close.
function P:scan_single_quoted(start)
  local body = start + 1
  local i = body
  while i < self.n do
    local c = self:at(i)
    if c == 39 then return self.src:sub(body + 1, i), i + 1 end
    if c == 10 then fail(E.FigUnclosedString, self.pos) end
    i = i + 1
  end
  fail(E.FigUnclosedString, self.pos)
end

-- One `\…` escape at 0-based `i` in `s`; the decoded text and the index
-- just past it. `at` is where a bad one is reported.
local function decode_escape(s, i, at)
  if i + 1 >= #s then fail(E.FigBadEscape, at) end
  local e = s:sub(i + 2, i + 2)
  if e == "n" then return "\n", i + 2 end
  if e == "t" then return "\t", i + 2 end
  if e == "r" then return "\r", i + 2 end
  if e == "\\" then return "\\", i + 2 end
  if e == '"' then return '"', i + 2 end
  if e == "'" then return "'", i + 2 end
  if e == "u" then
    if i + 6 > #s then fail(E.FigBadEscape, at) end
    local hex = s:sub(i + 3, i + 6)
    if not hex:match("^%x%x%x%x$") then fail(E.FigBadEscape, at) end
    local cp = tonumber(hex, 16)
    if cp >= 0xD800 and cp <= 0xDFFF then fail(E.FigBadEscape, at) end
    return utf8.char(cp), i + 6
  end
  fail(E.FigBadEscape, at)
end

-- `"…"`: escaped.
function P:scan_double_quoted(start)
  local out = {}
  local i = start + 1
  while i < self.n do
    local c = self:at(i)
    if c == 10 then fail(E.FigUnclosedString, self.pos) end
    if c == 34 then return table.concat(out), i + 1 end
    if c == 92 then
      local text, nxt = decode_escape(self.src, i, self.pos)
      out[#out + 1] = text
      i = nxt
    else
      out[#out + 1] = string.char(c)
      i = i + 1
    end
  end
  fail(E.FigUnclosedString, self.pos)
end

-- `'''`/`"""` at `start`: the text, the index past the close, and the
-- opener line's comment if any.
function P:scan_triple(start, q, dedent_and_escape)
  local src = self.src
  local i = start + 3
  local opener_comment
  while i < self.n and self:at(i) ~= 10 do
    if self:at(i) == 35 then
      local cstart = i + 1
      local j = cstart
      while j < self.n and self:at(j) ~= 10 do j = j + 1 end
      opener_comment = src:sub(cstart + 1, j):match("^[ \t\r]*(.-)[ \t\r]*$")
      i = j
      break
    end
    i = i + 1
  end
  if i < self.n and self:at(i) == 10 then i = i + 1 end
  local body_start = i
  local line_start = body_start
  local close_pos
  while line_start <= self.n do
    local nl = src:find("\n", line_start + 1, true)
    local line_end = nl and nl - 1 or self.n
    local j = line_start
    while j < line_end and (self:at(j) == 32 or self:at(j) == 9) do j = j + 1 end
    if j + 3 <= self.n and self:at(j) == q and self:at(j + 1) == q and self:at(j + 2) == q then
      close_pos = j
      break
    end
    if line_end >= self.n then fail(E.FigUnclosedString, self.pos) end
    line_start = line_end + 1
  end
  if not close_pos then fail(E.FigUnclosedString, self.pos) end
  local dedent = close_pos - line_start
  local body_end = line_start
  if body_end > body_start and self:at(body_end - 1) == 10 then body_end = body_end - 1 end
  if body_end > body_start and self:at(body_end - 1) == 13 then body_end = body_end - 1 end
  local body = body_end >= body_start and src:sub(body_start + 1, body_end) or ""
  local out = {}
  local first = true
  for raw_line in (body .. "\n"):gmatch("(.-)\n") do
    if not first then out[#out + 1] = "\n" end
    first = false
    local line = raw_line
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if dedent_and_escape then
      local stripped = 0
      while stripped < dedent and #line > 0 and (line:sub(1, 1) == " " or line:sub(1, 1) == "\t") do
        line = line:sub(2)
        stripped = stripped + 1
      end
      local k = 0
      while k < #line do
        if line:sub(k + 1, k + 1) == "\\" then
          local text, nxt = decode_escape(line, k, self.pos)
          out[#out + 1] = text
          k = nxt
        else
          out[#out + 1] = line:sub(k + 1, k + 1)
          k = k + 1
        end
      end
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out), close_pos + 3, opener_comment
end

-- ── comments and frames ──

function P:drain_pending()
  local out = {}
  for _, pc in ipairs(self.pending) do out[#out + 1] = pc.text end
  self.pending = {}
  return out
end

local function append_all(dst, src)
  for _, x in ipairs(src) do dst[#dst + 1] = x end
end

function P:close_frames_above(depth)
  while #self.stack > 0 and self.stack[#self.stack].child_depth > depth do
    local frame = table.remove(self.stack)
    if frame.container.kind == "undecided" then self:fail("FigEmptyContainer") end
    if frame.container.born_of_append and #frame.container.entries == 0 then self:fail("FigEmptyContainer") end
    if #self.pending > 0 then
      local keep = {}
      for _, pc in ipairs(self.pending) do
        if pc.depth >= frame.child_depth then
          frame.owner.dangling[#frame.owner.dangling + 1] = pc.text
        else
          keep[#keep + 1] = pc
        end
      end
      self.pending = keep
    end
  end
end

-- ── markers ──

function P:scan_markers()
  local count = 0
  local broke = false
  while self:peek() == 62 do
    count = count + 1
    self:advance()
    while self:peek() == 32 or self:peek() == 9 do
      local save = self.pos
      self:skip_spaces_tabs()
      if self:peek() == 42 then
        broke = true
        break
      end
      if self:peek() ~= 62 then
        self.pos = save
        break
      end
    end
    if broke then break end
  end
  if count > 0 and self:peek() == 45 then self:fail("FigForeignSyntaxDash") end
  if self:peek() == 42 then
    local star_span = { self.pos, self.pos + 1 }
    self:advance()
    if self:peek() == 32 or self:peek() == 9 then
      self:skip_spaces_tabs()
    elseif self:peek() == 58 then
      -- `*: type = v`: the `:` binds to the `*`, no separator needed.
    elseif not self:at_end_of_content() then
      self:fail("FigBadMarkerSeparator")
    end
    return count, true, star_span
  end
  if count > 0 then
    if self:peek() == 32 or self:peek() == 9 then
      self:skip_spaces_tabs()
    elseif not self:at_end_of_content() then
      self:fail("FigBadMarkerSeparator")
    end
  end
  return count, false, nil
end

-- ── key paths ──

function P:scan_key_seg()
  local c = self:peek()
  if c == nil then self:fail("FigBadKey") end
  local start = self.pos
  if c == 34 then
    local text, e = self:scan_double_quoted(self.pos)
    self.pos = e
    return { name = text, span = { start, e } }
  end
  if c == 39 then
    local text, e = self:scan_single_quoted(self.pos)
    self.pos = e
    return { name = text, span = { start, e } }
  end
  while self.pos < self.n and is_bare_key_char(self:at(self.pos)) do self.pos = self.pos + 1 end
  if self.pos == start then self:fail("FigBadKey") end
  local text = self.src:sub(start + 1, self.pos)
  local f = text:byte(1)
  if f == 45 or f == 62 then self:fail("FigBadKey") end
  return { name = text, span = { start, self.pos } }
end

function P:scan_index_seg()
  self:advance() -- [
  if self:peek() == 93 then
    self:advance()
    return { index = "append" }
  end
  local start = self.pos
  while self.pos < self.n and is_digit(self:at(self.pos)) do self.pos = self.pos + 1 end
  if self.pos == start or self:peek() ~= 93 then self:fail("FigBadKey") end
  local n = tonumber(self.src:sub(start + 1, self.pos))
  self:advance()
  return { index = n }
end

function P:scan_key_path()
  local steps = {}
  while true do
    steps[#steps + 1] = { key = self:scan_key_seg() }
    while self:peek() == 91 do steps[#steps + 1] = self:scan_index_seg() end
    if self:peek() == 46 then
      self:advance()
    else
      break
    end
  end
  return steps
end

-- ── path navigation ──

function P:get_or_create_map_container(m, seg)
  local e = m.index[seg.name]
  if e then
    if e.value.value.kind ~= "container" then self:fail("FigKeyNotContainer") end
    return self:open(e.value.value.container)
  end
  local child = new_container()
  local entry = { key = seg.name, key_span = seg.span, sep_span = { seg.span[2], seg.span[2] }, key_leading = {}, value = new_node({ kind = "container", container = child }, { seg.span[1], seg.span[2] }) }
  add_entry(m, entry)
  return child
end

function P:get_or_create_seq_container(s, idx)
  if idx == "append" then
    if #s.elements == 0 then self:fail("FigEmptyAppendTarget") end
    local last = s.elements[#s.elements]
    if last.value.kind ~= "container" then self:fail("FigKeyNotContainer") end
    return self:open(last.value.container)
  end
  if idx < #s.elements then
    local el = s.elements[idx + 1]
    if el.value.kind ~= "container" then self:fail("FigKeyNotContainer") end
    return self:open(el.value.container)
  elseif idx == #s.elements then
    local child = new_container()
    local el = new_node({ kind = "container", container = child }, { self.cur_line_start, self.cur_line_start })
    s.elements[#s.elements + 1] = el
    return child
  end
  self:fail("FigIndexSkipped")
end

function P:navigate_intermediate(start, steps)
  local cur = start
  for i = 1, #steps - 1 do
    local step = steps[i]
    if step.key then
      cur = self:get_or_create_map_container(self:as_mapping(cur), step.key)
    else
      local s = self:as_sequence(cur)
      self:mark_addressed(s)
      cur = self:get_or_create_seq_container(s, step.index)
    end
  end
  return cur
end

-- A header line's final segment: the container to push, its owner node,
-- and its entry when reached through a key.
function P:resolve_header_final(parent, last)
  if last.key then
    local k = last.key
    local m = self:as_mapping(parent)
    local e = m.index[k.name]
    if e then
      if e.value.value.kind ~= "container" then self:fail("FigDuplicateKey") end
      local c = self:open(e.value.value.container)
      c.reentries[#c.reentries + 1] = k.span[1]
      c.reentry_names[#c.reentry_names + 1] = k.span
      return c, e.value, e
    end
    local child = new_container()
    local entry = { key = k.name, key_span = k.span, sep_span = { k.span[2], k.span[2] }, key_leading = {}, value = new_node({ kind = "container", container = child }, { k.span[1], k.span[2] }) }
    add_entry(m, entry)
    return child, entry.value, entry
  end
  local s = self:as_sequence(parent)
  self:mark_addressed(s)
  local idx = last.index
  if idx == "append" then
    local child = new_container()
    child.born_of_append = true
    child.kind = "mapping"
    local el = new_node({ kind = "container", container = child }, { self.cur_line_start, self.cur_line_start })
    s.elements[#s.elements + 1] = el
    return child, el, nil
  end
  if idx < #s.elements then
    local el = s.elements[idx + 1]
    if el.value.kind ~= "container" then self:fail("FigKeyNotContainer") end
    local c = self:open(el.value.container)
    c.reentries[#c.reentries + 1] = self.cur_line_start
    return c, el, nil
  elseif idx == #s.elements then
    local child = new_container()
    local el = new_node({ kind = "container", container = child }, { self.cur_line_start, self.cur_line_start })
    s.elements[#s.elements + 1] = el
    return child, el, nil
  end
  self:fail("FigIndexSkipped")
end

-- ── values ──

-- A bare RHS to the end of the line, the `#`-after-whitespace rule
-- honoured; `pos` is left at the newline. Returns text, its span, and the
-- comment if any.
function P:scan_bare_rest_of_line()
  local start = self.pos
  local i = start
  local prev_space = true
  local comment_start
  while i < self.n and self:at(i) ~= 10 do
    local ch = self:at(i)
    if ch == 35 and prev_space then
      comment_start = i
      break
    end
    prev_space = (ch == 32 or ch == 9)
    i = i + 1
  end
  local value_end = comment_start or i
  local ts, te = trim_span(self.src, start, value_end)
  local comment
  local line_end = value_end
  if comment_start then
    local j = comment_start + 1
    while j < self.n and self:at(j) ~= 10 do j = j + 1 end
    comment = self.src:sub(comment_start + 2, j):match("^[ \t\r]*(.-)[ \t\r]*$")
    line_end = j
  end
  self.pos = line_end
  return self.src:sub(ts + 1, te), { ts, te }, comment
end

-- After a committed value: only whitespace and a `# comment` may follow.
function P:scan_trailing_comment_only()
  self:skip_spaces_tabs()
  if self.pos >= self.n or self:at(self.pos) == 10 or self:at_crlf() then return nil end
  if self:at(self.pos) == 35 then
    local cs = self.pos + 1
    local j = cs
    while j < self.n and self:at(j) ~= 10 do j = j + 1 end
    local c = self.src:sub(cs + 1, j):match("^[ \t\r]*(.-)[ \t\r]*$")
    self.pos = j
    return c
  end
  self:fail("FigTrailingContent")
end

function P:scan_flow_opener_comment()
  local i = self.pos + 1
  while i < self.n and (self:at(i) == 32 or self:at(i) == 9) do i = i + 1 end
  if i >= self.n or self:at(i) ~= 35 then return nil end
  local j = i + 1
  while j < self.n and self:at(j) ~= 10 do j = j + 1 end
  return self.src:sub(i + 2, j):match("^[ \t\r]*(.-)[ \t\r]*$")
end

local function sniff_to_node(text, span)
  local s = sniff_bare(text)
  if s.kind == "null" then return new_node({ kind = "null" }, span) end
  if s.kind == "bool" then return new_node({ kind = "bool", text = s.text }, span) end
  if s.kind == "int" or s.kind == "float" then return new_node({ kind = s.kind, text = s.text }, span) end
  if s.ext_kind then return new_node({ kind = "string", text = s.text, ext_kind = s.ext_kind }, span) end
  return new_node({ kind = "string", text = s.text }, span)
end

-- A decimal integer body once its leading zeros go, or nil when it is not
-- purely digits after a sign: the `: int`/`: float` coercion check.
local function normalize_decimal(text)
  local body = text
  local f = body:sub(1, 1)
  if f == "+" or f == "-" then body = body:sub(2) end
  if body == "" or not body:match("^%d+$") then return nil end
  return body
end

-- A ZON-style char literal `'A'`, `'\n'`, `'\u{1F600}'`: its codepoint, or
-- nil.
local function parse_char_literal(text)
  if #text < 3 or text:sub(1, 1) ~= "'" or text:sub(-1) ~= "'" then return nil end
  local inner = text:sub(2, -2)
  if inner:sub(1, 1) ~= "\\" then
    local ok = utf8.len(inner)
    if ok ~= 1 then return nil end
    return utf8.codepoint(inner)
  end
  local e = inner:sub(2, 2)
  if #inner == 2 then
    local simple = { n = 10, r = 13, t = 9, ["\\"] = 92, ["'"] = 39, ['"'] = 34 }
    return simple[e]
  end
  if e == "x" and #inner == 4 and inner:sub(3):match("^%x%x$") then return tonumber(inner:sub(3), 16) end
  if e == "u" then
    local hex = inner:match("^\\u{(%x+)}$")
    if not hex or #hex > 6 then return nil end
    local cp = tonumber(hex, 16)
    if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil end
    return cp
  end
  return nil
end

-- `key: type = value`: checked, coercing, and kept as a tag.
function P:apply_known_type(type_name, text, span)
  if type_name == "int" then
    local n = sniff_number(text)
    if n then
      if n ~= "int" then return nil end
      return new_node({ kind = "int", text = text, tag = "!!int" }, span)
    end
    if normalize_decimal(text) then return new_node({ kind = "int", text = text, tag = "!!int" }, span) end
    return nil
  elseif type_name == "float" then
    if text == "inf" or text == "-inf" or text == "nan" then
      return new_node({ kind = "string", text = text, ext_kind = "number_special" }, span)
    end
    if sniff_number(text) then return new_node({ kind = "float", text = text, tag = "!!float" }, span) end
    if text:sub(-1) == "." and #text >= 2 then
      if normalize_decimal(text:sub(1, -2)) then return new_node({ kind = "float", text = text, tag = "!!float" }, span) end
      return nil
    end
    if normalize_decimal(text) then return new_node({ kind = "float", text = text, tag = "!!float" }, span) end
    return nil
  elseif type_name == "bool" then
    if text == "true" or text == "false" then return new_node({ kind = "bool", text = text, tag = "!!bool" }, span) end
    return nil
  elseif type_name == "enum" then
    if text == "" then return nil end
    return new_node({ kind = "string", text = text, ext_kind = "enum_literal" }, span)
  elseif type_name == "char" then
    local cp = parse_char_literal(text)
    if not cp then return nil end
    return new_node({ kind = "int", text = string.format("%d", cp), ext_kind = "char_literal" }, span)
  elseif type_name == "datetime" or type_name == "date" or type_name == "time" then
    local k = classify_datetime(text)
    if not k then return nil end
    if type_name == "date" and k ~= "local_date" then return nil end
    if type_name == "time" and k ~= "local_time" then return nil end
    return new_node({ kind = "string", text = text, ext_kind = k }, span)
  end
  return nil, "FigUnknownType"
end

function P:parse_assigned_value(type_name)
  self:skip_spaces_tabs()
  if type_name then
    if type_name == "string" then
      local node = self:parse_untyped_value(true)
      node.value.tag = "!!str"
      return node
    end
    local text, span, comment = self:scan_bare_rest_of_line()
    if text == "" then self:fail("FigInvalidValue") end
    local node, why = self:apply_known_type(type_name, text, span)
    if not node then fail(E[why or "FigTypeMismatch"], span[1]) end
    node.trailing = comment
    return node
  end
  return self:parse_untyped_value(false)
end

function P:parse_untyped_value(force_string_bare)
  if force_string_bare then
    local text, span, comment = self:scan_bare_rest_of_line()
    if text == "" then self:fail("FigInvalidValue") end
    local node = new_node({ kind = "string", text = text }, span)
    node.trailing = comment
    return node
  end
  local c = self:peek()
  if c == nil then self:fail("FigInvalidValue") end
  if c == 39 or c == 34 then return self:parse_quoted_or_triple(c) end
  if c == 91 or c == 123 then
    if classify_bracket_commit(self.src, self.pos) == "bare_trailing" then
      local text, span, comment = self:scan_bare_rest_of_line()
      if text == "" then self:fail("FigInvalidValue") end
      local node = new_node({ kind = "string", text = text }, span)
      node.trailing = comment
      return node
    end
    local opener_comment = self:scan_flow_opener_comment()
    local node = self:parse_flow_value()
    local trailing = self:scan_trailing_comment_only()
    node.trailing = opener_comment or trailing
    return node
  end
  local text, span, comment = self:scan_bare_rest_of_line()
  if text == "" then self:fail("FigInvalidValue") end
  local node = sniff_to_node(text, span)
  node.trailing = comment
  return node
end

function P:parse_quoted_or_triple(q)
  local start = self.pos
  if self:is_triple_at(self.pos, q) then
    local j = self.pos + 3
    while j < self.n and (self:at(j) == 32 or self:at(j) == 9) do j = j + 1 end
    if j < self.n and self:at(j) ~= 10 and self:at(j) ~= 35 and not self:is_crlf_at(j) then
      self:fail_at(j, "FigMultilineOpenerContent")
    end
    local text, e, opener_comment = self:scan_triple(self.pos, q, q == 34)
    self.pos = e
    local node = new_node({ kind = "string", text = text }, { start, e })
    local trailing = self:scan_trailing_comment_only()
    node.trailing = opener_comment or trailing
    return node
  end
  local text, e
  if q == 39 then text, e = self:scan_single_quoted(self.pos) else text, e = self:scan_double_quoted(self.pos) end
  self.pos = e
  local node = new_node({ kind = "string", text = text }, { start, e })
  -- Stray content after the closing quote is the wrapped-bare-string slip,
  -- with its own message.
  self:skip_spaces_tabs()
  if not (self.pos >= self.n or self:at(self.pos) == 10 or self:at_crlf()) and self:at(self.pos) ~= 35 then
    self:fail("FigQuotedTrailingContent")
  end
  node.trailing = self:scan_trailing_comment_only()
  return node
end

-- ── flow ──

function P:skip_flow_ws()
  while self.pos < self.n do
    local c = self:at(self.pos)
    if c == 32 or c == 9 or c == 13 or c == 10 then
      self.pos = self.pos + 1
    elseif c == 35 then
      while self.pos < self.n and self:at(self.pos) ~= 10 do self.pos = self.pos + 1 end
    else
      return
    end
  end
end

function P:parse_flow_value()
  if self:peek() == 91 then return self:parse_flow_array() end
  return self:parse_flow_object()
end

function P:parse_flow_array()
  local open = self.pos
  self:advance()
  local seq = new_container()
  seq.closed = true
  seq.kind = "sequence"
  self:skip_flow_ws()
  if self:peek() == 93 then
    self:advance()
    return new_node({ kind = "container", container = seq }, { open, self.pos })
  end
  while true do
    seq.elements[#seq.elements + 1] = self:parse_flow_scalar_or_nested()
    self:skip_flow_ws()
    local p = self:peek()
    if p == nil then self:fail("FigUnclosedFlow") end
    if p == 44 then
      self:advance()
      self:skip_flow_ws()
      if self:peek() == 93 then
        self:advance()
        break
      end
    elseif p == 93 then
      self:advance()
      break
    else
      self:fail("FigUnclosedFlow")
    end
  end
  return new_node({ kind = "container", container = seq }, { open, self.pos })
end

local function is_flow_key_stop(c)
  return c == 44 or c == 93 or c == 125 or c == 58 or c == 61 or c == 32 or c == 9 or c == 10 or c == 13
end

function P:parse_flow_key()
  local c = self:peek()
  if c == nil then self:fail("FigBadKey") end
  local start = self.pos
  if c == 34 then
    local text, e = self:scan_double_quoted(self.pos)
    self.pos = e
    return { text = text, quoted = true, span = { start, e } }
  end
  if c == 39 then
    local text, e = self:scan_single_quoted(self.pos)
    self.pos = e
    return { text = text, quoted = true, span = { start, e } }
  end
  while self.pos < self.n and not is_flow_key_stop(self:at(self.pos)) do self.pos = self.pos + 1 end
  if self.pos == start then self:fail("FigBadKey") end
  return { text = self.src:sub(start + 1, self.pos), quoted = false, span = { start, self.pos } }
end

function P:parse_flow_object()
  local open = self.pos
  self:advance()
  local map = new_container()
  map.closed = true
  map.kind = "mapping"
  self:skip_flow_ws()
  if self:peek() == 125 then
    self:advance()
    return new_node({ kind = "container", container = map }, { open, self.pos })
  end
  local mode
  while true do
    local key = self:parse_flow_key()
    self:skip_flow_ws()
    local sep = self:peek()
    if sep == nil then self:fail("FigUnclosedFlow") end
    local this_mode
    if sep == 61 then
      this_mode = "fig"
    elseif sep == 58 then
      if not key.quoted then self:fail("FigFlowBareKeyColon") end
      this_mode = "json"
    else
      self:fail("FigUnclosedFlow")
    end
    if mode and mode ~= this_mode then self:fail("FigMixedFlowSeparators") end
    mode = this_mode
    self:advance()
    self:skip_flow_ws()
    local v = self:parse_flow_scalar_or_nested()
    if map.index[key.text] then self:fail("FigDuplicateKey") end
    add_entry(map, { key = key.text, key_span = key.span, key_leading = {}, value = v })
    self:skip_flow_ws()
    local p = self:peek()
    if p == nil then self:fail("FigUnclosedFlow") end
    if p == 44 then
      self:advance()
      self:skip_flow_ws()
      if self:peek() == 125 then
        self:advance()
        break
      end
    elseif p == 125 then
      self:advance()
      break
    else
      self:fail("FigUnclosedFlow")
    end
  end
  return new_node({ kind = "container", container = map }, { open, self.pos })
end

function P:scan_flow_bare_value()
  local start = self.pos
  local prev_space = false
  while self.pos < self.n do
    local ch = self:at(self.pos)
    if ch == 44 or ch == 93 or ch == 125 or ch == 10 then break end
    if ch == 35 and prev_space then break end
    prev_space = (ch == 32 or ch == 9)
    self.pos = self.pos + 1
  end
  local ts, te = trim_span(self.src, start, self.pos)
  return self.src:sub(ts + 1, te), { ts, te }
end

function P:scan_flow_bare_bracket()
  local start = self.pos
  local depth = 0
  local prev_space = false
  while self.pos < self.n do
    local ch = self:at(self.pos)
    if ch == 91 or ch == 123 then
      depth = depth + 1
    elseif ch == 93 or ch == 125 then
      if depth == 0 then break end
      depth = depth - 1
    elseif ch == 44 or ch == 10 then
      if depth == 0 then break end
    elseif ch == 35 then
      if prev_space and depth == 0 then break end
    end
    prev_space = (ch == 32 or ch == 9)
    self.pos = self.pos + 1
  end
  local ts, te = trim_span(self.src, start, self.pos)
  return self.src:sub(ts + 1, te), { ts, te }
end

function P:parse_flow_scalar_or_nested()
  self:skip_flow_ws()
  local c = self:peek()
  if c == nil then self:fail("FigUnclosedFlow") end
  if c == 91 or c == 123 then
    if classify_flow_bracket(self.src, self.pos) == "bare_trailing" then
      local text, span = self:scan_flow_bare_bracket()
      if text == "" then self:fail("FigInvalidValue") end
      return new_node({ kind = "string", text = text }, span)
    end
    return self:parse_flow_value()
  end
  if c == 34 or c == 39 then
    local start = self.pos
    local text, e
    if c == 34 then text, e = self:scan_double_quoted(self.pos) else text, e = self:scan_single_quoted(self.pos) end
    self.pos = e
    return new_node({ kind = "string", text = text }, { start, e })
  end
  local text, span = self:scan_flow_bare_value()
  if text == "" then self:fail("FigInvalidValue") end
  return sniff_to_node(text, span)
end

-- ── lines ──

function P:finish_header(target, steps, depth)
  if not self:at_end_of_content() then self:fail("FigTrailingContent") end
  local leading = self:drain_pending()
  local parent = self:navigate_intermediate(target, steps)
  local last = steps[#steps]
  local container, owner, entry = self:resolve_header_final(parent, last)
  if entry then append_all(entry.key_leading, leading) else append_all(owner.leading, leading) end
  local cm = self:scan_trailing_comment_only()
  if cm then owner.trailing = cm end
  self:consume_line_end()
  self.stack[#self.stack + 1] = { container = container, child_depth = depth + 1, owner = owner }
  if depth == 0 and last.index == "append" then self.last_append_steps = steps end
end

function P:finish_assignment(target, steps, type_name, sep)
  self:skip_spaces_tabs()
  local leading = self:drain_pending()
  local parent = self:navigate_intermediate(target, steps)
  local last = steps[#steps]
  local value_node = self:parse_assigned_value(type_name)
  self:consume_line_end()
  if last.key then
    local k = last.key
    local m = self:as_mapping(parent)
    if m.index[k.name] then fail(E.FigDuplicateKey, k.span[1]) end
    local entry = { key = k.name, key_span = k.span, sep_span = sep, key_leading = {}, value = value_node }
    append_all(entry.key_leading, leading)
    add_entry(m, entry)
  else
    local s = self:as_sequence(parent)
    self:mark_addressed(s)
    append_all(value_node.leading, leading)
    local idx = last.index
    if idx == "append" then self:fail("FigAppendAssignment") end
    if idx < #s.elements then self:fail("FigIndexAlreadySet") end
    if idx > #s.elements then self:fail("FigIndexSkipped") end
    s.elements[#s.elements + 1] = value_node
  end
end

function P:scan_type_name()
  local colon_pos = self.pos
  self:advance()
  self:skip_spaces_tabs()
  local type_start = self.pos
  while self.pos < self.n and is_bare_key_char(self:at(self.pos)) do self.pos = self.pos + 1 end
  local type_name = self.src:sub(type_start + 1, self.pos)
  if type_name == "" then self:fail("FigBadKey") end
  self:skip_spaces_tabs()
  if self:peek() ~= 61 then self:fail_at(colon_pos, "FigForeignSyntaxColon") end
  return type_name
end

function P:parse_key_line(target, depth)
  local steps = self:scan_key_path()
  self:skip_spaces_tabs()
  if self:peek() == 58 then
    local type_name = self:scan_type_name()
    local eq = { self.pos, self.pos + 1 }
    self:advance()
    self:finish_assignment(target, steps, type_name, eq)
  elseif self:peek() == 61 then
    local eq = { self.pos, self.pos + 1 }
    self:advance()
    self:finish_assignment(target, steps, nil, eq)
  else
    self:finish_header(target, steps, depth)
  end
end

function P:parse_element_line(target, depth, star)
  local body_start = self.pos
  self:skip_spaces_tabs()
  local leading = self:drain_pending()
  local seq = self:as_sequence(target)
  self:mark_element(seq)
  if self:at_end_of_content() then
    local child = new_container()
    local el = new_node({ kind = "container", container = child }, { body_start, body_start })
    el.marker = star
    append_all(el.leading, leading)
    seq.elements[#seq.elements + 1] = el
    local cm = self:scan_trailing_comment_only()
    if cm then el.trailing = cm end
    self:consume_line_end()
    self.stack[#self.stack + 1] = { container = child, child_depth = depth + 1, owner = el }
    return
  end
  if self:peek() == 58 then
    local type_name = self:scan_type_name()
    self:advance()
    local node = self:parse_assigned_value(type_name)
    node.marker = star
    self:consume_line_end()
    append_all(node.leading, leading)
    seq.elements[#seq.elements + 1] = node
    return
  end
  local c = self:peek()
  if c == 39 or c == 34 or c == 91 or c == 123 then
    local node = self:parse_untyped_value(false)
    node.marker = star
    self:consume_line_end()
    append_all(node.leading, leading)
    seq.elements[#seq.elements + 1] = node
    return
  end
  -- A bare element: the no-inline-field guardrail on the raw rest of the
  -- line, before the sniff.
  local k = self.pos
  while k < self.n and self:at(k) ~= 10 do k = k + 1 end
  if self.src:sub(self.pos + 1, k):find(" = ", 1, true) then self:fail("FigElementInlineField") end
  local node = self:parse_untyped_value(false)
  node.marker = star
  self:consume_line_end()
  append_all(node.leading, leading)
  seq.elements[#seq.elements + 1] = node
end

function P:is_plus_line()
  local j = self.pos + 1
  if j >= self.n then return true end
  local c = self:at(j)
  return c == 32 or c == 9 or c == 13 or c == 10 or c == 35
end

function P:parse_continuation_line(depth)
  self:advance() -- +
  if depth ~= 0 then self:fail("FigDanglingContinuation") end
  local steps = self.last_append_steps
  if not steps then self:fail("FigDanglingContinuation") end
  self:skip_spaces_tabs()
  if not self:at_end_of_content() then self:fail("FigTrailingContent") end
  local leading = self:drain_pending()
  local parent = self:navigate_intermediate(self.root, steps)
  local container, owner = self:resolve_header_final(parent, steps[#steps])
  append_all(owner.leading, leading)
  local cm = self:scan_trailing_comment_only()
  if cm then owner.trailing = cm end
  self:consume_line_end()
  self.stack[#self.stack + 1] = { container = container, child_depth = 1, owner = owner }
end

function P:process_content_line(depth, star_span)
  local star = star_span ~= nil
  self:close_frames_above(depth)
  local required = #self.stack == 0 and 0 or self.stack[#self.stack].child_depth
  if depth ~= required then self:fail(required == 0 and "FigRootMarker" or "FigSkippedLevel") end
  local target = #self.stack == 0 and self.root or self.stack[#self.stack].container
  local is_plus = not star and self:peek() == 43 and self:is_plus_line()
  if depth == 0 and not is_plus then self.last_append_steps = nil end
  if is_plus then return self:parse_continuation_line(depth) end
  if star then return self:parse_element_line(target, depth, star_span) end
  local c = self:peek()
  if c == 45 then self:fail("FigForeignSyntaxDash") end
  if c == 91 then self:fail("FigForeignSyntaxBracket") end
  self:parse_key_line(target, depth)
end

function P:process_line(line_start)
  self:skip_spaces_tabs()
  local depth, star, star_span = self:scan_markers()
  if not star and self:at_true_line_end() then
    self:skip_to_next_line()
    return
  end
  if not star and self:peek() == 35 then
    self:advance()
    local j = self.pos
    while j < self.n and self:at(j) ~= 10 do j = j + 1 end
    local text = self.src:sub(self.pos + 1, j):match("^[ \t\r]*(.-)[ \t\r]*$")
    self.pending[#self.pending + 1] = { text = text, depth = depth }
    self.pos = j
    self:skip_to_next_line()
    return
  end
  self:process_content_line(depth, star_span)
end

-- ── the tree, as the wire sees it ──
-- Containers widen to their last child's end here, so every span below is
-- final before the one above it is read.

local function build_node(node, out_regions)
  local v = node.value
  local built
  if v.kind == "container" then
    local c = v.container
    local end_ = 0
    if c.kind == "undecided" then fail(E.FigEmptyContainer, 0) end
    if c.kind == "mapping" then
      built = fig.mapping(nil, { duplicates = "keep" })
      for _, e in ipairs(c.entries) do
        local key = fig.scalar("string", e.key_span, e.key)
        for _, t in ipairs(e.key_leading) do key:comment("leading", t) end
        local value = build_node(e.value)
        if e.value.value.kind == "container" and not e.value.value.container.closed then
          value.mentions = value.mentions or {}
          value.mentions[#value.mentions + 1] = { span = e.key_span, kind = "entry" }
          for _, name in ipairs(e.value.value.container.reentry_names) do
            value.mentions[#value.mentions + 1] = { span = name, kind = "entry" }
          end
        end
        local kv = fig.entry(key, value, { e.key_span[1], e.value.span[2] })
        if e.sep_span then kv.sep = e.sep_span end
        if e.value.span[2] > end_ then end_ = e.value.span[2] end
        built.entries[#built.entries + 1] = kv
      end
    else
      built = fig.sequence(nil)
      for _, el in ipairs(c.elements) do
        local item = build_node(el)
        if el.span[2] > end_ then end_ = el.span[2] end
        if el.marker then item.marker = el.marker end
        for _, t in ipairs(el.leading) do item:comment("leading", t) end
        built.items[#built.items + 1] = item
      end
    end
    if end_ > node.span[2] then node.span[2] = end_ end
    built.span = { node.span[1], node.span[2] }
    if not c.closed and not c.is_root then
      built.regions = built.regions or {}
      built.regions[#built.regions + 1] = { node.span[1], "line" }
      for _, off in ipairs(c.reentries) do built.regions[#built.regions + 1] = { off, "line" } end
    end
  else
    local extra = {}
    if v.ext_kind then extra.ext_kind = v.ext_kind end
    if v.tag then extra.tag = v.tag end
    built = fig.scalar(v.kind, { node.span[1], node.span[2] }, v.text, extra)
  end
  if node.trailing then built:comment("trailing", node.trailing) end
  for _, t in ipairs(node.dangling) do built:comment("dangling", t) end
  return built
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

local function resolve_regions(src, node)
  if node.regions then
    for i, r in ipairs(node.regions) do
      if r[2] == "line" then node.regions[i] = line_region(src, r[1]) end
    end
  end
  if node.kind == "mapping" then
    for _, e in ipairs(node.entries) do resolve_regions(src, e.value) end
  elseif node.kind == "sequence" then
    for _, item in ipairs(node.items) do resolve_regions(src, item) end
  end
end

local function parse_document(input)
  local self = setmetatable({ src = input, n = #input, pos = 0, root = new_container(), root_dangling = {}, pending = {}, stack = {}, last_append_steps = nil, cur_line_start = 0 }, P)
  self.root.is_root = true
  if input:sub(1, 3) == "\239\187\191" then self.pos = 3 end
  while self.pos < self.n do
    local line_start = self.pos
    self.cur_line_start = line_start
    self:process_line(line_start)
  end
  self:close_frames_above(0)
  for _, pc in ipairs(self.pending) do self.root_dangling[#self.root_dangling + 1] = pc.text end
  self.pending = {}
  -- An empty document is an empty mapping.
  if self.root.kind == "undecided" then self.root.kind = "mapping" end
  local root_wrap = new_node({ kind = "container", container = self.root }, { 0, 0 })
  root_wrap.dangling = self.root_dangling
  local root = build_node(root_wrap)
  resolve_regions(input, root)
  return root
end

function M.parse(_dialect, input)
  return parse_document(input)
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's house style, rule for rule: spaced marker runs,
-- fits-or-breaks inline flow, dotted-key collapse, sections at the root
-- with hoisting past depth 2, `path[]`/`+` append groups for lists of
-- maps, multi-line flow for long scalar lists, comments as conservative
-- blockers. Widths are byte widths, as the compiled printer counts them.

local MAX_BODY_DEPTH = 2
local MAX_INLINE_SEQ_ITEMS = 6
local ASSIGN_OP_WIDTH = 3
local MARKER_CELL = 2

local Pr = {}
Pr.__index = Pr

local function is_bare_key_str(s)
  return s:match("^[A-Za-z0-9_%-]+$") ~= nil
end

local function is_total_sink_safe(s)
  if s == "" then return false end
  if s:sub(1, 1) == " " or s:sub(-1) == " " then return false end
  if s:find("[\n\r\t]") then return false end
  local prev_ws = true
  for i = 1, #s do
    local c = s:byte(i)
    if c == 35 and prev_ws then return false end
    prev_ws = (c == 32)
  end
  return true
end

local function flow_leading_bracket_bare(s)
  if classify_flow_bracket(s, 0) ~= "bare_trailing" then return false end
  local depth = 0
  local prev_space = false
  for i = 1, #s do
    local c = s:byte(i)
    if c == 91 or c == 123 then
      depth = depth + 1
    elseif c == 93 or c == 125 then
      if depth == 0 then return false end
      depth = depth - 1
    elseif c == 44 then
      if depth == 0 then return false end
    elseif c == 35 then
      if prev_space and depth == 0 then return false end
    end
    prev_space = (c == 32 or c == 9)
  end
  return depth == 0
end

local function is_bare_safe(s, is_key, in_flow)
  if s == "" then return false end
  if s:sub(1, 1) == " " or s:sub(-1) == " " then return false end
  for i = 1, #s do
    local c = s:byte(i)
    if c == 10 or c == 13 or c == 9 then return false end
    if is_key and not is_bare_key_char(c) then return false end
  end
  if is_key and (s:sub(1, 1) == "-" or s:sub(1, 1) == ">") then return false end
  if not is_key then
    local f = s:byte(1)
    if f == 39 or f == 34 then return false end
    if f == 91 or f == 123 then
      if in_flow then return flow_leading_bracket_bare(s) end
      if classify_bracket_commit(s, 0) ~= "bare_trailing" then return false end
    end
    if in_flow and s:find("[,%]}]") then return false end
    local prev_ws = true
    for i = 1, #s do
      local c = s:byte(i)
      if c == 35 and prev_ws then return false end
      prev_ws = (c == 32 or c == 9)
    end
    if sniff_bare(s).kind ~= "string" or sniff_bare(s).ext_kind then return false end
  end
  return true
end

local function can_raw_quote(s) return not s:find("['\n]") end

local function quoted_width(s)
  if can_raw_quote(s) then return #s + 2 end
  local w = 2
  for i = 1, #s do
    local c = s:sub(i, i)
    w = w + ((c == '"' or c == "\\" or c == "\n" or c == "\r" or c == "\t") and 2 or 1)
  end
  return w
end

local function scalar_string_width(s, is_key, in_flow)
  return is_bare_safe(s, is_key, in_flow) and #s or quoted_width(s)
end

local function bare_or_quoted(s, is_key, in_flow)
  if is_bare_safe(s, is_key, in_flow) then return s end
  if can_raw_quote(s) then return "'" .. s .. "'" end
  return '"' .. s:gsub('["\\\n\r\t]', { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }) .. '"'
end

local function multiline_string(s)
  if not s:find("'''", 1, true) and not s:find("\r", 1, true) then return "'''\n" .. s .. "\n'''" end
  return '"""\n' .. s:gsub('[\\"\r]', { ["\\"] = "\\\\", ['"'] = '\\"', ["\r"] = "\\r" }) .. '\n"""'
end

local function char_literal(text)
  local cp = tonumber(text)
  if not cp then return text end
  if cp == 39 then return "'\\''" end
  if cp == 92 then return "'\\\\'" end
  if cp == 10 then return "'\\n'" end
  if cp == 13 then return "'\\r'" end
  if cp == 9 then return "'\\t'" end
  if (cp >= 0x20 and cp <= 0x26) or (cp >= 0x28 and cp <= 0x5b) or (cp >= 0x5d and cp <= 0x7e) then return "'" .. string.char(cp) .. "'" end
  return string.format("'\\u{%x}'", cp)
end

local function is_multiline(row) return row.kind == "string" and row.text and row.text:find("\n", 1, true) ~= nil end

function Pr:comments_on() return not self.strip end

function Pr:kind_tag(row)
  if not row.tag then return nil end
  local k = row.tag
  if k == "!!str" then
    if row.kind == "string" and not is_total_sink_safe(row.text or "") then return nil end
    return "string"
  end
  if k == "!!int" then return "integer" end
  if k == "!!float" then return "float" end
  if k == "!!bool" then return "boolean" end
  return nil
end

function Pr:key_text(row)
  if row.kind ~= "string" then error("a fig key must be a string", 0) end
  return row.text or ""
end

function Pr:key_width(row) return scalar_string_width(self:key_text(row), true, false) end

function Pr:leading_of(row) return self:comments_on() and row.leading or {} end
function Pr:trailing_of(row) return self:comments_on() and row.trailing[1] or nil end
function Pr:dangling_of(row) return self:comments_on() and row.dangling or {} end

-- Width of `row` as inline flow, or nil when it has no flow spelling under
-- `policy` ("strict", "allow_trailing", "allow_leading_trailing").
function Pr:inline_width(row, policy)
  if self:comments_on() then
    if #row.dangling > 0 then return nil end
    if policy == "strict" and (#row.leading > 0 or #row.trailing > 0) then return nil end
    if policy == "allow_trailing" and #row.leading > 0 then return nil end
  end
  return self:structural_width(row)
end

function Pr:structural_width(row)
  local memo = self.memo[row]
  if memo ~= nil then return memo or nil end
  local w = self:compute_inline_width(row)
  self.memo[row] = w == nil and false or w
  return w
end

function Pr:compute_inline_width(row)
  if self:kind_tag(row) then return nil end
  local k = row.kind
  if k == "null" then return 4 end
  if k == "bool" then return row.text == "true" and 4 or 5 end
  if k == "int" or k == "float" then
    if row.ext_kind then return nil end
    return #row.text
  end
  if k == "string" then
    local e = row.ext_kind
    if e then
      if e == "offset_datetime" or e == "local_datetime" or e == "local_date" or e == "local_time" then return #row.text end
      return nil
    end
    if row.text and row.text:find("\n", 1, true) then return nil end
    return scalar_string_width(row.text or "", false, true)
  end
  if k == "alias" or k == "keyvalue" then return nil end
  if k == "sequence" then
    local w = 2
    for i, el in ipairs(row.items) do
      local ew = self:inline_width(el, "strict")
      if not ew then return nil end
      w = w + ew + (i > 1 and 2 or 0)
    end
    return w
  end
  if k == "mapping" then
    if #row.items == 0 then return 2 end
    local w = 4
    for i, e in ipairs(row.items) do
      if self:comments_on() and #e.key.leading > 0 then return nil end
      if e.value.kind == "mapping" then return nil end
      local vw = self:inline_width(e.value, "strict")
      if not vw then return nil end
      w = w + self:key_width(e.key) + 3 + vw + (i > 1 and 2 or 0)
    end
    return w
  end
  return nil
end

function Pr:fits_inline(row, prefix_width, policy)
  local w = self:inline_width(row, policy)
  if not w then return false end
  return prefix_width + w <= self.width
end

function Pr:seq_fits_inline(row, prefix_width, policy)
  return #row.items <= MAX_INLINE_SEQ_ITEMS and self:fits_inline(row, prefix_width, policy)
end

local function map_entry_prefix_width(depth, key_width) return MARKER_CELL * depth + key_width + ASSIGN_OP_WIDTH end
local function element_prefix_width(depth) return MARKER_CELL * (depth + 1) end

local function all_elements_mappings(row)
  for _, el in ipairs(row.items) do
    if el.kind ~= "mapping" then return false end
  end
  return true
end

local function has_mapping_element(row)
  for _, el in ipairs(row.items) do
    if el.kind == "mapping" then return true end
  end
  return false
end

local function flow_quotes_what_block_leaves_bare(row)
  if row.kind == "string" and not row.ext_kind then
    local s = row.text or ""
    return not is_bare_safe(s, false, true) and is_bare_safe(s, false, false)
  end
  if row.kind == "sequence" then
    for _, el in ipairs(row.items) do
      if flow_quotes_what_block_leaves_bare(el) then return true end
    end
  end
  return false
end

function Pr:multiline_flow_eligible(row, policy)
  if #row.items == 0 then return false end
  if has_mapping_element(row) then return false end
  if flow_quotes_what_block_leaves_bare(row) then return false end
  return self:inline_width(row, policy) ~= nil
end

function Pr:collapse_child(e)
  local v = e.value
  if v.kind ~= "mapping" then return nil end
  if #v.items ~= 1 then return nil end
  if self:comments_on() then
    if #e.key.leading > 0 then return nil end
    if #v.leading > 0 or #v.trailing > 0 or #v.dangling > 0 then return nil end
  end
  return v.items[1]
end

function Pr:resolve_chain(e)
  local cur = e
  local w = self:key_width(cur.key)
  while true do
    local child = self:collapse_child(cur)
    if not child then break end
    cur = child
    w = w + 1 + self:key_width(cur.key)
  end
  return cur, w
end

function Pr:chain_keys(e, end_e)
  local parts = { bare_or_quoted(self:key_text(e.key), true, false) }
  local cur = e
  while cur ~= end_e do
    cur = self:collapse_child(cur)
    parts[#parts + 1] = bare_or_quoted(self:key_text(cur.key), true, false)
  end
  return table.concat(parts, ".")
end

function Pr:block_depth_map(row, depth)
  local maxd = depth
  for _, e in ipairs(row.items) do
    local end_e, kw = self:resolve_chain(e)
    local v = end_e.value
    if v.kind == "mapping" then
      if not self:fits_inline(v, map_entry_prefix_width(depth, kw), "allow_trailing") then
        maxd = math.max(maxd, self:block_depth_map(v, depth + 1))
      end
    elseif v.kind == "sequence" then
      if not self:fits_inline(v, map_entry_prefix_width(depth, kw), "allow_trailing") and not self:multiline_flow_eligible(v, "allow_trailing") then
        maxd = math.max(maxd, self:block_depth_seq(v, depth + 1))
      end
    end
  end
  return maxd
end

function Pr:block_depth_seq(row, depth)
  local maxd = depth
  for _, el in ipairs(row.items) do
    if el.kind == "mapping" then
      if not self:fits_inline(el, element_prefix_width(depth), "allow_leading_trailing") then
        maxd = math.max(maxd, self:block_depth_map(el, depth + 1))
      end
    elseif el.kind == "sequence" then
      if not self:fits_inline(el, element_prefix_width(depth), "allow_leading_trailing") and not self:multiline_flow_eligible(el, "allow_leading_trailing") then
        maxd = math.max(maxd, self:block_depth_seq(el, depth + 1))
      end
    end
  end
  return maxd
end

-- ── writing ──

function Pr:put(...) self.w:put(...) end

function Pr:markers(depth) for _ = 1, depth do self:put("> ") end end

function Pr:comment_lines(c, depth)
  for line in (c.text .. "\n"):gmatch("(.-)\n") do
    self:markers(depth)
    self:put("#")
    local t = line:match("^[ \t]*(.-)[ \t]*$")
    if t ~= "" then self:put(" ", t) end
    self:put("\n")
  end
end

function Pr:leading_comments(row, depth)
  for _, c in ipairs(self:leading_of(row)) do self:comment_lines(c, depth) end
end

function Pr:trailing_comment(row)
  local c = self:trailing_of(row)
  if not c then return end
  self:put(" #")
  if c.text ~= "" then self:put(" ", (c.text:gsub("\n", " "))) end
end

function Pr:type_annotation(row)
  local k = self:kind_tag(row)
  if k == "integer" then self:put(": int") return true end
  if k == "float" then self:put(": float") return true end
  if k == "string" then self:put(": string") return true end
  if k == "boolean" then self:put(": bool") return true end
  local e = row.ext_kind
  if e == "enum_literal" then self:put(": enum") return true end
  if e == "char_literal" then self:put(": char") return true end
  if e == "number_special" then self:put(": float") return true end
  return false
end

function Pr:value(row, in_flow)
  local k = row.kind
  if k == "null" then
    self:put("null")
  elseif k == "bool" then
    self:put(row.text)
  elseif k == "int" or k == "float" then
    if row.ext_kind == "char_literal" then self:put(char_literal(row.text)) else self:put(row.text) end
  elseif k == "string" then
    local e = row.ext_kind
    if e then
      self:put(row.text)
    elseif not in_flow and is_multiline(row) then
      self:put(multiline_string(row.text))
    elseif not in_flow and self:kind_tag(row) == "string" then
      self:put(row.text)
    else
      self:put(bare_or_quoted(row.text or "", false, in_flow))
    end
  elseif k == "mapping" or k == "sequence" then
    self:flow_value(row)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as fig", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function Pr:flow_value(row)
  if row.kind == "sequence" then
    self:put("[")
    for i, el in ipairs(row.items) do
      if i > 1 then self:put(", ") end
      self:value(el, true)
    end
    self:put("]")
  elseif row.kind == "mapping" then
    if #row.items == 0 then return self:put("{}") end
    self:put("{ ")
    for i, e in ipairs(row.items) do
      if i > 1 then self:put(", ") end
      self:put(bare_or_quoted(self:key_text(e.key), true, false), " = ")
      self:value(e.value, true)
    end
    self:put(" }")
  else
    error("a " .. row.kind .. " has no flow spelling", 0)
  end
end

function Pr:multiline_flow_seq(row, indent, comment_anchor)
  self:put("[")
  if comment_anchor then self:trailing_comment(comment_anchor) end
  self:put("\n")
  local inner = indent + 2
  for _, el in ipairs(row.items) do
    self:put(string.rep(" ", inner))
    if el.kind == "sequence" and #el.items > 0 and not self:seq_fits_inline(el, inner + 1, "strict") then
      self:multiline_flow_seq(el, inner, nil)
    else
      self:value(el, true)
    end
    self:put(",\n")
  end
  self:put(string.rep(" ", indent), "]")
end

function Pr:body(row, depth)
  if row.kind == "mapping" then return self:map_body(row, depth) end
  if row.kind == "sequence" then return self:seq_body(row, depth) end
  error("a " .. row.kind .. " has no block body", 0)
end

function Pr:map_body(row, depth)
  for _, e in ipairs(row.items) do self:map_entry_line(e, depth) end
  for _, c in ipairs(self:dangling_of(row)) do self:comment_lines(c, depth) end
end

function Pr:map_entry_line(e, depth)
  local end_e, kw = self:resolve_chain(e)
  self:leading_comments(end_e.key, depth)
  self:markers(depth)
  self:put(self:chain_keys(e, end_e))
  local v = end_e.value
  local prefix_width = map_entry_prefix_width(depth, kw)
  if v.kind == "mapping" then
    if self:fits_inline(v, prefix_width, "allow_trailing") then
      self:put(" = ")
      self:flow_value(v)
      self:trailing_comment(v)
      self:put("\n")
    else
      self:trailing_comment(v)
      self:put("\n")
      self:body(v, depth + 1)
    end
  elseif v.kind == "sequence" then
    if self:seq_fits_inline(v, prefix_width, "allow_trailing") then
      self:put(" = ")
      self:flow_value(v)
      self:trailing_comment(v)
      self:put("\n")
    elseif self:multiline_flow_eligible(v, "allow_trailing") then
      self:put(" = ")
      self:multiline_flow_seq(v, 2 * depth, v)
      self:put("\n")
    else
      self:trailing_comment(v)
      self:put("\n")
      self:body(v, depth + 1)
    end
  else
    self:type_annotation(v)
    self:put(" = ")
    self:value(v, false)
    self:trailing_comment(v)
    self:put("\n")
  end
end

function Pr:seq_body(row, depth)
  for _, el in ipairs(row.items) do
    self:leading_comments(el, depth)
    self:markers(depth)
    self:put("*")
    if el.kind == "mapping" then
      if self:fits_inline(el, element_prefix_width(depth), "allow_leading_trailing") then
        self:put(" ")
        self:flow_value(el)
        self:trailing_comment(el)
        self:put("\n")
      else
        self:trailing_comment(el)
        self:put("\n")
        self:body(el, depth + 1)
      end
    elseif el.kind == "sequence" then
      if self:seq_fits_inline(el, element_prefix_width(depth), "allow_leading_trailing") then
        self:put(" ")
        self:flow_value(el)
        self:trailing_comment(el)
        self:put("\n")
      elseif self:multiline_flow_eligible(el, "allow_leading_trailing") then
        self:put(" ")
        self:multiline_flow_seq(el, element_prefix_width(depth), el)
        self:put("\n")
      else
        self:trailing_comment(el)
        self:put("\n")
        self:body(el, depth + 1)
      end
    else
      local annotated = self:type_annotation(el)
      self:put(annotated and " = " or " ")
      self:value(el, false)
      self:trailing_comment(el)
      self:put("\n")
    end
  end
  for _, c in ipairs(self:dangling_of(row)) do self:comment_lines(c, depth) end
end

-- ── sections ──

function Pr:path_text()
  local parts = {}
  for _, key in ipairs(self.path) do parts[#parts + 1] = bare_or_quoted(self:key_text(key), true, false) end
  return table.concat(parts, ".")
end

function Pr:path_width()
  local w = #self.path > 0 and #self.path - 1 or 0
  for _, key in ipairs(self.path) do w = w + self:key_width(key) end
  return w
end

function Pr:begin_section(multiline, anchor)
  local has_lead = anchor ~= nil and self:comments_on() and #anchor.leading > 0
  local ml = multiline or has_lead
  if self.started and (ml or self.prev_multiline) then self:put("\n") end
  self.started = true
  self.prev_multiline = ml
  if anchor then self:leading_comments(anchor, 0) end
end

function Pr:is_flat_child(e)
  local end_e, kw = self:resolve_chain(e)
  local v = end_e.value
  if v.kind == "mapping" then return self:fits_inline(v, map_entry_prefix_width(1, kw), "allow_trailing") end
  if v.kind == "sequence" then return self:seq_fits_inline(v, map_entry_prefix_width(1, kw), "allow_trailing") end
  return true
end

function Pr:section_assign(anchor_key, v)
  self:begin_section(false, anchor_key)
  self:put(self:path_text())
  if v.kind == "mapping" or v.kind == "sequence" then
    self:put(" = ")
    self:flow_value(v)
  else
    self:type_annotation(v)
    self:put(" = ")
    self:value(v, false)
  end
  self:trailing_comment(v)
  self:put("\n")
end

function Pr:emit_append_group(seq)
  for i, el in ipairs(seq.items) do
    if i == 1 then self:begin_section(true, nil) end
    self:leading_comments(el, 0)
    if i == 1 then self:put(self:path_text(), "[]") else self:put("+") end
    self:trailing_comment(el)
    self:put("\n")
    self:map_body(el, 1)
  end
end

function Pr:emit_section(e)
  self.path[#self.path + 1] = e.key
  local ok, err = pcall(function()
    local child = self:collapse_child(e)
    if child then return self:emit_section(child) end
    local v = e.value
    if v.kind == "mapping" then
      if self:fits_inline(v, self:path_width() + ASSIGN_OP_WIDTH, "allow_trailing") then return self:section_assign(e.key, v) end
      local key_has_leading = self:comments_on() and #e.key.leading > 0
      local v_has_tail = self:comments_on() and (#v.trailing > 0 or #v.dangling > 0)
      if #v.items > 0 and self:block_depth_map(v, 1) > MAX_BODY_DEPTH and not key_has_leading and not v_has_tail then
        local i = 1
        while i <= #v.items do
          local run_len = 0
          local j = i
          while j <= #v.items and self:is_flat_child(v.items[j]) do
            run_len = run_len + 1
            j = j + 1
          end
          if run_len == 1 then
            self:emit_section(v.items[i])
            i = i + 1
          elseif run_len >= 2 then
            self:begin_section(true, nil)
            self:put(self:path_text(), "\n")
            for _ = 1, run_len do
              self:map_entry_line(v.items[i], 1)
              i = i + 1
            end
          end
          if i <= #v.items then
            self:emit_section(v.items[i])
            i = i + 1
          end
        end
        return
      end
      self:begin_section(true, e.key)
      self:put(self:path_text())
      self:trailing_comment(v)
      self:put("\n")
      self:map_body(v, 1)
    elseif v.kind == "sequence" then
      if self:seq_fits_inline(v, self:path_width() + ASSIGN_OP_WIDTH, "allow_trailing") then return self:section_assign(e.key, v) end
      local key_has_leading = self:comments_on() and #e.key.leading > 0
      local v_has_tail = self:comments_on() and (#v.trailing > 0 or #v.dangling > 0)
      if #v.items > 0 and all_elements_mappings(v) and not key_has_leading and not v_has_tail then
        return self:emit_append_group(v)
      end
      if self:multiline_flow_eligible(v, "allow_trailing") then
        self:begin_section(false, e.key)
        self:put(self:path_text(), " = ")
        self:multiline_flow_seq(v, 0, v)
        self:put("\n")
        return
      end
      self:begin_section(true, e.key)
      self:put(self:path_text())
      self:trailing_comment(v)
      self:put("\n")
      self:seq_body(v, 1)
    else
      self:section_assign(e.key, v)
    end
  end)
  self.path[#self.path] = nil
  if not ok then error(err, 0) end
end

local function new_printer(options)
  options = options or {}
  return setmetatable({
    w = fig.writer(options),
    width = options.width or 80,
    strip = options.strip_comments == true,
    memo = {},
    path = {},
    started = false,
    prev_multiline = false,
  }, Pr)
end

-- A mapping at depth 0 is a document of sections; deeper, a block body.
function Pr:print_node(row, depth)
  if row.kind == "mapping" then
    if depth == 0 then
      for _, e in ipairs(row.items) do self:emit_section(e) end
      for _, c in ipairs(self:dangling_of(row)) do self:comment_lines(c, 0) end
    else
      self:map_body(row, depth)
    end
  elseif row.kind == "sequence" then
    self:seq_body(row, depth)
  else
    if depth == 0 then error("a scalar has no fig document spelling; use the canonical form", 0) end
    self:value(row, false)
    self:put("\n")
  end
end

function M.print(_dialect, t, options)
  local root = t.byid(0)
  local p = new_printer(options)
  p:leading_comments(root, 0)
  if root.kind == "mapping" then
    for _, e in ipairs(root.items) do p:emit_section(e) end
    for _, c in ipairs(p:dangling_of(root)) do p:comment_lines(c, 0) end
  elseif root.kind == "sequence" then
    p:seq_body(root, 0)
  else
    -- A scalar root is a fragment — a value the editor will splice after
    -- `key = ` — and takes its ordinary spelling; a whole document is
    -- never a scalar.
    p:value(root, false)
    p:put("\n")
  end
  return p.w:string()
end

-- ── the renderer ──────────────────────────────────────────────────────────
-- What follows a key on its entry line: ` = value` for an inline value, or
-- a newline and a block map or sequence re-printed as a nested section one
-- marker level below the key's — the count of `>` in `indent`. The root
-- (an empty key) takes the value as written.

local function block_body(depth, value_text)
  local t = value_text:match("^[ \t\r\n]*(.-)[ \t\r\n]*$")
  if t == "" then return nil end
  local f = t:sub(1, 1)
  if f == "{" or f == "[" or f == "'" or f == '"' then return nil end
  if not t:find("\n", 1, true) then return nil end
  local ok, root = pcall(parse_document, value_text)
  if not ok then return nil end
  if root.kind ~= "mapping" and root.kind ~= "sequence" then return nil end
  local t2 = fig.rows(root)
  fig.index(t2)
  local p = new_printer({})
  p:print_node(t2.byid(0), depth)
  return p.w:string()
end

function M.render(which, args)
  if which ~= "tail" then error("no renderer `" .. which .. "`", 0) end
  if args.key == "" then return args.value end
  local _, depth = args.indent:gsub(">", "")
  local body = block_body(depth + 1, args.value)
  if body then return "\n" .. body:gsub("\n+$", "") end
  return " = " .. args.value
end

return M
