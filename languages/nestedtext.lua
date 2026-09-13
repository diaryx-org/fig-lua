-- NestedText, in Lua: the twin of fig's compiled `nestedtext` format, row
-- for row, marker for marker.
--
-- `fig lang check lua-nestedtext --against nestedtext <files…>` holds this
-- script to the compiled parser's node table on every file given, and
-- this script is written against `fig lang table -i nestedtext`, which
-- prints that table. What the compiled format accepts is stated in fig's
-- `src/languages/nestedtext/` (`tokenizer.zig`, `parser.zig`,
-- `printer.zig`, `editor_helper.zig`), and this follows them function for
-- function: the tokenizer classifies every physical line by the tag that
-- starts its content, and the parser relates the lines by indentation.
--
-- The shape, as the compiled parser builds it:
--
--   * a line is `key: value` or `key:` (a dict item; the key is what
--     precedes the first `: ` or a trailing `:`, trimmed at its end; the
--     value is the rest of the line, exactly), `: text` (a multiline key,
--     its lines joined with `\n`), `- value` (a list item), `> text` (a
--     string block, its lines joined with `\n`), `# comment`, or blank;
--     a value left empty on its line is what the more-indented lines
--     below hold, or the empty string where those lines would begin;
--     a line beginning `{` or `[` where a document or a nested value
--     starts is an inline dict or list, the whole line;
--   * every scalar is a string, and every string is literal — no
--     escapes, no quoting; a `{` after `key: ` is text;
--   * a block container spans its first line's start (indentation
--     included) to its last value's end; a string block and a multiline
--     key likewise; a dict item spans its key through its value with the
--     `:` as its `sep` (zero-width at the key's end for a multiline key);
--     a list item records its `-` as `marker`; an inline container spans
--     its brackets, its entries have no `sep`; a duplicate key is refused;
--   * a comment leads the next key or list item, or dangles on the root
--     when no item follows; nothing trails a value; an empty document is
--     a null spanning nothing at the input's end.
--
-- The refusals are the compiled parser's, in its words and at its
-- offsets — a line's start for a line that is wrong, the cursor for an
-- inline value, the input's start for a duplicate key, which the compiled
-- parser reports without a position. Indentation is spaces only: a tab
-- or a no-break space where indentation is read is refused.

local M = {}

M.name = "lua-nestedtext"
M.caps = { read = true, edit = true, serialize = true }
M.syntax = {
  comments = { style = "hash", line = { open = "#" } },
  kv_sep = ": ",
  indent_unit = "    ",
  seq_item_marker = "- ",
}
M.dialects = {
  -- The compiled format owns `.nt`, and a compiled format's extension
  -- wins, so this is reached by `--lang lua-nestedtext`.
  { name = "lua-nestedtext", extensions = { "nt" }, splice = "raw", empty_doc_seed = "" },
}
M.samples = {
  "a: 1\nb:\n  - x\n  - y\n",
}
-- The compiled editor's four renderers: an entry, an item, a value's tail
-- after its key, and a key over an old one.
M.renderers = { "entry", "item", "tail", "key" }

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  InvalidUtf8 = "this file is not valid UTF-8; NestedText documents must be UTF-8 encoded",
  InvalidIndentChar = "indentation must use plain spaces; a tab or other whitespace character is not allowed here",
  TopLevelIndent = "top-level content must start in column 1",
  InvalidIndentation = "this line's indentation does not match any enclosing block (partial dedent)",
  ExpectedDictItem = "expected a dictionary item (`key: value` or a `: multiline key` line) here",
  ExpectedListItem = "expected a list item (`- value`) here",
  UnrecognizedLine = "this line is not a valid dictionary item, list item, string item, or comment",
  MissingValue = "expected a value here",
  MultilineKeyNoValue = "a multiline key requires a value on a more-indented line",
  MultilineKeyBadValue = "the value of a multiline key must be on a more-indented line",
  DuplicateKey = "this key is already defined in this mapping",
  ExtraContent = "unexpected content after the document's value",
  ExtraCharsAfterDelim = "unexpected content after the closing `}`/`]`",
  UnclosedDelim = "this line ended without a closing `}`/`]`",
  ExpectedColon = "expected `:` after this inline dictionary key",
  ExpectedCommaOrClose = "expected `,` or a closing `}`/`]` here",
}

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- One record per physical line: `{ kind=, indent=, line_start=, s=, e= }`
-- with `kind` one of `blank`, `comment`, `dash`, `colon`, `gt`, `other`,
-- `end_of_file`; `[s, e)` is the content after the tag and its one space,
-- the whole line for `other`.

