-- Apple property lists (the XML form), in Lua: the twin of fig's compiled
-- `plist` format, row for row.
--
-- The contract is the format and the tree it makes: for every document the
-- compiled `plist` reads, this script builds the same node table and
-- prints the same bytes, and it refuses what the compiled format refuses —
-- in words and at offsets of its own. `fig lang table -i plist` prints
-- that table, and `fig lang check lua-plist --against plist <files…>` holds
-- this script to it on any file. What the format is:
--
--   * `<plist [version="…"]>OBJECT</plist>`, or a bare OBJECT with no
--     wrapper; an XML declaration, a DOCTYPE without an internal subset,
--     processing instructions and `<!-- -->` comments are skipped;
--   * `dict` is a mapping of `<key>`/value pairs, `array` a sequence;
--     `string`, `integer`, `real`, `true`, `false` are the scalars they
--     name; `date` and `data` are extended scalars (`data` with all
--     whitespace stripped from the base64); entity references and CDATA
--     are decoded in text content; no element takes an attribute;
--   * a repeated `<key>` keeps the first entry's place and takes the last
--     value, as `plutil` does;
--   * a node's span is its whole element, `<` through `>`; an entry's
--     runs from its `<key>` through its value element.
--
-- The compiled parser keeps no comments (its editor works on the `<!-- -->`
-- pairs in the source), so neither does this one. The compiled format
-- declares three fragment renderers — how a value spells as a typed
-- element, an entry as `<key>k</key>` over the value, and a renamed key as
-- its whole `<key>` element — and they are here too.
-- Spans are byte offsets, 0-based, `[start, end)`.
--
-- The XML shape — tags, text, CDATA, what is skipped, and how each is
-- refused — is `fig.xml`, the twin of fig's shared XML tokenizer; what is
-- here is what makes a plist a plist.

local G = require("fig.grammar")
local X = require("fig.xml").with({
  unexpected = "unexpected content here; expected plist markup",
  no_attributes = "an attribute is not allowed on a plist element",
  unknown_element = function(name) return "`<" .. name .. ">` is not a plist element" end,
})

local M = {}

M.name = "lua-plist"
M.caps = { read = true, edit = true, serialize = true }
M.syntax = {
  comments = {
    style = "xml_comment",
    line = { open = "<!--", close = "-->", forbidden = "--" },
    trailing = { open = "<!--", close = "-->", forbidden = "--" },
  },
  -- An entry is a pair of sibling elements, not a `key<sep>value` line, and
  -- a value is always a typed element: no separator, no bare `{}`.
  flow_containers = false,
  closed_containers = { map_open = "<dict>", map_close = "</dict>", seq_open = "<array>", seq_close = "</array>" },
  seq_item_marker = "",
}
M.dialects = {
  { name = "lua-plist", extensions = { "plist" }, splice = "raw", empty_doc_seed = "<dict>\n</dict>\n" },
}
M.samples = {
  '<plist version="1.0"><dict><key>a</key><string>b</string><key>n</key><integer>1</integer><key>l</key><array><true/><false/></array></dict></plist>\n',
}
M.renderers = { "value", "entry", "key" }

local UNEXPECTED = X.messages.unexpected

-- ── text ──────────────────────────────────────────────────────────────────

