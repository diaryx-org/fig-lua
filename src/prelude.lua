-- The `fig` global a fig-lua script sees. Loaded before the script, once
-- per process; `require("fig.grammar")`, `require("fig.xml")`,
-- `require("fig.number")` and `require("fig.datetime")` are the modules
-- built beside it.
--
-- Three layers, each written in terms of the one below:
--
--   * the **node table** — `fig.table()`, `t:row(...)`, the wire's shape,
--     which a `parse` may return directly and a `print` receives indexed;
--   * the **tree** — `fig.mapping`, `fig.sequence`, `fig.entry`,
--     `fig.scalar`, nodes that hold their children and their comments as
--     fields, which a `parse` may return instead and `fig.rows` lays out
--     in pre-order; and `fig.scanner`, a byte cursor whose positions are
--     already the wire's;
--   * the **grammar** — `require("fig.grammar")`, combinators whose
--     primitives are these nodes, so a format is a description and the
--     tree, the spans, the comment binding and the duplicate policy fall
--     out of it.
--
-- Offsets are byte offsets into the input, 0-based, `[start, end)` — the
-- wire's, and what `fig lang table` prints. Everything here speaks them; a
-- script only meets Lua's 1-based `string.byte(s, i)` if it goes below the
-- scanner. Row ids are 0-based too: the root is row 0.
local fig = {}

-- ── failure ───────────────────────────────────────────────────────────────

local Failure = {}
Failure.__index = Failure
function Failure:__tostring()
  if self.at then return self.message .. " (at byte " .. self.at .. ")" end
  return self.message
end

--- Refuse the input: raises, from anywhere inside a `parse`, and fig
--- reports `message` at byte offset `at` (nil for "no position"). Any
--- other error a `parse` raises is reported with its message and no
--- offset. `return fig.fail(...)` and a bare `fig.fail(...)` are the same.
function fig.fail(message, at)
  error(setmetatable({ message = message, at = at }, Failure), 0)
end

--- Whether `e`, an error caught by `pcall`, is what `fig.fail` raises.
function fig.is_failure(e)
  return getmetatable(e) == Failure
end

--- What the host calls: runs a script's `parse` and answers with the
--- contract's `table` or `nil, message, offset`. A `parse` may return a
--- node table, a tree node (laid out with `fig.rows`), or raise through
--- `fig.fail`; a `nil, message, offset` return is passed through.
function fig.run_parse(parse, dialect, input)
  local ok, result, message, at = pcall(parse, dialect, input)
  if not ok then
    if fig.is_failure(result) then return nil, result.message, result.at end
    error(result, 0)
  end
  if type(result) == "table" and result.kind ~= nil and result.rows == nil then
    return fig.rows(result)
  end
  return result, message, at
end

-- ── the node table ────────────────────────────────────────────────────────

local Table = {}
Table.__index = Table

--- A new, empty node table. Rows are added in pre-order: a container
--- before its children, a keyvalue before its key and then its value.
function fig.table()
  return setmetatable({ rows = {}, comments = {}, regions = {}, mentions = {}, directives = {} }, Table)
end

--- Add one row and return its id. `kind` is one of "null", "bool", "int",
--- "float", "string", "sequence", "mapping", "keyvalue", "alias"; `parent`
--- is a row id or nil for the root; `span` is `{start, end}`. `extra` may
--- carry `text`, `sep`, `marker`, `anchor`, `anchor_span`, `tag`,
--- `tag_span` and `ext_kind`.
function Table:row(kind, parent, span, extra)
  local id = #self.rows
  local row = { kind = kind, parent = parent, span = span }
  if extra then
    for k, v in pairs(extra) do row[k] = v end
  end
  self.rows[id + 1] = row
  return id
end

