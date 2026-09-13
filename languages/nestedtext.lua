-- NestedText, in Lua: a twin of fig's compiled `nestedtext` format.
--
-- NestedText is an indentation-based format in which every value is a
-- string, held literally — no quoting, no escapes, no types. A line is
-- `key: value` or `key:` (a dict item), `: text` (one line of a multiline
-- key), `- value` (a list item), `> text` (one line of a string block),
-- `# comment`, or blank; a value left empty on its line is the block of
-- more-indented lines below it, or the empty string where those lines
-- would have begun. A line that begins `{` or `[` where a value starts is
-- an inline dict or list, read to the end of that line.
--
-- The node table this builds is held row for row against the compiled
-- format — kinds, spans, `sep`, `marker` and comments alike — by `cargo
-- test --test twins nestedtext`, against the `*.table.json` beside every
-- fixture in `tests/fixtures/nestedtext/`; `fig lang table -i nestedtext`
-- prints that table for any input. The printer's bytes and the four
-- editor renderers are held to the compiled format the same way.
--
-- The refusals are the format's, worded here: every document the compiled
-- format refuses this script refuses too, in its own words and at its own
-- offsets. Indentation is plain spaces: a tab or a no-break space where
-- indentation is read is refused.
--
-- Every offset is a byte offset, and Lua strings are bytes, so the line
-- records index the input directly.

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