local function lines_of(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

local function trim(s) return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")) end

local function valid_integer(s) return s:match("^[+-]?%d+$") ~= nil end
local function valid_real(s)
  local i = 1
  if s:sub(1, 1) == "+" or s:sub(1, 1) == "-" then i = 2 end
  local _, e = s:find("^%d+", i)
  if not e then return false end
  i = e + 1
  if s:sub(i, i) == "." then
    _, e = s:find("^%d*", i + 1)
    i = e + 1
  end
  local ex = s:sub(i, i)
  if ex == "e" or ex == "E" then
    i = i + 1
    if s:sub(i, i) == "+" or s:sub(i, i) == "-" then i = i + 1 end
    _, e = s:find("^%d+", i)
    if not e then return false end
    i = e + 1
  end
  return i == #s + 1
end
local function valid_base64(s)
  local body, pad = s:match("^([A-Za-z0-9+/]*)(=*)$")
  return body ~= nil and #pad <= 2
end
local function valid_date(s) return s ~= "" and s:match("^[%d%-:%.TZ+]+$") ~= nil end

-- ── the grammar ───────────────────────────────────────────────────────────
-- Every value is an element, dispatched on its name; a container's body is
-- a `G.map` or `G.sequence` closed by its close tag, so the tree, the spans
-- and the duplicate policy are the grammar's.

local value

-- A scalar element: its span is the whole element.
local function scalar(kind, sc, tag, text, extra)
  return fig.scalar(kind, { tag[1], sc.pos }, text, extra)
end

-- `<true/>`, `<true></true>`, `<true> </true>`: nothing but whitespace and
-- ignorable markup inside.
local function no_content(sc, tag)
  if tag.empty then return end
  local message = "`<" .. tag.name .. ">` takes no content"
  X.skip(sc, message)
  if sc:eof() then sc:fail(UNEXPECTED) end
  if not sc:starts("</") then sc:fail(message) end
  X.close(tag.name)(sc)
end

local dict_body = G.map({
  entry = G.entry({
    key = X.text_element("key", { wrong_name = "expected `<key>` here; a dict is `<key>`/value pairs" }),
    between = X.trivia,
    value = function(sc, ctx) return value(sc, ctx) end,
    missing_value = "this `<key>` has no value after it",
  }),
  trivia = X.trivia,
  close = X.close("dict"),
  duplicates = "last_value",
  expected = UNEXPECTED,
  unclosed = UNEXPECTED,
})

local array_body = G.sequence({
  item = function(sc, ctx) return value(sc, ctx) end,
  trivia = X.trivia,
  close = X.close("array"),
  expected = UNEXPECTED,
  unclosed = UNEXPECTED,
})

local elements = {
  dict = function(sc, ctx, tag)
    if tag.empty then return fig.mapping({ tag[1], tag[2] }) end
    local m = dict_body(sc, ctx)
    m.span[1] = tag[1]
    return m
  end,
  array = function(sc, ctx, tag)
    if tag.empty then return fig.sequence({ tag[1], tag[2] }) end
    local q = array_body(sc, ctx)
    q.span[1] = tag[1]
    return q
  end,
  string = function(sc, _ctx, tag)
    return scalar("string", sc, tag, X.content(sc, tag))
  end,
  integer = function(sc, _ctx, tag)
    local raw = trim(X.content(sc, tag))
    if not valid_integer(raw) then sc:fail("`" .. raw .. "` is not an integer", tag[1]) end
    return scalar("int", sc, tag, raw)
  end,
  real = function(sc, _ctx, tag)
    local raw = trim(X.content(sc, tag))
    if not valid_real(raw) then sc:fail("`" .. raw .. "` is not a real", tag[1]) end
    return scalar("float", sc, tag, raw)
  end,
  ["true"] = function(sc, _ctx, tag)
    no_content(sc, tag)
    return scalar("bool", sc, tag, "true")
  end,
  ["false"] = function(sc, _ctx, tag)
    no_content(sc, tag)
    return scalar("bool", sc, tag, "false")
  end,
  date = function(sc, _ctx, tag)
    local t = trim(X.content(sc, tag))
    if not valid_date(t) then sc:fail("`" .. t .. "` is not an ISO 8601 date", tag[1]) end
    return scalar("string", sc, tag, t, { ext_kind = "plist_date" })
  end,
  data = function(sc, _ctx, tag)
    local t = X.content(sc, tag):gsub("[ \t\r\n]", "")
    if not valid_base64(t) then sc:fail("`<data>` holds something other than base64", tag[1]) end
    return scalar("string", sc, tag, t, { ext_kind = "plist_data" })
  end,
}

value = X.element(elements)

-- The document's object: inside a `<plist>` wrapper, which alone may carry
-- an attribute, `version`; or bare.
local root_tag = X.tag({ attributes = function(name) return name == "plist" end })

local function root(sc, ctx)
  local tag = root_tag(sc)
  if tag == nil then return nil end
  if tag.name ~= "plist" then
    local h = elements[tag.name]
    if not h then sc:fail("`<" .. tag.name .. ">` is not a plist element", tag[1]) end
    return h(sc, ctx, tag)
  end
  for _, a in ipairs(tag.attrs) do
    if a.name ~= "version" then sc:fail("`<plist>` takes only a `version` attribute", a.s) end
  end
  if tag.empty then sc:fail("`<plist/>` holds no object", tag[1]) end
  X.trivia(sc)
  if sc:starts("</") then sc:fail("`<plist>` holds no object") end
  local inner = value(sc, ctx)
  if inner == nil then sc:fail(UNEXPECTED) end
  X.trivia(sc)
  if sc:byte() == 60 and not sc:starts("</") then sc:fail("a plist holds one object; a second one starts here") end
  if not sc:starts("</") then sc:fail(UNEXPECTED) end
  X.close("plist")(sc)
  return inner
end

M.parse = G.document({
  root = root,
  trivia = X.trivia,
  missing = "no plist object; expected `<plist>` or a `<dict>`",
  trailing = function(sc)
    if sc:byte() == 60 then return "a plist holds one object; a second one starts here" end
    return UNEXPECTED
  end,
})

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: the XML declaration, the DOCTYPE, a
-- `<plist version="1.0">` wrapper, and one element per line indented by
-- `options.indent` per depth; `<dict/>` and `<array/>` when empty. Splice
-- text (`options.splice`) is the root as its bare element, with no header
-- and no wrapper.

local function text_element(tag, text)
  return "<" .. tag .. ">" .. X.escape(text) .. "</" .. tag .. ">"
end

local HEADER = '<?xml version="1.0" encoding="UTF-8"?>\n'
  .. '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  .. '<plist version="1.0">'

local function write_value(w, row, depth)
  local k = row.kind
  if k == "null" then error("a plist has no null; a null value cannot be written", 0) end
  if k == "alias" then error("an alias must be resolved before it is written as a plist", 0) end
  if k == "bool" then
    w:put(row.text == "true" and "<true/>" or "<false/>")
  elseif k == "int" then
    w:put("<integer>", row.text or "", "</integer>")
  elseif k == "float" then
    w:put("<real>", row.text or "", "</real>")
  elseif k == "string" then
    local tag = "string"
    if row.ext_kind == "plist_date" then tag = "date" elseif row.ext_kind == "plist_data" then tag = "data" end
    w:put(text_element(tag, row.text or ""))
  elseif k == "sequence" then
    if #row.items == 0 then return w:put("<array/>") end
    w:put("<array>"):nl()
    for _, item in ipairs(row.items) do
      w:indent(depth)
      write_value(w, item, depth + 1)
      w:nl()
    end
    w:indent(depth - 1):put("</array>")
  elseif k == "mapping" then
    if #row.items == 0 then return w:put("<dict/>") end
    w:put("<dict>"):nl()
    for _, kv in ipairs(row.items) do
      if kv.key.kind ~= "string" then error("a plist dict key must be a string", 0) end
      w:line(depth, text_element("key", kv.key.text or ""))
      w:indent(depth)
      write_value(w, kv.value, depth + 1)
      w:nl()
    end
    w:indent(depth - 1):put("</dict>")
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function M.print(_dialect, t, options)
  local root_row = t.byid(0)
  local w = fig.writer(options)
  if (options and options.splice) or fig.is_scalar(root_row.kind) then
    -- Splice text, or a scalar fragment: the bare element with no
    -- declaration, DOCTYPE or `<plist>` wrapper, a container's lines at the
    -- top level — the compiled `printSplice`. What the editor splices, and
    -- what `render_value` takes as an element already spelled.
    write_value(w, root_row, 1)
    return w:string()
  end
  w:put(HEADER):nl()
  write_value(w, root_row, 1)
  w:nl():put("</plist>\n")
  return w:string()
end

-- ── the renderers ─────────────────────────────────────────────────────────
-- A value the CLI hands the editor is bare text, and fig has already said
-- what its own literal rules make of it — `args.literal`: `true`/`false`, a
-- number (decimal with `_` separators and no leading zero, or `0x`/`0o`/
-- `0b`), a datetime shape, or a string — so this only spells the typed
-- element for the kind it is told. Text that already starts with `<` is
-- spliced as written: how `<data>` or a nested `<dict>` is given, or a
-- type forced.

local ELEMENT = {
  int = "integer",
  float = "real",
  datetime = "date",
}

local function render_value(value_text, literal)
  local t = trim(value_text)
  if t:sub(1, 1) == "<" then return t end
  if literal == "null" then error("a plist has no null; a null value cannot be written", 0) end
  if literal == "bool" then return t == "true" and "<true/>" or "<false/>" end
  local tag = ELEMENT[literal]
  if tag then return "<" .. tag .. ">" .. t .. "</" .. tag .. ">" end
  return text_element("string", t)
end

-- An entry: `<key>k</key>`, then the value at the same indent. A value that
-- spans lines — a `<dict>` or `<array>` spliced as the printer spells it,
-- its lines at the top level — has every further non-empty line moved
-- under `indent` too, so it lands at the entry's depth.
local function render_entry(indent, key, value)
  local out = { "<key>" .. X.escape(key) .. "</key>\n" .. indent }
  for i, line in ipairs(lines_of(value)) do
    if i > 1 then out[#out + 1] = "\n" .. (line == "" and "" or indent) end
    out[#out + 1] = line
  end
  return table.concat(out)
end

function M.render(which, args)
  if which == "value" then return render_value(args.value, args.literal or "string") end
  if which == "entry" then return render_entry(args.indent, args.key, args.value) end
  -- A renamed key: a key's span is its whole `<key>…</key>` element, so the
  -- new name is spelled and escaped rather than spliced bare over the tags.
  if which == "key" then return "<key>" .. X.escape(args.key) .. "</key>" end
  error("no renderer `" .. which .. "`", 0)
end

return M