--- Bind a comment to row `node`. `slot` is "leading", "trailing" or
--- "dangling"; `style` is "line" or "block"; `text` is the comment's text
--- with its delimiters removed.
function Table:comment(node, slot, style, text)
  self.comments[#self.comments + 1] = { node = node, slot = slot, style = style, text = text }
end

--- Record one header line `[start, end)` belonging to section row `node`.
function Table:region(node, start, stop)
  self.regions[#self.regions + 1] = { node = node, start = start, ["end"] = stop }
end

--- Record one place section row `node`'s name is written; `kind` is
--- "header" or "entry".
function Table:mention(node, span, kind)
  self.mentions[#self.mentions + 1] = { node = node, span = span, kind = kind }
end

--- Record one tag-handle declaration of the document (a YAML `%TAG`):
--- `handle` is `!e!`, or a redefined `!`/`!!`, and `prefix` what it
--- expands to. A print of a whole document receives them back, in this
--- order, to re-emit above any tag that uses one.
function Table:directive(handle, prefix)
  self.directives[#self.directives + 1] = { handle = handle, prefix = prefix }
end

--- Whether `kind` names a scalar row.
function fig.is_scalar(kind)
  return kind ~= "sequence" and kind ~= "mapping" and kind ~= "keyvalue" and kind ~= "alias"
end

--- Index a table a `print` receives (fig calls this before the script's
--- `print`): every row gains `id`, `children` (its child ids, in order),
--- `items` (the same children as rows), and `leading`, `trailing`,
--- `dangling` (its comments, each `{style=, text=}`); a keyvalue row gains
--- `key` and `value`, its two children as rows; the table gains
--- `byid(id)`.
function fig.index(t)
  t.rows = t.rows or {}
  t.comments = t.comments or {}
  t.regions = t.regions or {}
  t.mentions = t.mentions or {}
  t.directives = t.directives or {}
  for i, row in ipairs(t.rows) do
    row.id = i - 1
    row.children = {}
    row.items = {}
    row.leading = {}
    row.trailing = {}
    row.dangling = {}
  end
  for i, row in ipairs(t.rows) do
    if row.parent ~= nil then
      local p = t.rows[row.parent + 1]
      p.children[#p.children + 1] = i - 1
      p.items[#p.items + 1] = row
    end
  end
  for _, row in ipairs(t.rows) do
    if row.kind == "keyvalue" then
      row.key = row.items[1]
      row.value = row.items[2]
    end
  end
  for _, c in ipairs(t.comments) do
    local row = t.rows[c.node + 1]
    local slot = row[c.slot]
    slot[#slot + 1] = { style = c.style, text = c.text }
  end
  function t.byid(id) return t.rows[id + 1] end
  return t
end

--- The child ids of row `id` in an indexed table.
function fig.children(t, id)
  return t.rows[id + 1].children
end

-- ── the tree ──────────────────────────────────────────────────────────────
-- A node is a table with `kind` and `span`, and for a scalar `text`; a
-- mapping holds `entries` (keyvalue nodes), a sequence `items`, a keyvalue
-- its `key` and `value`. Comments are `leading`, `trailing` and `dangling`
-- lists of `{style=, text=}`. `fig.rows` walks one into a node table.

local Node = {}
Node.__index = Node

local function node(kind, span, extra)
  local n = setmetatable({ kind = kind, span = span }, Node)
  if extra then
    for k, v in pairs(extra) do n[k] = v end
  end
  return n
end

--- Any node; the constructors below are the usual spellings of it.
fig.node = node

--- A scalar: `kind` is "null", "bool", "int", "float" or "string";
--- `extra` may carry `ext_kind`, `tag`, `tag_span`, `anchor`,
--- `anchor_span`.
function fig.scalar(kind, span, text, extra)
  local n = node(kind, span, extra)
  n.text = text
  return n
end

--- A mapping. `opts.duplicates` says what `map:put` does with a repeated
--- key: "last_value" (the default — the first entry keeps its place and
--- span and takes the last value, as `plutil` and every flat format here
--- do), "first_value" (a later entry is ignored), "keep" (both stay), or
--- "error" (refused, at the later key). The span may be filled in later.
function fig.mapping(span, opts)
  local n = node("mapping", span)
  n.entries = {}
  n.by_key = {}
  n.duplicates = opts and opts.duplicates or "last_value"
  return n
end

--- A sequence; `seq:add(item)` appends.
function fig.sequence(span)
  local n = node("sequence", span)
  n.items = {}
  return n
end

--- A keyvalue over two nodes. The span defaults to the key's start
--- through the value's end.
function fig.entry(key, value, span)
  local n = node("keyvalue", span or { key.span[1], value.span[2] })
  n.key = key
  n.value = value
  return n
end

--- Put an entry in a mapping by its duplicate policy; returns the entry
--- that holds the value afterwards. A key with no text — a null, a
--- container, in a format whose keys are nodes — repeats nothing.
function Node:put(entry)
  local name = entry.key.text
  local existing = name ~= nil and self.by_key[name] or nil
  local policy = self.duplicates
  if existing and policy ~= "keep" then
    if policy == "last_value" then
      -- The first entry keeps its place, its key and its span; the later
      -- key, and the comments on it, are unreachable.
      existing.value = entry.value
      return existing
    elseif policy == "first_value" then
      return existing
    elseif policy == "error" then
      fig.fail("duplicate key `" .. name .. "`", entry.key.span[1])
    end
    error("unknown duplicate policy `" .. tostring(policy) .. "`", 0)
  end
  self.entries[#self.entries + 1] = entry
  if name ~= nil and not existing then self.by_key[name] = entry end
  return entry
end

--- Append an item to a sequence.
function Node:add(item)
  self.items[#self.items + 1] = item
  return item
end

--- Bind a comment to this node: `slot` is "leading", "trailing" or
--- "dangling", `style` "line" (the default) or "block".
function Node:comment(slot, text, style)
  local list = self[slot]
  if not list then
    list = {}
    self[slot] = list
  end
  list[#list + 1] = { style = style or "line", text = text }
  return self
end

--- A tree as a node table: rows in pre-order, comments bound by row.
function fig.rows(root)
  local t = fig.table()
  local function emit(n, parent)
    local id = t:row(n.kind, parent, n.span, {
      text = n.text,
      ext_kind = n.ext_kind,
      sep = n.sep,
      marker = n.marker,
      anchor = n.anchor,
      anchor_span = n.anchor_span,
      tag = n.tag,
      tag_span = n.tag_span,
    })
    for _, slot in ipairs({ "leading", "trailing", "dangling" }) do
      local list = n[slot]
      if list then
        for _, c in ipairs(list) do t:comment(id, slot, c.style or "line", c.text) end
      end
    end
    if n.regions then
      for _, r in ipairs(n.regions) do t:region(id, r[1], r[2]) end
    end
    if n.mentions then
      for _, m in ipairs(n.mentions) do t:mention(id, m.span, m.kind) end
    end
    if n.kind == "mapping" then
      for _, e in ipairs(n.entries) do emit(e, id) end
    elseif n.kind == "sequence" then
      for _, item in ipairs(n.items) do emit(item, id) end
    elseif n.kind == "keyvalue" then
      emit(n.key, id)
      if n.value then emit(n.value, id) end
    end
    return id
  end
  emit(root, nil)
  return t
end

-- ── bytes and text ────────────────────────────────────────────────────────

--- Whether `cp` is a UTF-16 surrogate, high or low: a codepoint no text
--- can hold on its own.
function fig.is_surrogate(cp)
  return cp >= 0xD800 and cp <= 0xDFFF
end

--- The codepoint a `\uXXXX\uXXXX` surrogate pair spells, or nil when
--- `hi` and `lo` are not a high surrogate followed by a low one.
function fig.surrogate_pair(hi, lo)
  if hi >= 0xD800 and hi <= 0xDBFF and lo >= 0xDC00 and lo <= 0xDFFF then
    return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
  end
  return nil
end

--- A comment's text as the wire carries it: `raw` with the spaces, tabs
--- and carriage returns at either end removed.
function fig.trim_comment(raw)
  return (raw:match("^[ \t\r]*(.-)[ \t\r]*$"))
end

-- ── the token cursor ──────────────────────────────────────────────────────
-- A parser written over a token list rather than a grammar — one whose
-- tokenizer runs first — walks the list with this: `peek`, `advance`, the
-- text a token covers, and a failure at the token in hand.

local Cursor = {}
Cursor.__index = Cursor

--- A cursor over `tokens` — each `{kind=, s=, e=}` over byte offsets, the
--- last an end-of-input token the cursor never moves past — reading text
--- through scanner `sc`.
function fig.cursor(tokens, sc)
  return setmetatable({ tokens = tokens, sc = sc, pos = 1 }, Cursor)
end

--- The token in hand.
function Cursor:peek()
  return self.tokens[self.pos]
end

--- The token `k` (1) past the one in hand, or the last.
function Cursor:ahead(k)
  return self.tokens[math.min(self.pos + (k or 1), #self.tokens)]
end

--- The token in hand, moving to the next unless it is the last.
function Cursor:advance()
  local t = self.tokens[self.pos]
  if self.pos < #self.tokens then self.pos = self.pos + 1 end
  return t
end

--- Whether the token in hand is of `kind`.
function Cursor:at(kind)
  return self.tokens[self.pos].kind == kind
end

--- The token in hand when it is of `kind`, moving past it; else nil.
function Cursor:take(kind)
  if self:at(kind) then return self:advance() end
  return nil
end

--- The text `t` (the token in hand) covers.
function Cursor:text(t)
  t = t or self.tokens[self.pos]
  return self.sc:slice(t.s, t.e)
end

--- `fig.fail` at the start of `t` (the token in hand).
function Cursor:fail(message, t)
  fig.fail(message, (t or self.tokens[self.pos]).s)
end

-- ── the scanner ───────────────────────────────────────────────────────────
-- A cursor over the input whose `pos` is a 0-based byte offset, so every
-- span it hands out is the wire's. Nothing here advances on a miss.

local Scanner = {}
Scanner.__index = Scanner

--- A scanner over `src`, at `pos` (0).
function fig.scanner(src, pos)
  return setmetatable({ src = src, pos = pos or 0, n = #src }, Scanner)
end

function Scanner:eof() return self.pos >= self.n end

--- The byte `k` (0) past the cursor, or nil past the end; `k` may be
--- negative.
function Scanner:byte(k)
  return string.byte(self.src, self.pos + (k or 0) + 1)
end

--- Whether the input at the cursor begins with `s`.
function Scanner:starts(s)
  return self.src:sub(self.pos + 1, self.pos + #s) == s
end

--- The bytes `[s, e)`.
function Scanner:slice(s, e)
  return self.src:sub(s + 1, e)
end

--- Match a Lua pattern anchored at the cursor. Advances past it and
--- returns the span `s, e` and then the pattern's captures, or nil.
function Scanner:match(pattern)
  local r = table.pack(self.src:find("^" .. pattern, self.pos + 1))
  if r[1] == nil then return nil end
  local s, e = r[1] - 1, r[2]
  self.pos = e
  return s, e, table.unpack(r, 3, r.n)
end

--- Match the literal `s` at the cursor: advances and returns the span, or
--- nil.
function Scanner:lit(s)
  if not self:starts(s) then return nil end
  local start = self.pos
  self.pos = start + #s
  return start, self.pos
end

--- The offset of the next `s` at or after the cursor, plain, or nil.
function Scanner:find(s)
  local at = self.src:find(s, self.pos + 1, true)
  return at and at - 1
end

--- Move the cursor `k` bytes (1) forward.
function Scanner:advance(k)
  self.pos = self.pos + (k or 1)
  return self.pos
end

--- Whether no newline lies in `[a, b)`: what "on the same line" means to
--- a trailing comment.
function Scanner:same_line(a, b)
  local nl = self.src:find("\n", a + 1, true)
  return nl == nil or nl - 1 >= b
end

--- `fig.fail` at the cursor, or at `at`.
function Scanner:fail(message, at)
  fig.fail(message, at or self.pos)
end

-- ── the writer ────────────────────────────────────────────────────────────

local Writer = {}
Writer.__index = Writer

--- A buffer for a `print`, that knows the `options` it was given:
--- `w:nl()` and `w:indent(depth)` write nothing when `pretty` is off, and
--- the unit of indentation is `options.indent` spaces (2).
function fig.writer(options)
  options = options or {}
  return setmetatable({
    parts = {},
    pretty = options.pretty ~= false,
    unit = string.rep(" ", options.indent or 2),
  }, Writer)
end

--- Append each argument.
function Writer:put(...)
  local parts = self.parts
  for i = 1, select("#", ...) do
    parts[#parts + 1] = select(i, ...)
  end
  return self
end

function Writer:nl()
  if self.pretty then self.parts[#self.parts + 1] = "\n" end
  return self
end

function Writer:indent(depth)
  if self.pretty and depth > 0 then self.parts[#self.parts + 1] = string.rep(self.unit, depth) end
  return self
end

--- Indent, write the arguments, end the line.
function Writer:line(depth, ...)
  return self:indent(depth):put(...):nl()
end

--- Write `comments` (a row's `leading`, say) as full lines, each line of
--- each comment's text on its own, trimmed, after `leader` and a space —
--- `# text`, or the bare leader for an empty line — indented by `depth`
--- (0). Answers whether anything was written.
function Writer:comments(comments, leader, depth)
  local wrote = false
  for _, c in ipairs(comments) do
    for line in (c.text .. "\n"):gmatch("(.-)\n") do
      local t = line:match("^[ \t]*(.-)[ \t]*$")
      self:indent(depth or 0):put(t == "" and leader or (leader .. " " .. t), "\n")
      wrote = true
    end
  end
  return wrote
end

function Writer:string()
  return table.concat(self.parts)
end

return fig