-- Each line of `s`, the last one included even when it is empty.
local function lines_of(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

-- ── the tokenizer ─────────────────────────────────────────────────────────
-- One record per physical line: `{ kind=, indent=, line_start=, s=, e= }`
-- with `kind` one of `blank`, `comment`, `dash`, `colon`, `gt`, `other`,
-- `end_of_file`; `[s, e)` is the content after the tag and its one space,
-- the whole line for `other`.

local TAGS = { [45] = "dash", [58] = "colon", [62] = "gt" }

local function tokenize(src)
  local n = #src
  local function at(k) return src:byte(k + 1) end
  local lines = {}
  local i = src:sub(1, 3) == "\239\187\191" and 3 or 0
  while i < n do
    local line_start = i
    local j = i
    while at(j) == 32 do j = j + 1 end
    local e = j
    while e < n and at(e) ~= 10 and at(e) ~= 13 do e = e + 1 end
    local line = { kind = "blank", indent = j - line_start, line_start = line_start, s = e, e = e }
    if j < e then
      local c = at(j)
      if c == 9 or (c == 0xC2 and at(j + 1) == 0xA0) then
        fig.fail("indentation must be plain spaces", line_start)
      end
      local tagged = TAGS[c] ~= nil and (j + 1 == e or at(j + 1) == 32)
      if c == 35 then
        line.kind = "comment"
        line.s = j + 1
      elseif tagged then
        line.kind = TAGS[c]
        line.s = math.min(j + 2, e)
      else
        line.kind = "other"
        line.s = j
      end
    end
    lines[#lines + 1] = line
    i = e + (at(e) == 13 and 1 or 0)
    if at(i) == 10 then i = i + 1 end
  end
  lines[#lines + 1] = { kind = "end_of_file", indent = 0, line_start = n, s = n, e = n }
  return lines
end

-- ── the parser ────────────────────────────────────────────────────────────

local INLINE_STOP = { [44] = true, [123] = true, [125] = true, [91] = true, [93] = true }

local function attach(node, slot, texts)
  for _, t in ipairs(texts) do node:comment(slot, t) end
  return node
end

local P = {}
P.__index = P

function P:peek() return self.lines[self.pos] end
function P:at_end() return self:peek().kind == "end_of_file" end
function P:text(s, e) return self.src:sub(s + 1, e) end
function P:fail_at_line(l, message) fig.fail(message, l.line_start) end

-- Comment lines pile up to lead the next item; blank lines are nothing.
function P:skip_blank()
  while true do
    local l = self:peek()
    if l.kind == "comment" then
      self.pending[#self.pending + 1] = self:text(l.s, l.e)
    elseif l.kind ~= "blank" then
      return
    end
    self.pos = self.pos + 1
  end
end

function P:take_leading()
  local out = self.pending
  self.pending = {}
  return out
end

-- A line beginning `{` or `[` is an inline value, not a dict item.
function P:bracket(l)
  local c = self.src:byte(l.s + 1)
  return l.e > l.s and (c == 123 or c == 91)
end

-- `key: value` / `key:`: where the key ends and the value begins, or nil.
function P:split_dict_item(l)
  for i = l.s, l.e - 1 do
    if self.src:byte(i + 1) == 58 then
      if i + 1 == l.e then return i, l.e end
      if self.src:byte(i + 2) == 32 then return i, i + 2 end
    end
  end
  return nil
end

function P:is_dict_item(l)
  return not self:bracket(l) and self:split_dict_item(l) ~= nil
end

-- The value that belongs here: the whole document (`parent_indent` nil,
-- at indent 0) or the block under an item whose own line left its value
-- empty (more indented than `parent_indent`). Nothing there is
-- `on_missing`: a null document, an empty string, or a refusal.
function P:parse_region(parent_indent, on_missing)
  self:skip_blank()
  if self:at_end() or (parent_indent ~= nil and self:peek().indent <= parent_indent) then
    if on_missing == "null" then
      return fig.scalar("null", { self.n, self.n })
    elseif on_missing == "empty" then
      local at = self:at_end() and self.n or self:peek().line_start
      return fig.scalar("string", { at, at }, "")
    end
    self:fail_at_line(self:peek(), "expected a value here")
  end
  local first = self:peek()
  if parent_indent == nil and first.indent ~= 0 then
    self:fail_at_line(first, "the document's first line must start in column 1")
  end
  if first.kind == "other" and self:bracket(first) then
    local node = self:parse_inline_line(first)
    self.pos = self.pos + 1
    self:skip_blank()
    if not self:at_end() and (parent_indent == nil or self:peek().indent > parent_indent) then
      self:fail_at_line(self:peek(), "nothing may follow an inline value")
    end
    return node
  end
  return self:parse_block(first.indent)
end

function P:parse_block(indent)
  local first = self:peek()
  if first.kind == "dash" then return self:parse_list(indent) end
  if first.kind == "gt" then
    local text, span = self:join_lines("gt", indent)
    return fig.scalar("string", span, text)
  end
  if first.kind == "colon" or self:is_dict_item(first) then return self:parse_dict(indent) end
  self:fail_at_line(first, "this line is not a dictionary item, a list item, a string line, or a comment")
end

-- The value written after a `- ` or `key: `, or the block below it when
-- the line left it empty.
function P:item_value(s, e, indent)
  if e ~= s then return fig.scalar("string", { s, e }, self:text(s, e)) end
  return self:parse_region(indent, "empty")
end

function P:parse_list(indent)
  local start = self:peek().line_start
  local seq = fig.sequence({ start, start })
  while true do
    self:skip_blank()
    if self:at_end() then break end
    local l = self:peek()
    if l.indent < indent then break end
    if l.indent > indent then self:fail_at_line(l, "this line is indented past the list it is in") end
    if l.kind ~= "dash" then self:fail_at_line(l, "expected a list item (`- value`) here") end
    self.pos = self.pos + 1
    local leading = self:take_leading()
    local value = attach(self:item_value(l.s, l.e, indent), "leading", leading)
    local dash = l.line_start + l.indent
    value.marker = { dash, dash + 1 }
    seq:add(value)
    seq.span[2] = value.span[2]
  end
  return seq
end

function P:parse_dict(indent)
  local start = self:peek().line_start
  local map = fig.mapping({ start, start }, { duplicates = "error" })
  while true do
    self:skip_blank()
    if self:at_end() then break end
    local l = self:peek()
    if l.indent < indent then break end
    if l.indent > indent then self:fail_at_line(l, "this line is indented past the dictionary it is in") end
    local key, value, sep
    if l.kind == "colon" then
      local text, span = self:join_lines("colon", indent)
      key = attach(fig.scalar("string", span, text), "leading", self:take_leading())
      if self:at_end() or self:peek().indent <= indent then
        self:fail_at_line(self:peek(), "a multiline key needs its value on a more-indented line below it")
      end
      value = self:parse_region(indent, nil)
      sep = { span[2], span[2] }
    elseif l.kind == "other" and self:is_dict_item(l) then
      local key_end, value_start = self:split_dict_item(l)
      self.pos = self.pos + 1
      -- The key is what precedes the `:`, trimmed of trailing spaces,
      -- tabs and no-break spaces, byte by byte.
      local key_text = (self:text(l.s, key_end):gsub("[ \t\194\160]+$", ""))
      key = fig.scalar("string", { l.s, l.s + #key_text }, key_text)
      attach(key, "leading", self:take_leading())
      value = self:item_value(value_start, l.e, indent)
      sep = { key_end, key_end + 1 }
    else
      self:fail_at_line(l, "expected a dictionary item (`key: value`, or a `: key` line) here")
    end
    local kv = fig.entry(key, value)
    kv.sep = sep
    map:put(kv)
    map.span[2] = value.span[2]
  end
  return map
end

-- The `: ` lines of a multiline key, or the `> ` lines of a string block,
-- at `indent`: joined with `\n`, spanning the first line's start to the
-- last line's content end; blank and comment lines between are skipped.
function P:join_lines(kind, indent)
  local parts = {}
  local start = self:peek().line_start
  local end_ = start
  while true do
    local i = self.pos
    while self.lines[i].kind == "blank" or self.lines[i].kind == "comment" do i = i + 1 end
    local l = self.lines[i]
    if l.kind ~= kind or l.indent ~= indent then break end
    parts[#parts + 1] = self:text(l.s, l.e)
    end_ = l.e
    self.pos = i + 1
  end
  return table.concat(parts, "\n"), { start, end_ }
end

-- ── inline values ─────────────────────────────────────────────────────────
-- `{…}` and `[…]` on one line, scanned over absolute offsets between
-- `ipos` and the line's end.

function P:byte() return self.src:byte(self.ipos + 1) end

function P:skip_inline_ws()
  while self.ipos < self.iend and (self:byte() == 32 or self:byte() == 9) do self.ipos = self.ipos + 1 end
end

function P:parse_inline_line(l)
  self.ipos = l.s
  self.iend = l.e
  local node = self:parse_inline_value(nil)
  self:skip_inline_ws()
  if self.ipos < self.iend then fig.fail("nothing may follow the closing `}` or `]`", self.ipos) end
  return node
end

-- A value inside an inline container, or the container itself. Text runs
-- to the next `,` or bracket and keeps its inner spaces, losing the ones
-- at its end.
function P:parse_inline_value(close)
  self:skip_inline_ws()
  if self.ipos >= self.iend then fig.fail("this inline value was never closed", self.ipos) end
  local c = self:byte()
  if c == 123 or c == 91 then return self:parse_inline_container(c) end
  local start = self.ipos
  while self.ipos < self.iend and not INLINE_STOP[self:byte()] do self.ipos = self.ipos + 1 end
  if self.ipos < self.iend and self:byte() ~= 44 and self:byte() ~= close then
    fig.fail("expected `,` or a closing `}` or `]` here", self.ipos)
  end
  return fig.scalar("string", { start, self.ipos }, (self:text(start, self.ipos):gsub("[ \t]+$", "")))
end

-- `{key: value, …}` when `open` is `{`, `[value, …]` when it is `[`. An
-- empty one closes at once; a dict refuses a trailing comma, where a list
-- reads one as an empty value.
function P:parse_inline_container(open)
  local dict = open == 123
  local close = dict and 125 or 93
  local start = self.ipos
  self.ipos = self.ipos + 1
  local node = dict and fig.mapping({ start, start }, { duplicates = "error" }) or fig.sequence({ start, start })
  if self.ipos < self.iend and self:byte() == close then
    self.ipos = self.ipos + 1
  else
    while true do
      if dict then
        self:parse_inline_entry(node)
      else
        node:add(self:parse_inline_value(close))
      end
      self:skip_inline_ws()
      if self.ipos >= self.iend then fig.fail("this inline value was never closed", self.ipos) end
      local d = self:byte()
      self.ipos = self.ipos + 1
      if d == close then break end
      if d ~= 44 then fig.fail("expected `,` or a closing `}` or `]` here", self.ipos - 1) end
      if dict then
        self:skip_inline_ws()
        if self.ipos < self.iend and self:byte() == close then
          fig.fail("expected a value after `,`", self.ipos)
        end
      end
    end
  end
  node.span[2] = self.ipos
  return node
end

function P:parse_inline_entry(map)
  self:skip_inline_ws()
  local start = self.ipos
  while self.ipos < self.iend and self:byte() ~= 58 and not INLINE_STOP[self:byte()] do
    self.ipos = self.ipos + 1
  end
  if self.ipos >= self.iend then fig.fail("this inline value was never closed", self.ipos) end
  if self:byte() ~= 58 then fig.fail("expected `:` after this inline dictionary key", self.ipos) end
  local key_text = (self:text(start, self.ipos):gsub("[ \t]+$", ""))
  local key = fig.scalar("string", { start, self.ipos }, key_text)
  self.ipos = self.ipos + 1
  map:put(fig.entry(key, self:parse_inline_value(125)))
end

function M.parse(_dialect, input)
  -- The host hands a Lua script raw bytes, so the format's own demand for
  -- UTF-8 is checked here.
  if not utf8.len(input) then
    fig.fail("this file is not valid UTF-8; NestedText documents must be UTF-8", 0)
  end
  local p = setmetatable(
    { src = input, n = #input, lines = tokenize(input), pos = 1, pending = {}, ipos = 0, iend = 0 },
    P
  )
  local root = p:parse_region(nil, "null")
  p:skip_blank()
  if not p:at_end() then p:fail_at_line(p:peek(), "nothing may follow the document's value") end
  return attach(root, "dangling", p:take_leading())
end

-- ── the printer ───────────────────────────────────────────────────────────
-- Block form throughout, four spaces a level: `key: value` on one line
-- when the value is a non-empty single line and a `>` block below the key
-- otherwise, `- ` items likewise, a key that would not read back as one
-- spelled as `: ` lines with its value always nested; comments as `#`
-- lines — leading above the item, a trailing one on its own line after
-- it, dangling at a container's end. A null root prints nothing; a scalar
-- root is a `>` block.

local INDENT = "    "

-- Whether `key` has to be written as `: ` lines: one that would read back
-- as a tag, a comment, an inline value, or a second key.
local function needs_multiline_key(key)
  if key == "" then return true end
  local c0 = key:sub(1, 1)
  if ("#{[ \t"):find(c0, 1, true) then return true end
  if (c0 == "-" or c0 == ":" or c0 == ">") and (#key == 1 or key:sub(2, 2) == " ") then return true end
  return key:find("\n", 1, true) ~= nil or key:find(": ", 1, true) ~= nil
end

local function scalar_text(row)
  local k = row.kind
  if k == "string" or k == "int" or k == "float" or k == "bool" then return row.text or "" end
  if k == "null" then error("NestedText has no null; a null value cannot be written", 0) end
  if k == "alias" then error("an alias must be resolved before it is written as NestedText", 0) end
  error("a " .. k .. " is not a value", 0)
end

local Pr = {}
Pr.__index = Pr

-- `tag` lines (`> ` or `: `) for each line of `text`, a bare tag for an
-- empty line.
function Pr:tagged_lines(tag, depth, text)
  for _, line in ipairs(lines_of(text)) do
    self.w:indent(depth):put(line == "" and tag or (tag .. " " .. line), "\n")
  end
end

function Pr:item_value(row, depth, force_nested)
  if row.kind == "mapping" or row.kind == "sequence" then
    if not force_nested then self.w:put("\n") end
    self:container(row, depth + 1)
    return
  end
  local text = scalar_text(row)
  if not force_nested and text ~= "" and not text:find("\n", 1, true) then
    self.w:put(" ", text, "\n")
    return
  end
  if not force_nested then self.w:put("\n") end
  self:tagged_lines(">", depth + 1, text)
end

function Pr:container(row, depth)
  local dict = row.kind == "mapping"
  for _, item in ipairs(row.items) do
    local value = dict and item.value or item
    self.w:comments((dict and item.key or item).leading, "#", depth)
    local multiline = false
    if dict then
      if item.key.kind ~= "string" then error("a NestedText key must be a string", 0) end
      local key_text = item.key.text or ""
      multiline = needs_multiline_key(key_text)
      if multiline then
        self:tagged_lines(":", depth, key_text)
      else
        self.w:indent(depth):put(key_text, ":")
      end
    else
      self.w:indent(depth):put("-")
    end
    self:item_value(value, depth, multiline)
    self.w:comments(value.trailing, "#", depth)
  end
  self.w:comments(row.dangling, "#", depth)
end

function M.print(_dialect, t, _options)
  local w = fig.writer({ indent = #INDENT })
  local p = setmetatable({ w = w }, Pr)
  local root = t.byid(0)
  if root.kind == "null" then
    return ""
  elseif root.kind == "mapping" or root.kind == "sequence" then
    p:container(root, 0)
  else
    p:tagged_lines(">", 0, scalar_text(root))
  end
  return w:string()
end

-- ── the renderers ─────────────────────────────────────────────────────────
-- What the editor splices. `args.indent` is the line's indentation; a
-- value that is empty or has a line break goes under its key as a `>`
-- block one level in, a single line rides the key's line.

-- Each line of `text` after `tag` — a bare tag for an empty line — joined
-- with `sep`.
local function tagged(text, tag, sep)
  local parts = {}
  for _, line in ipairs(lines_of(text)) do
    parts[#parts + 1] = line == "" and tag or (tag .. " " .. line)
  end
  return table.concat(parts, sep)
end

local function value_tail(out, child_indent, text, force_nested)
  if not force_nested and text ~= "" and not text:find("\n", 1, true) then
    out[#out + 1] = " " .. text
  else
    out[#out + 1] = "\n" .. child_indent .. tagged(text, ">", "\n" .. child_indent)
  end
end

-- Whether the key's source text is already the `: ` spelling.
local function is_multiline_key_text(key)
  local k = key:gsub("^[ \t]+", "")
  if k == "" or k:sub(1, 1) ~= ":" then return false end
  local c = k:sub(2, 2)
  return #k == 1 or c == " " or c == "\n" or c == "\r"
end

function M.render(which, args)
  local out = {}
  local indent = args.indent or ""
  local child = indent .. INDENT
  if which == "entry" then
    local multiline = needs_multiline_key(args.key)
    out[#out + 1] = multiline and tagged(args.key, ":", "\n" .. indent) or (args.key .. ":")
    value_tail(out, child, args.value, multiline)
  elseif which == "item" then
    out[#out + 1] = "-"
    value_tail(out, child, args.value, false)
  elseif which == "tail" then
    if args.key == "" then
      out[#out + 1] = tagged(args.value, ">", "\n")
    else
      local multiline = is_multiline_key_text(args.key)
      if not multiline then out[#out + 1] = ":" end
      value_tail(out, child, args.value, multiline)
    end
  elseif which == "key" then
    local was_multiline = is_multiline_key_text(args.old_key or "")
    if needs_multiline_key(args.key) then
      if not was_multiline then
        error("this key needs the `: ` multiline spelling, which cannot replace a plain key in place", 0)
      end
      out[#out + 1] = indent .. tagged(args.key, ":", "\n" .. indent)
    else
      out[#out + 1] = was_multiline and (args.key .. ":") or args.key
    end
  else
    error("no renderer named " .. tostring(which), 0)
  end
  return table.concat(out)
end

return M