local function tokenize(src)
  local n = #src
  local i = 0
  local lines = {}
  local function at(k) return src:byte(k + 1) end
  if src:sub(1, 3) == "\239\187\191" then i = 3 end
  while i < n do
    local line_start = i
    local j = i
    while j < n and at(j) == 32 do j = j + 1 end
    local e = j
    while e < n and at(e) ~= 10 and at(e) ~= 13 do e = e + 1 end
    local indent = j - line_start
    if j == e then
      lines[#lines + 1] = { kind = "blank", indent = indent, line_start = line_start, s = e, e = e }
    else
      local c = at(j)
      if c == 9 or (c == 0xC2 and at(j + 1) == 0xA0) then fig.fail(MESSAGES.InvalidIndentChar, line_start) end
      local function tagged(kind)
        local after = j + 1
        if after < e then
          lines[#lines + 1] = { kind = kind, indent = indent, line_start = line_start, s = after + 1, e = e }
        else
          lines[#lines + 1] = { kind = kind, indent = indent, line_start = line_start, s = e, e = e }
        end
      end
      local next_is_space_or_end = j + 1 == e or at(j + 1) == 32
      if c == 35 then
        lines[#lines + 1] = { kind = "comment", indent = indent, line_start = line_start, s = j + 1, e = e }
      elseif c == 45 and next_is_space_or_end then
        tagged("dash")
      elseif c == 58 and next_is_space_or_end then
        tagged("colon")
      elseif c == 62 and next_is_space_or_end then
        tagged("gt")
      else
        lines[#lines + 1] = { kind = "other", indent = indent, line_start = line_start, s = j, e = e }
      end
    end
    local k = e
    if k < n and at(k) == 13 then k = k + 1 end
    if k < n and at(k) == 10 then k = k + 1 end
    i = k
  end
  lines[#lines + 1] = { kind = "end_of_file", indent = 0, line_start = n, s = n, e = n }
  return lines
end

-- ── the parser ────────────────────────────────────────────────────────────

local P = {}
P.__index = P

function P:peek() return self.lines[self.pos] end
function P:at_end() return self:peek().kind == "end_of_file" end
function P:text(s, e) return self.src:sub(s + 1, e) end

function P:fail_at_line(l, code) fig.fail(MESSAGES[code], l.line_start) end

function P:skip_blank()
  while true do
    local l = self:peek()
    if l.kind == "comment" then
      self.pending[#self.pending + 1] = self:text(l.s, l.e)
      self.pos = self.pos + 1
    elseif l.kind == "blank" then
      self.pos = self.pos + 1
    else
      return
    end
  end
end

function P:take_leading()
  local out = self.pending
  self.pending = {}
  return out
end

local function attach(node, slot, texts)
  for _, t in ipairs(texts) do node:comment(slot, t) end
end

-- A mapping keeps its entries in order and refuses a repeated key where
-- the compiled parser does: with no position.
local function put(map, entry)
  if map.by_key[entry.key.text] then fig.fail(MESSAGES.DuplicateKey, 0) end
  map:put(entry)
end

function P:starts_with_bracket(l)
  if l.e == l.s then return false end
  local c = self.src:byte(l.s + 1)
  return c == 123 or c == 91
end

-- `key: value` / `key:`: where the key ends and the value begins, or nil.
function P:split_dict_item(l)
  local i = l.s
  while i < l.e do
    if self.src:byte(i + 1) == 58 then
      if i + 1 == l.e then return i, l.e end
      if self.src:byte(i + 2) == 32 then return i, i + 2 end
    end
    i = i + 1
  end
  return nil
end

function P:is_dict_item_line(l)
  if self:starts_with_bracket(l) then return false end
  return self:split_dict_item(l) ~= nil
end

-- The value that belongs here: the whole document (`parent_indent` nil,
-- at indent 0) or the block under an item whose own line left its value
-- empty (more indented than `parent_indent`). Nothing there is
-- `on_missing`: a null document, an empty string, or a refusal.
function P:parse_region(parent_indent, on_missing)
  self:skip_blank()
  local no_content = self:at_end() or (parent_indent ~= nil and self:peek().indent <= parent_indent)
  if no_content then
    if on_missing == "null_document" then
      return fig.scalar("null", { self.n, self.n })
    elseif on_missing == "empty_string" then
      local at = self:at_end() and self.n or self:peek().line_start
      return fig.scalar("string", { at, at }, "")
    end
    fig.fail(MESSAGES.MissingValue, self:peek().line_start)
  end
  local first = self:peek()
  local region_indent = first.indent
  if parent_indent == nil and region_indent ~= 0 then self:fail_at_line(first, "TopLevelIndent") end
  if first.kind == "other" and self:starts_with_bracket(first) then
    local node = self:parse_inline_line(first)
    self.pos = self.pos + 1
    self:skip_blank()
    local still_in_region = not self:at_end() and (parent_indent == nil or self:peek().indent > parent_indent)
    if still_in_region then self:fail_at_line(self:peek(), "ExtraContent") end
    return node
  end
  return self:parse_container_at(region_indent)
end

function P:parse_container_at(indent)
  local first = self:peek()
  if first.kind == "dash" then return self:parse_list_block(indent) end
  if first.kind == "gt" then return self:parse_string_block(indent) end
  if first.kind == "colon" then return self:parse_dict_block(indent) end
  if self:is_dict_item_line(first) then return self:parse_dict_block(indent) end
  self:fail_at_line(first, "UnrecognizedLine")
end

function P:parse_item_value(s, e, container_indent)
  if e ~= s then return fig.scalar("string", { s, e }, self:text(s, e)) end
  return self:parse_region(container_indent, "empty_string")
end

function P:parse_list_block(indent)
  local start = self:peek().line_start
  local seq = fig.sequence({ start, start })
  local end_ = start
  while true do
    self:skip_blank()
    if self:at_end() then break end
    local l = self:peek()
    if l.indent < indent then break end
    if l.indent > indent then self:fail_at_line(l, "InvalidIndentation") end
    if l.kind ~= "dash" then self:fail_at_line(l, "ExpectedListItem") end
    self.pos = self.pos + 1
    local leading = self:take_leading()
    local value = self:parse_item_value(l.s, l.e, indent)
    attach(value, "leading", leading)
    local dash = l.line_start + l.indent
    value.marker = { dash, dash + 1 }
    seq:add(value)
    end_ = value.span[2]
  end
  seq.span[2] = end_
  return seq
end

-- The `: ` lines of a multiline key, or the `> ` lines of a string block,
-- at `indent`: joined with `\n`, spanning the first line's start to the
-- last line's content end; blank and comment lines between are skipped.
function P:collect_lines(kind, indent)
  local parts = {}
  local start = self:peek().line_start
  local end_ = start
  while true do
    local i = self.pos
    while i <= #self.lines and (self.lines[i].kind == "blank" or self.lines[i].kind == "comment") do i = i + 1 end
    local l = self.lines[i]
    if l == nil or l.kind ~= kind or l.indent ~= indent then break end
    self.pos = i
    parts[#parts + 1] = self:text(l.s, l.e)
    end_ = l.e
    self.pos = self.pos + 1
  end
  return table.concat(parts, "\n"), { start, end_ }
end

function P:parse_string_block(indent)
  local text, span = self:collect_lines("gt", indent)
  return fig.scalar("string", span, text)
end

function P:parse_dict_block(indent)
  local start = self:peek().line_start
  local map = fig.mapping({ start, start }, { duplicates = "keep" })
  local end_ = start
  while true do
    self:skip_blank()
    if self:at_end() then break end
    local l = self:peek()
    if l.indent < indent then break end
    if l.indent > indent then self:fail_at_line(l, "InvalidIndentation") end
    if l.kind == "colon" then
      local text, span = self:collect_lines("colon", indent)
      local key = fig.scalar("string", span, text)
      attach(key, "leading", self:take_leading())
      if self:at_end() then fig.fail(MESSAGES.MultilineKeyNoValue, self:peek().line_start) end
      if self:peek().indent <= indent then self:fail_at_line(self:peek(), "MultilineKeyBadValue") end
      local value = self:parse_region(indent, "err")
      local kv = fig.entry(key, value, { key.span[1], value.span[2] })
      kv.sep = { span[2], span[2] }
      put(map, kv)
      end_ = value.span[2]
    elseif l.kind == "other" and self:is_dict_item_line(l) then
      local key_end, val_start = self:split_dict_item(l)
      self.pos = self.pos + 1
      local key_text = self:trim_key(self:text(l.s, key_end))
      local key = fig.scalar("string", { l.s, l.s + #key_text }, key_text)
      attach(key, "leading", self:take_leading())
      local value = self:parse_item_value(val_start, l.e, indent)
      local kv = fig.entry(key, value, { key.span[1], value.span[2] })
      kv.sep = { key_end, key_end + 1 }
      put(map, kv)
      end_ = value.span[2]
    else
      self:fail_at_line(l, "ExpectedDictItem")
    end
  end
  map.span[2] = end_
  return map
end

-- `std.mem.trimEnd(key, " \t\xC2\xA0")`: trailing bytes in that set go —
-- a byte at a time, as the compiled parser trims, so the two bytes of a
-- no-break space go one by one and so would a lone `\xC2`.
function P:trim_key(s)
  local e = #s
  while e > 0 do
    local b = s:byte(e)
    if b == 32 or b == 9 or b == 0xC2 or b == 0xA0 then e = e - 1 else break end
  end
  return s:sub(1, e)
end

-- ── inline values ─────────────────────────────────────────────────────────
-- `{…}` and `[…]` on one line, scanned over absolute offsets; the refusals
-- are reported at the cursor.

local function is_inline_stop(c)
  return c == 44 or c == 123 or c == 125 or c == 91 or c == 93
end

function P:skip_inline_ws()
  while self.ipos < self.iend and (self.src:byte(self.ipos + 1) == 32 or self.src:byte(self.ipos + 1) == 9) do
    self.ipos = self.ipos + 1
  end
end

function P:parse_inline_line(l)
  self.ipos = l.s
  self.iend = l.e
  local node = self:parse_inline_value(nil)
  self:skip_inline_ws()
  if self.ipos < self.iend then fig.fail(MESSAGES.ExtraCharsAfterDelim, self.ipos) end
  return node
end

function P:parse_inline_value(close)
  self:skip_inline_ws()
  if self.ipos >= self.iend then fig.fail(MESSAGES.UnclosedDelim, self.ipos) end
  local c = self.src:byte(self.ipos + 1)
  if c == 123 then return self:parse_inline_dict() end
  if c == 91 then return self:parse_inline_list() end
  return self:scan_inline_value(close)
end

function P:scan_inline_value(close)
  local start = self.ipos
  while self.ipos < self.iend and not is_inline_stop(self.src:byte(self.ipos + 1)) do self.ipos = self.ipos + 1 end
  local raw_end = self.ipos
  if self.ipos < self.iend then
    local stop = self.src:byte(self.ipos + 1)
    if stop ~= 44 and stop ~= close then fig.fail(MESSAGES.ExpectedCommaOrClose, self.ipos) end
  end
  local text = self:text(start, raw_end):gsub("[ \t]+$", "")
  return fig.scalar("string", { start, raw_end }, text)
end

function P:parse_inline_entry(map)
  self:skip_inline_ws()
  local key_start = self.ipos
  while self.ipos < self.iend do
    local c = self.src:byte(self.ipos + 1)
    if c == 58 or is_inline_stop(c) then break end
    self.ipos = self.ipos + 1
  end
  if self.ipos >= self.iend then fig.fail(MESSAGES.UnclosedDelim, self.ipos) end
  if self.src:byte(self.ipos + 1) ~= 58 then fig.fail(MESSAGES.ExpectedColon, self.ipos) end
  local key_text = self:text(key_start, self.ipos):gsub("[ \t]+$", "")
  local key = fig.scalar("string", { key_start, self.ipos }, key_text)
  self.ipos = self.ipos + 1
  local value = self:parse_inline_value(125)
  put(map, fig.entry(key, value, { key.span[1], value.span[2] }))
end

function P:parse_inline_dict()
  local start = self.ipos
  self.ipos = self.ipos + 1
  local map = fig.mapping({ start, start }, { duplicates = "keep" })
  if self.ipos < self.iend and self.src:byte(self.ipos + 1) == 125 then
    self.ipos = self.ipos + 1
    map.span[2] = self.ipos
    return map
  end
  local first = true
  while true do
    if not first then
      self:skip_inline_ws()
      if self.ipos < self.iend and self.src:byte(self.ipos + 1) == 125 then fig.fail(MESSAGES.MissingValue, self.ipos) end
    end
    first = false
    self:parse_inline_entry(map)
    self:skip_inline_ws()
    if self.ipos >= self.iend then fig.fail(MESSAGES.UnclosedDelim, self.ipos) end
    local d = self.src:byte(self.ipos + 1)
    if d == 44 then
      self.ipos = self.ipos + 1
    elseif d == 125 then
      self.ipos = self.ipos + 1
      break
    else
      fig.fail(MESSAGES.ExpectedCommaOrClose, self.ipos)
    end
  end
  map.span[2] = self.ipos
  return map
end

function P:parse_inline_list()
  local start = self.ipos
  self.ipos = self.ipos + 1
  local seq = fig.sequence({ start, start })
  if self.ipos < self.iend and self.src:byte(self.ipos + 1) == 93 then
    self.ipos = self.ipos + 1
    seq.span[2] = self.ipos
    return seq
  end
  while true do
    seq:add(self:parse_inline_value(93))
    self:skip_inline_ws()
    if self.ipos >= self.iend then fig.fail(MESSAGES.UnclosedDelim, self.ipos) end
    local d = self.src:byte(self.ipos + 1)
    if d == 44 then
      self.ipos = self.ipos + 1
    elseif d == 93 then
      self.ipos = self.ipos + 1
      break
    else
      fig.fail(MESSAGES.ExpectedCommaOrClose, self.ipos)
    end
  end
  seq.span[2] = self.ipos
  return seq
end

function M.parse(_dialect, input)
  local ok, bad = utf8.len(input)
  if not ok then fig.fail(MESSAGES.InvalidUtf8, 0) end
  local p = setmetatable({ src = input, n = #input, lines = tokenize(input), pos = 1, pending = {}, ipos = 0, iend = 0 }, P)
  local root = p:parse_region(nil, "null_document")
  p:skip_blank()
  if not p:at_end() then p:fail_at_line(p:peek(), "ExtraContent") end
  attach(root, "dangling", p:take_leading())
  return root
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: block form throughout, four spaces a
-- level, `key: value` on one line when the value is a non-empty single
-- line and a `>` block below the key otherwise, `- ` items likewise, a
-- key that would not read back as one spelled as `: ` lines with its
-- value always nested; comments as `#` lines — leading above the item,
-- a trailing one on its own line after it, dangling at a container's
-- end. A null root prints nothing; a scalar root is a `>` block.

local INDENT = "    "

local function needs_multiline_key(key)
  if key == "" then return true end
  local c0 = key:sub(1, 1)
  if c0 == "#" or c0 == "{" or c0 == "[" or c0 == " " or c0 == "\t" then return true end
  if (c0 == "-" or c0 == ":" or c0 == ">") and (#key == 1 or key:sub(2, 2) == " ") then return true end
  if key:find("\n", 1, true) then return true end
  if key:find(": ", 1, true) then return true end
  return false
end

local function scalar_text(row)
  local k = row.kind
  if k == "string" then return row.text or "" end
  if k == "int" or k == "float" or k == "bool" then return row.text or "" end
  if k == "null" then error("NestedText has no null; a null value cannot be written", 0) end
  if k == "alias" then error("an alias must be resolved before it is written as NestedText", 0) end
  error("a " .. k .. " is not a value", 0)
end

local Pr = {}
Pr.__index = Pr

function Pr:indent(depth) self.w:put(INDENT:rep(depth)) end

-- `tag` lines (`> ` or `: `) for each line of `text`, a bare tag for an
-- empty line.
function Pr:tagged_lines(tag, depth, text)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    self:indent(depth)
    self.w:put(line == "" and tag or (tag .. " " .. line), "\n")
  end
end

function Pr:hash_lines(texts, depth)
  for _, c in ipairs(texts) do
    for line in (c.text .. "\n"):gmatch("(.-)\n") do
      local t = line:match("^[ \t]*(.-)[ \t]*$")
      self:indent(depth)
      self.w:put(t == "" and "#" or ("# " .. t), "\n")
    end
  end
end

function Pr:item_value(row, depth, force_nested)
  local w = self.w
  local k = row.kind
  if k == "mapping" then
    if not force_nested then w:put("\n") end
    self:mapping(row, depth + 1)
  elseif k == "sequence" then
    if not force_nested then w:put("\n") end
    self:sequence(row, depth + 1)
  else
    local text = scalar_text(row)
    if not force_nested and text ~= "" and not text:find("\n", 1, true) then
      w:put(" ", text, "\n")
    else
      if not force_nested then w:put("\n") end
      self:tagged_lines(">", depth + 1, text)
    end
  end
end

function Pr:mapping(row, depth)
  for _, kv in ipairs(row.items) do
    self:hash_lines(kv.key.leading, depth)
    if kv.key.kind ~= "string" then error("a NestedText key must be a string", 0) end
    local key_text = kv.key.text or ""
    local multiline = needs_multiline_key(key_text)
    if multiline then
      self:tagged_lines(":", depth, key_text)
    else
      self:indent(depth)
      self.w:put(key_text, ":")
    end
    self:item_value(kv.value, depth, multiline)
    self:hash_lines(kv.value.trailing, depth)
  end
  self:hash_lines(row.dangling, depth)
end

function Pr:sequence(row, depth)
  for _, item in ipairs(row.items) do
    self:hash_lines(item.leading, depth)
    self:indent(depth)
    self.w:put("-")
    self:item_value(item, depth, false)
    self:hash_lines(item.trailing, depth)
  end
  self:hash_lines(row.dangling, depth)
end

function M.print(_dialect, t, _options)
  local w = fig.writer()
  local p = setmetatable({ w = w }, Pr)
  local root = t.byid(0)
  if root.kind == "null" then
    return ""
  elseif root.kind == "mapping" then
    p:mapping(root, 0)
  elseif root.kind == "sequence" then
    p:sequence(root, 0)
  else
    p:tagged_lines(">", 0, scalar_text(root))
  end
  return w:string()
end

-- ── the renderers ─────────────────────────────────────────────────────────
-- What the editor splices, spelled as the compiled `editor_helper.zig`
-- spells it. `args.indent` is the line's indentation; a value that is
-- empty or has a line break goes under its key as a `>` block one level
-- in, a single line rides the key's line.

local function value_tail(out, child_indent, text, force_nested)
  if not force_nested and text ~= "" and not text:find("\n", 1, true) then
    out[#out + 1] = " " .. text
    return
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = "\n" .. child_indent .. (line == "" and ">" or ("> " .. line))
  end
end

local function multiline_key_lines(out, indent, key)
  local first = true
  for line in (key .. "\n"):gmatch("(.-)\n") do
    if not first then out[#out + 1] = "\n" .. indent end
    first = false
    out[#out + 1] = line == "" and ":" or (": " .. line)
  end
end

-- Whether the key's source text is the `: ` spelling.
local function is_multiline_key_text(key)
  local k = key:gsub("^[ \t]+", "")
  if k == "" or k:sub(1, 1) ~= ":" then return false end
  if #k == 1 then return true end
  local c = k:sub(2, 2)
  return c == " " or c == "\n" or c == "\r"
end

function M.render(which, args)
  local out = {}
  local indent = args.indent or ""
  local child = indent .. INDENT
  if which == "entry" then
    if needs_multiline_key(args.key) then
      multiline_key_lines(out, indent, args.key)
      value_tail(out, child, args.value, true)
    else
      out[#out + 1] = args.key .. ":"
      value_tail(out, child, args.value, false)
    end
  elseif which == "item" then
    out[#out + 1] = "-"
    value_tail(out, child, args.value, false)
  elseif which == "tail" then
    if args.key == "" then
      local first = true
      for line in (args.value .. "\n"):gmatch("(.-)\n") do
        if not first then out[#out + 1] = "\n" end
        first = false
        out[#out + 1] = line == "" and ">" or ("> " .. line)
      end
    else
      local multiline = is_multiline_key_text(args.key)
      if not multiline then out[#out + 1] = ":" end
      value_tail(out, child, args.value, multiline)
    end
  elseif which == "key" then
    local was_multiline = is_multiline_key_text(args.old_key or "")
    local wants_multiline = needs_multiline_key(args.key)
    if wants_multiline and not was_multiline then
      error("this key needs the `: ` multiline spelling, which cannot replace a plain key in place", 0)
    end
    if wants_multiline then
      out[#out + 1] = indent
      multiline_key_lines(out, indent, args.key)
    elseif was_multiline then
      out[#out + 1] = args.key .. ":"
    else
      out[#out + 1] = args.key
    end
  else
    error("no renderer named " .. tostring(which), 0)
  end
  return table.concat(out)
end

return M
