-- Apple property lists (the XML form), in Lua: the twin of fig's compiled
-- `plist` format, row for row.
--
-- `fig lang check lua-plist --against plist <files…>` holds this script to
-- the compiled parser's node table, and it is written against `fig lang
-- table -i plist`. What the compiled format accepts is stated in fig's
-- `src/languages/plist/parser.zig`, and this follows it:
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
-- declares two fragment renderers — how a value spells as a typed element,
-- and an entry as `<key>k</key>` over the value — and they are here too.
-- Spans are byte offsets, 0-based, `[start, end)`.

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
M.renderers = { "value", "entry" }

local function fail(message, at)
  error({ message = message, at = at }, 0)
end

-- ── the XML tokenizer ─────────────────────────────────────────────────────
-- Purely lexical, as fig's shared XML tokenizer is: `lt`, `lt_slash`, `gt`,
-- `slash_gt`, `eq`, `name`, `attr_value`, `char_data`, `cdata`, `eof`, with
-- 0-based `[s, e)` spans. Comments, PIs and the DOCTYPE are skipped here.

local function is_name_start(c)
  return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 58 or c >= 128
end
local function is_name_char(c)
  return is_name_start(c) or (c >= 48 and c <= 57) or c == 45 or c == 46
end
local function is_space(c)
  return c == 32 or c == 9 or c == 13 or c == 10
end

local function tokenize(src)
  local n = #src
  local byte = function(i) return string.byte(src, i + 1) end
  local starts = function(i, s) return src:sub(i + 1, i + #s) == s end
  local find = function(s, i) return src:find(s, i + 1, true) end
  local tokens = {}
  local function emit(kind, s, e) tokens[#tokens + 1] = { kind = kind, s = s, e = e } end
  local i = 0
  local in_tag = false

  local function content()
    if byte(i) ~= 60 then
      local s = i
      while i < n and byte(i) ~= 60 do i = i + 1 end
      emit("char_data", s, i)
      return
    end
    local s = i
    if starts(i, "<!--") then
      local at = find("-->", i + 4)
      if not at then fail("unclosed comment; expected `-->`", i) end
      i = at - 1 + 3
    elseif starts(i, "<![CDATA[") then
      local at = find("]]>", i + 9)
      if not at then fail("unclosed CDATA section; expected `]]>`", i) end
      emit("cdata", i + 9, at - 1)
      i = at - 1 + 3
    elseif starts(i, "<!DOCTYPE") then
      i = i + 9
      while i < n do
        local c = byte(i)
        if c == 91 then fail("a DOCTYPE with an internal subset is not supported", i) end
        if c == 62 then i = i + 1; return end
        i = i + 1
      end
      fail("unterminated DOCTYPE", i)
    elseif starts(i, "<!") then
      fail("markup is not well-formed here", i)
    elseif starts(i, "<?") then
      local at = find("?>", i + 2)
      if not at then fail("unclosed processing instruction; expected `?>`", i) end
      i = at - 1 + 2
    elseif starts(i, "</") then
      i = i + 2
      emit("lt_slash", s, i)
      in_tag = true
    elseif i + 1 < n and is_name_start(byte(i + 1)) then
      i = i + 1
      emit("lt", s, i)
      in_tag = true
    else
      fail("markup is not well-formed here", i)
    end
  end

  local function tag()
    while i < n and is_space(byte(i)) do i = i + 1 end
    if i >= n then fail("unclosed tag; expected `>`", i) end
    local c = byte(i)
    if c == 62 then
      emit("gt", i, i + 1); i = i + 1; in_tag = false
    elseif c == 47 then
      if not starts(i, "/>") then fail("unclosed tag; expected `/>`", i) end
      emit("slash_gt", i, i + 2); i = i + 2; in_tag = false
    elseif c == 61 then
      emit("eq", i, i + 1); i = i + 1
    elseif c == 34 or c == 39 then
      i = i + 1
      local s = i
      while i < n and byte(i) ~= c do
        if byte(i) == 60 then fail("`<` is not allowed in an attribute value", i) end
        i = i + 1
      end
      if i >= n then fail("unclosed attribute value", i) end
      emit("attr_value", s, i)
      i = i + 1
    elseif is_name_start(c) then
      local s = i
      i = i + 1
      while i < n and is_name_char(byte(i)) do i = i + 1 end
      emit("name", s, i)
    else
      fail("unexpected character inside a tag", i)
    end
  end

  while i < n do
    if in_tag then tag() else content() end
  end
  if in_tag then fail("unclosed tag at end of input", i) end
  emit("eof", n, n)
  return tokens
end

-- ── text content ──────────────────────────────────────────────────────────

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function decode_entities(raw, at)
  if not raw:find("&", 1, true) then return raw end
  local out = {}
  local i = 1
  while i <= #raw do
    local c = raw:sub(i, i)
    if c ~= "&" then
      out[#out + 1] = c
      i = i + 1
    else
      local semi = raw:find(";", i + 1, true)
      if not semi then fail("an entity reference here has no `;`", at + i - 1) end
      local ent = raw:sub(i + 1, semi - 1)
      if ent:sub(1, 1) == "#" then
        local hex = ent:sub(2, 2) == "x" or ent:sub(2, 2) == "X"
        local digits = hex and ent:sub(3) or ent:sub(2)
        local cp = tonumber(digits, hex and 16 or 10)
        if not cp or digits == "" or cp > 0x10FFFF then fail("`&" .. ent .. ";` is not a character reference", at + i - 1) end
        out[#out + 1] = utf8.char(cp)
      else
        local r = ENTITIES[ent]
        if not r then fail("`&" .. ent .. ";` is not an entity this reader knows", at + i - 1) end
        out[#out + 1] = r
      end
      i = semi + 1
    end
  end
  return table.concat(out)
end

local function trim(s) return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")) end
local function whitespace_only(s) return s:find("[^ \t\r\n]") == nil end

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

-- ── the parser ────────────────────────────────────────────────────────────

local function parse_tokens(src, tokens)
  local pos = 1
  local function cur() return tokens[pos] end
  local function kind() return tokens[pos].kind end
  local function text() local t = tokens[pos]; return src:sub(t.s + 1, t.e) end
  local function advance() pos = pos + 1 end
  local function extent(s) return { s, tokens[pos - 1].e } end
  local function unexpected() fail("unexpected content here; expected plist markup", cur().s) end

  -- Nodes are built as Lua tables first — the tree is walked into rows at
  -- the end, in pre-order, which is where a replaced duplicate drops out.
  local function skip_ws()
    while kind() == "char_data" do
      if not whitespace_only(text()) then fail("text is not allowed here; only markup", cur().s) end
      advance()
    end
    if kind() == "cdata" then fail("text is not allowed here; only markup", cur().s) end
  end

  -- After the name: no attributes; returns true when the tag self-closed.
  local function body_or_empty()
    if kind() == "name" then fail("an attribute is not allowed on a plist element", cur().s) end
    if kind() == "slash_gt" then advance(); return true end
    if kind() ~= "gt" then unexpected() end
    advance()
    return false
  end

  local function close_tag(name)
    advance() -- lt_slash
    if kind() ~= "name" or text() ~= name then fail("expected `</" .. name .. ">` here", cur().s) end
    advance()
    if kind() ~= "gt" then unexpected() end
    advance()
  end

  local function text_content(name)
    if body_or_empty() then return "" end
    local out = {}
    while kind() ~= "lt_slash" do
      local k = kind()
      if k == "char_data" then
        out[#out + 1] = decode_entities(text(), cur().s)
        advance()
      elseif k == "cdata" then
        out[#out + 1] = text()
        advance()
      elseif k == "lt" then
        fail("`<" .. name .. ">` holds text only; an element is not allowed inside it", cur().s)
      else
        unexpected()
      end
    end
    close_tag(name)
    return table.concat(out)
  end

  local parse_value
  local function from_name(name, s)
    if name == "dict" then
      local node = { kind = "mapping", entries = {} }
      if body_or_empty() then node.span = extent(s); return node end
      local by_key = {}
      while true do
        skip_ws()
        if kind() == "lt_slash" then break end
        if kind() ~= "lt" then unexpected() end
        local key_s = cur().s
        advance()
        if kind() ~= "name" or text() ~= "key" then fail("expected `<key>` here; a dict is `<key>`/value pairs", cur().s) end
        advance()
        local key_text = text_content("key")
        local key_span = extent(key_s)
        skip_ws()
        if kind() ~= "lt" then fail("this `<key>` has no value after it", cur().s) end
        local value = parse_value()
        local existing = by_key[key_text]
        if existing then
          existing.value = value
        else
          local entry = { key = { kind = "string", text = key_text, span = key_span }, value = value,
                          span = { key_s, value.span[2] } }
          node.entries[#node.entries + 1] = entry
          by_key[key_text] = entry
        end
      end
      close_tag("dict")
      node.span = extent(s)
      return node
    elseif name == "array" then
      local node = { kind = "sequence", items = {} }
      if body_or_empty() then node.span = extent(s); return node end
      while true do
        skip_ws()
        if kind() == "lt_slash" then break end
        if kind() ~= "lt" then unexpected() end
        node.items[#node.items + 1] = parse_value()
      end
      close_tag("array")
      node.span = extent(s)
      return node
    elseif name == "string" then
      local t = text_content("string")
      return { kind = "string", text = t, span = extent(s) }
    elseif name == "integer" or name == "real" then
      local raw = trim(text_content(name))
      if name == "integer" then
        if not valid_integer(raw) then fail("`" .. raw .. "` is not an integer", s) end
        return { kind = "int", text = raw, span = extent(s) }
      end
      if not valid_real(raw) then fail("`" .. raw .. "` is not a real", s) end
      return { kind = "float", text = raw, span = extent(s) }
    elseif name == "true" or name == "false" then
      if not body_or_empty() then
        while kind() ~= "lt_slash" do
          if kind() == "char_data" then
            if not whitespace_only(text()) then fail("`<" .. name .. ">` takes no content", cur().s) end
            advance()
          elseif kind() == "eof" then
            unexpected()
          else
            fail("`<" .. name .. ">` takes no content", cur().s)
          end
        end
        close_tag(name)
      end
      return { kind = "bool", text = name, span = extent(s) }
    elseif name == "date" then
      local t = trim(text_content("date"))
      if not valid_date(t) then fail("`" .. t .. "` is not an ISO 8601 date", s) end
      return { kind = "string", ext_kind = "plist_date", text = t, span = extent(s) }
    elseif name == "data" then
      local t = text_content("data"):gsub("[ \t\r\n]", "")
      if not valid_base64(t) then fail("`<data>` holds something other than base64", s) end
      return { kind = "string", ext_kind = "plist_data", text = t, span = extent(s) }
    end
    fail("`<" .. name .. ">` is not a plist element", s)
  end

  parse_value = function()
    local s = cur().s
    advance() -- lt
    if kind() ~= "name" then unexpected() end
    local name = text()
    advance()
    return from_name(name, s)
  end

  local function document_root()
    local s = cur().s
    advance()
    if kind() ~= "name" then unexpected() end
    local name = text()
    advance()
    if name ~= "plist" then return from_name(name, s) end
    while kind() == "name" do
      if text() ~= "version" then fail("`<plist>` takes only a `version` attribute", cur().s) end
      advance()
      if kind() ~= "eq" then unexpected() end
      advance()
      if kind() ~= "attr_value" then unexpected() end
      advance()
    end
    if kind() == "slash_gt" then advance(); fail("`<plist/>` holds no object", s) end
    if kind() ~= "gt" then unexpected() end
    advance()
    skip_ws()
    if kind() == "lt_slash" then fail("`<plist>` holds no object", cur().s) end
    if kind() ~= "lt" then unexpected() end
    local inner = parse_value()
    skip_ws()
    if kind() == "lt" then fail("a plist holds one object; a second one starts here", cur().s) end
    if kind() ~= "lt_slash" then unexpected() end
    close_tag("plist")
    return inner
  end

  skip_ws()
  if kind() ~= "lt" then fail("no plist object; expected `<plist>` or a `<dict>`", cur().s) end
  local root = document_root()
  skip_ws()
  local k = kind()
  if k == "lt" or k == "lt_slash" then fail("a plist holds one object; a second one starts here", cur().s) end
  if k ~= "eof" then unexpected() end

  local t = fig.table()
  local function emit(node, parent)
    local extra = { text = node.text, ext_kind = node.ext_kind }
    local id = t:row(node.kind, parent, node.span, extra)
    if node.kind == "mapping" then
      for _, e in ipairs(node.entries) do
        local kv = t:row("keyvalue", id, e.span)
        t:row("string", kv, e.key.span, { text = e.key.text })
        emit(e.value, kv)
      end
    elseif node.kind == "sequence" then
      for _, item in ipairs(node.items) do emit(item, id) end
    end
    return id
  end
  emit(root, nil)
  return t
end

function M.parse(_dialect, input)
  local ok, result = pcall(function() return parse_tokens(input, tokenize(input)) end)
  if ok then return result end
  if type(result) == "table" and result.message then
    return fig.fail(result.message, result.at)
  end
  error(result, 0)
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout: the XML declaration, the DOCTYPE, a
-- `<plist version="1.0">` wrapper, and one element per line indented by
-- `options.indent` per depth; `<dict/>` and `<array/>` when empty.

local function escape(s)
  return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function text_element(tag, text)
  return "<" .. tag .. ">" .. escape(text) .. "</" .. tag .. ">"
end

local HEADER = '<?xml version="1.0" encoding="UTF-8"?>\n'
  .. '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  .. '<plist version="1.0">'

local function printer(t, options)
  local pretty = options.pretty ~= false
  local unit = string.rep(" ", options.indent or 2)
  local out = {}
  local function nl() if pretty then out[#out + 1] = "\n" end end
  local function indent(depth) if pretty then out[#out + 1] = string.rep(unit, depth) end end
  local value
  value = function(row, depth)
    local k = row.kind
    if k == "null" then error("a plist has no null; a null value cannot be written", 0) end
    if k == "alias" then error("an alias must be resolved before it is written as a plist", 0) end
    if k == "bool" then out[#out + 1] = row.text == "true" and "<true/>" or "<false/>"
    elseif k == "int" then out[#out + 1] = "<integer>" .. (row.text or "") .. "</integer>"
    elseif k == "float" then out[#out + 1] = "<real>" .. (row.text or "") .. "</real>"
    elseif k == "string" then
      local tag = "string"
      if row.ext_kind == "plist_date" then tag = "date" elseif row.ext_kind == "plist_data" then tag = "data" end
      out[#out + 1] = text_element(tag, row.text or "")
    elseif k == "sequence" then
      if #row.children == 0 then out[#out + 1] = "<array/>"; return end
      out[#out + 1] = "<array>"
      nl()
      for _, id in ipairs(row.children) do
        indent(depth)
        value(t.byid(id), depth + 1)
        nl()
      end
      indent(depth - 1)
      out[#out + 1] = "</array>"
    elseif k == "mapping" then
      if #row.children == 0 then out[#out + 1] = "<dict/>"; return end
      out[#out + 1] = "<dict>"
      nl()
      for _, id in ipairs(row.children) do
        local kv = t.byid(id)
        local key = t.byid(kv.children[1])
        if key.kind ~= "string" then error("a plist dict key must be a string", 0) end
        indent(depth)
        out[#out + 1] = text_element("key", key.text or "")
        nl()
        indent(depth)
        value(t.byid(kv.children[2]), depth + 1)
        nl()
      end
      indent(depth - 1)
      out[#out + 1] = "</dict>"
    else
      error("a " .. k .. " is not a value", 0)
    end
  end
  return out, value, nl
end

function M.print(_dialect, t, options)
  local root = t.byid(0)
  local out, value, nl = printer(t, options)
  if fig.is_scalar(root.kind) then
    -- A fragment: the scalar as its typed element, standing alone.
    value(root, 1)
    return table.concat(out)
  end
  out[#out + 1] = HEADER
  nl()
  value(root, 1)
  nl()
  out[#out + 1] = "</plist>\n"
  return table.concat(out)
end

-- ── the renderers ─────────────────────────────────────────────────────────
-- A value the CLI hands the editor is bare text; it becomes a typed element
-- by the fig dialect's own literal-else-string rules — `true`/`false`, a
-- number (decimal with `_` separators and no leading zero, or `0x`/`0o`/
-- `0b`), a datetime shape — or `<string>`, escaped. Text that already
-- starts with `<` is spliced as written: how `<data>` or a nested
-- `<dict>` is given, or a type forced.

local function digit_run(s, i, class)
  local prev_us = true
  local j = i
  while j <= #s do
    local c = s:sub(j, j)
    if c == "_" then
      if prev_us then return nil end
      prev_us = true
    elseif c:match(class) then
      prev_us = false
    else
      break
    end
    j = j + 1
  end
  if prev_us then return nil end
  return j
end

local function sniff_number(s)
  local i = 1
  local c = s:sub(1, 1)
  if c == "+" or c == "-" then i = 2 end
  if i > #s then return nil end
  local body = s:sub(i)
  local radix = body:sub(1, 2)
  if radix == "0x" or radix == "0o" or radix == "0b" then
    local class = radix == "0x" and "%x" or (radix == "0o" and "[0-7]" or "[01]")
    local j = digit_run(body, 3, class)
    if j and j == #body + 1 then return "integer" end
    return nil
  end
  local j = digit_run(s, i, "%d")
  if not j then return nil end
  if j - i > 1 and s:sub(i, i) == "0" then return nil end
  local float = false
  if s:sub(j, j) == "." then
    float = true
    j = digit_run(s, j + 1, "%d")
    if not j then return nil end
  end
  local e = s:sub(j, j)
  if e == "e" or e == "E" then
    float = true
    j = j + 1
    local sign = s:sub(j, j)
    if sign == "+" or sign == "-" then j = j + 1 end
    j = digit_run(s, j, "%d")
    if not j then return nil end
  end
  if j ~= #s + 1 then return nil end
  return float and "real" or "integer"
end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function valid_date_part(s)
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return false end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 then return false end
  local days = DAYS[m]
  if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then days = 29 end
  return d >= 1 and d <= days
end
local function valid_time_part(s)
  local h, mi, rest = s:match("^(%d%d):(%d%d)(.*)$")
  if not h or tonumber(h) > 23 or tonumber(mi) > 59 then return false end
  if rest == "" then return true end
  local sec, frac = rest:match("^:(%d%d)(.*)$")
  if not sec or tonumber(sec) > 60 then return false end
  if frac == "" then return true end
  return frac:match("^%.%d+$") ~= nil
end
local function is_datetime(s)
  if #s >= 3 and s:sub(3, 3) == ":" then return valid_time_part(s) end
  if #s < 10 or not valid_date_part(s:sub(1, 10)) then return false end
  if #s == 10 then return true end
  local sep = s:sub(11, 11)
  if sep ~= "T" and sep ~= "t" and sep ~= " " then return false end
  local rest = s:sub(12)
  local last = rest:sub(-1)
  if last == "Z" or last == "z" then
    rest = rest:sub(1, -2)
  elseif #rest >= 6 and rest:sub(-6, -6):match("[+-]") and rest:sub(-3, -3) == ":" then
    local oh, om = rest:sub(-5, -4), rest:sub(-2)
    if not (oh:match("^%d%d$") and om:match("^%d%d$")) or tonumber(oh) > 23 or tonumber(om) > 59 then return false end
    rest = rest:sub(1, -7)
  end
  return valid_time_part(rest)
end

local function render_value(value)
  local t = trim(value)
  if t:sub(1, 1) == "<" then return t end
  if t == "null" then error("a plist has no null; a null value cannot be written", 0) end
  if t == "true" then return "<true/>" end
  if t == "false" then return "<false/>" end
  local num = sniff_number(t)
  if num then return "<" .. num .. ">" .. t .. "</" .. num .. ">" end
  if is_datetime(t) then return "<date>" .. t .. "</date>" end
  return text_element("string", t)
end

function M.render(which, args)
  if which == "value" then return render_value(args.value) end
  if which == "entry" then
    return "<key>" .. escape(args.key) .. "</key>\n" .. args.indent .. args.value
  end
  error("no renderer `" .. which .. "`", 0)
end

return M
