-- The `fig` global a fig-lua script sees: a builder for the node table a
-- `parse` returns, the failure convention, and the index a `print` receives
-- its table with. Loaded before the script, once per process.
--
-- Offsets are byte offsets into the input, 0-based, `[start, end)` — the
-- wire's, and what `fig lang table` prints — so a script converts from
-- Lua's 1-based `string.byte(s, i)` with `i - 1`. Row ids are 0-based too:
-- the root is row 0, and `t:row(...)` returns the id of the row it added.
local fig = {}

local Table = {}
Table.__index = Table

--- A new, empty node table. Rows are added in pre-order: a container
--- before its children, a keyvalue before its key and then its value.
function fig.table()
  return setmetatable({ rows = {}, comments = {}, regions = {}, mentions = {} }, Table)
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

--- What a `parse` returns to refuse its input: `return fig.fail("why", at)`.
--- `at` is the byte offset the message is about, or nil.
function fig.fail(message, byte_offset)
  return nil, message, byte_offset
end

--- Index a table a `print` receives (fig calls this before the script's
--- `print`): every row gains `id`, `children` (its child ids, in order),
--- and `leading`, `trailing`, `dangling` (its comments, each
--- `{style=, text=}`); the table gains `byid(id)`.
function fig.index(t)
  t.rows = t.rows or {}
  t.comments = t.comments or {}
  t.regions = t.regions or {}
  t.mentions = t.mentions or {}
  for i, row in ipairs(t.rows) do
    row.id = i - 1
    row.children = {}
    row.leading = {}
    row.trailing = {}
    row.dangling = {}
  end
  for i, row in ipairs(t.rows) do
    if row.parent ~= nil then
      local p = t.rows[row.parent + 1].children
      p[#p + 1] = i - 1
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

--- Whether `kind` names a scalar row.
function fig.is_scalar(kind)
  return kind ~= "sequence" and kind ~= "mapping" and kind ~= "keyvalue" and kind ~= "alias"
end

return fig
