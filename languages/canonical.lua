-- fig's canonical form, in Lua: the twin of the compiled `canonical`
-- format, row for row.
--
-- The canonical form is the tree spelled with nothing added — a total,
-- one-spelling encoding of every node kind fig has, the oracle two
-- documents are compared through — so this script touches every row the
-- wire can carry, which neither `dotenv.lua` (flat) nor `plist.lua` (XML)
-- does. The form, and the tree it makes — the contract this script is held
-- to, fixture by fixture, against the compiled `canonical`:
--
--   node   ::= ('&' name | '!' tag)* value
--   value  ::= 'null' | 'true' | 'false'
--            | '"' … '"'                       JSON escapes, `\uXXXX` included
--            | ['~i' | '~f'] number            the lexeme kept verbatim
--            | '@' extkind '"' … '"'           an extended scalar
--            | '[' node (',' node)* [','] ']'
--            | '{' node ':' node (',' …)* [','] '}'   keys are nodes
--            | '*' name                        an alias
--
-- A number's kind is implied by its lexeme (`0x…` is an int; a `.` or an
-- exponent makes a float) unless `~i`/`~f` pins it; the prefix is in the
-- span and not in the text. Repeated keys all stay. Comments are `//` to
-- the end of the line and `/* … */`; where each binds is the grammar
-- module's rule with `one` and `closing_line` set, which is to say:
--
--   * a `//` on the line a container opens is that container's trailing
--     comment (a block comment there leads the first child);
--   * a comment after an element, past its comma, is the element's
--     trailing comment — unless the element is a container that spans
--     lines, in which case it is that container's last dangling one;
--   * comments before the root go to its first child (or dangle on an
--     empty root), and a scalar root takes them as leading; a comment on
--     the root's closing line is the root's trailing, and anything after
--     dangles on the root.
--
-- The compiled form is a parse/print pair with no editor, so `caps.edit`
-- is off and there is no `syntax`. Spans are byte offsets, 0-based,
-- `[start, end)`. The compiled build is opt-in (`zig build
-- -Dcanonical=true`), which is what `fig lang check lua-canonical
-- --against canonical` needs.

local G = require("fig.grammar")

local M = {}

M.name = "lua-canonical"
M.caps = { read = true, serialize = true }
-- The compiled form owns no extension — it is selected by name — so this
-- one is reached with `--lang lua-canonical`; the extension is for the
-- fixtures beside the tests.
M.dialects = { { name = "lua-canonical", extensions = { "canonical" } } }
M.samples = {
  '{\n  "a": [1, ~f2, -0x1F, .5, "s\\n", null, true],\n  &x "k": @local_date "2024-01-01",\n  1: *x,\n  "e": {} // empty\n}\n',
  '// lead\n[ // head\n  !!str "t", // one\n  [\n    "deep"\n  ], // after\n  "last" /* end */\n  // before close\n]\n// eof\n',
  '"a scalar"\n',
}

-- ── lexical ───────────────────────────────────────────────────────────────

local NAME = "[A-Za-z0-9_%-]+"
local EXT_KINDS = {
  offset_datetime = true, local_datetime = true, local_date = true, local_time = true,
  enum_literal = true, char_literal = true, number_special = true,
  plist_date = true, data = true,
}

local line_comment = G.comment("//")
local block_comment = G.comment({ open = "/*", close = "*/", unclosed = "unclosed `/*` comment; expected `*/`" })
local comment = G.choice({ line_comment, block_comment })
-- Whitespace is spaces, tabs and line endings of either kind, as the
-- compiled parser's `skipWs`; a lone `\r` counts.
local trivia = G.trivia({ space = G.ws1, comment = comment })

local function is_container(n)
  return n.kind == "mapping" or n.kind == "sequence"
end

-- The compiled printer's `impliedNumberKind`, so a bare lexeme reparses to
-- the same kind it was printed from.
local function implied_kind(raw)
  local body = raw:match("^[+%-]?(.*)$")
  if body:match("^0[xX]") then return "int" end
  if raw:find("[.eE]") then return "float" end
  return "int"
end

local function looks_like_number(raw)
  local body = raw:match("^[+%-]?(.*)$")
  return body:match("^[%d.]") ~= nil
end

-- ── scalars ───────────────────────────────────────────────────────────────

local SIMPLE_ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- JSON's escapes, `\uXXXX` as one UTF-8 character. The grammar's `quoted`
-- decodes an escape to a fixed string, which `\u` is not, so it only
-- finds the closing quote here and the text is decoded whole.
local function decode(raw, span)
  if not raw:find("\\", 1, true) then return raw end
  local out, i, n = {}, 1, #raw
  while i <= n do
    local c = raw:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      local e = raw:sub(i + 1, i + 1)
      if e == "u" then
        local hex = raw:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then
          fig.fail("invalid `\\u` escape in a string; expected four hex digits", span[1])
        end
        local cp = tonumber(hex, 16)
        if fig.is_surrogate(cp) then
          fig.fail("invalid `\\u` escape in a string; a surrogate is not a character", span[1])
        end
        out[#out + 1] = utf8.char(cp)
        i = i + 6
      elseif SIMPLE_ESCAPES[e] then
        out[#out + 1] = SIMPLE_ESCAPES[e]
        i = i + 2
      else
        fig.fail("invalid escape `\\" .. e .. "` in a string", span[1])
      end
    end
  end
  return table.concat(out)
end

local string_value = G.quoted({
  open = '"',
  escape = "\\",
  crlf = false,
  text = decode,
  unclosed = "unclosed string; expected a closing `\"`",
})

-- `null`, `true`, `false`: a word of name characters that is one of them.
local function bareword(sc)
  local s = sc.pos
  local c = sc:byte()
  if not (c and (c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122))) then return nil end
  local _, e = sc:match(NAME)
  local word = sc:slice(s, e)
  if word == "null" then return fig.scalar("null", { s, e }, nil) end
  if word == "true" or word == "false" then return fig.scalar("bool", { s, e }, word) end
  sc:fail("`" .. word .. "` is not a value; expected `null`, `true` or `false`", s)
end

-- A number: an optional `~i`/`~f`, then the lexeme, drawn from the
-- characters the compiled lexer takes and beginning like a number.
local function number(sc)
  local s = sc.pos
  local c = sc:byte()
  if not (c and ((c >= 48 and c <= 57) or c == 43 or c == 45 or c == 46 or c == 126)) then return nil end
  local pinned
  if c == 126 then
    sc:advance()
    local k = sc:byte()
    if k == 102 then pinned = "float" elseif k == 105 then pinned = "int" else sc:fail("expected `i` or `f` after `~`") end
    sc:advance()
  end
  local rs, re = sc:match("[0-9a-fA-FxXoObB._+%-]+")
  if not rs then sc:fail("expected a number here") end
  local raw = sc:slice(rs, re)
  if not looks_like_number(raw) then sc:fail("`" .. raw .. "` is not a number", rs) end
  return fig.scalar(pinned or implied_kind(raw), { s, re }, raw)
end

-- `@kind "text"`: a string scalar of an extended kind, spanning both.
local function extended(sc)
  local s = sc.pos
  if not sc:lit("@") then return nil end
  local ks, ke = sc:match("[a-z_]*")
  local kind = sc:slice(ks, ke)
  if not EXT_KINDS[kind] then sc:fail("`@" .. kind .. "` is not an extended scalar kind", s) end
  G.ws(sc)
  local v = string_value(sc)
  if v == nil then sc:fail("expected a `\"` string after `@" .. kind .. "`") end
  return fig.scalar("string", { s, v.span[2] }, v.text, { ext_kind = kind })
end

local function alias(sc)
  local s = sc.pos
  if not sc:lit("*") then return nil end
  local ns, ne = sc:match(NAME)
  if not ns then sc:fail("expected a name after `*`") end
  return fig.scalar("alias", { s, ne }, sc:slice(ns, ne))
end

-- ── nodes ─────────────────────────────────────────────────────────────────
-- `node` is prefixes then a value; the containers are `G.map` and
-- `G.sequence`, with the openers, the separators and the key and value
-- rules doing what the compiled binding does that the module's defaults
-- do not.

local node

-- A container's opener: the delimiter, and a `//` comment on its line,
-- which the container takes as its trailing comment once it exists —
-- held on the context until then, a stack because containers nest. The
-- context's `last` is cleared so nothing before the opener catches a
-- comment inside it.
local function opener(delim)
  return function(sc, ctx)
    local s = sc.pos
    if not sc:lit(delim) then return nil end
    local p = sc.pos
    G.hs(sc)
    local c = line_comment(sc)
    if not c then sc.pos = p end
    ctx.heads[#ctx.heads + 1] = c or false
    ctx.last = nil
    return { s, sc.pos }
  end
end

-- After an element: a comma, or the close ahead (comments allowed
-- between, bound later by the container's own trivia); anything else is
-- an element with no comma before it.
local function separator(close)
  local close_ahead = G.ahead(function(sc)
    trivia(sc, nil)
    return close(sc)
  end)
  return G.seq({
    G.hs,
    G.choice({ G.lit(","), close_ahead, G.fail("expected `,` between elements") }),
  })
end

local function container(rule)
  return function(sc, ctx)
    local n = rule(sc, ctx)
    if n == nil then return nil end
    local head = table.remove(ctx.heads)
    if head then n:comment("trailing", head.text, head.style) end
    return n
  end
end

-- A key is any node; the comments waiting when it is done are its own,
-- so that those between the `:` and the value are the value's.
local function key(sc, ctx)
  local k = node(sc, ctx)
  if k ~= nil then ctx:flush(k, "leading") end
  return k
end

local function value(sc, ctx)
  ctx.last = nil
  trivia(sc, ctx)
  local v = node(sc, ctx)
  if v ~= nil then ctx:flush(v, "leading") end
  return v
end

local mapping = container(G.map({
  open = opener("{"),
  close = G.lit("}"),
  trivia = trivia,
  entry = G.entry({
    key = key,
    between = G.ws,
    sep = G.lit(":"),
    value = value,
    missing_sep = "expected `:` after this key",
    missing_value = "expected a value after `:`",
  }),
  after = separator(G.lit("}")),
  duplicates = "keep",
  expected = "expected a `key: value` entry or `}` here",
  unclosed = "unclosed mapping; expected `}` before the end of the input",
}))

local sequence = container(G.sequence({
  open = opener("["),
  close = G.lit("]"),
  trivia = trivia,
  item = function(sc, ctx) return node(sc, ctx) end,
  after = separator(G.lit("]")),
  expected = "expected a value or `]` here",
  unclosed = "unclosed sequence; expected `]` before the end of the input",
}))

local plain_value = G.choice({ mapping, sequence, string_value, extended, alias, number, bareword })

-- Prefixes, then the value they mark: `&name` at most once, `!tag` at
-- most once, in either order, whitespace between. The node's span is the
-- value's; the prefixes are fields on it.
node = function(sc, ctx)
  local anchor, tag
  while true do
    local c = sc:byte()
    if c == 38 then
      if anchor then sc:fail("a node takes one anchor") end
      sc:advance()
      local ns, ne = sc:match(NAME)
      if not ns then sc:fail("expected a name after `&`") end
      anchor = sc:slice(ns, ne)
      G.ws(sc)
    elseif c == 33 then
      if tag then sc:fail("a node takes one tag") end
      local ts, te = sc:match("[^ \t\r\n,:{}%[%]\"]+")
      tag = sc:slice(ts, te)
      G.ws(sc)
    else
      break
    end
  end
  local v = plain_value(sc, ctx)
  if v == nil then
    if anchor or tag then sc:fail("expected a value after the prefix") end
    return nil
  end
  v.anchor = anchor
  v.tag = tag
  return v
end

-- The document, by hand rather than `G.document`: the root's comments
-- bind by rules of their own (see the top), and the binding policy is the
-- context's, so this is where a script states one.
function M.parse(_dialect, input)
  local sc = fig.scanner(input)
  -- The binding rule is the context's own, refined twice: `closing_line` —
  -- a container that spans lines takes the comment on its closing line as
  -- dangling, not trailing; `one` — a node takes one trailing comment, a
  -- second on the same line waiting like any other.
  local ctx = G.context(sc, { one = true, closing_line = true })
  ctx.heads = {}
  trivia(sc, ctx)
  local root = node(sc, ctx)
  if root == nil then
    if sc:eof() then sc:fail("no document here; expected a value") end
    sc:fail("expected a value here")
  end
  -- A container root gave what was waiting to its first child already; a
  -- scalar root takes it as leading.
  ctx:flush(root, "leading")
  G.hs(sc)
  local c = comment(sc)
  if c then root:comment("trailing", c.text, c.style) end
  ctx.last = nil
  trivia(sc, ctx)
  if not sc:eof() then sc:fail("unexpected content after the document") end
  ctx:flush(root, "dangling")
  return root
end

-- ── the printer ───────────────────────────────────────────────────────────
-- The compiled printer's layout, which is the only one: two spaces per
-- level, one element per line, an empty container inline, a container's
-- trailing comment beside its opener, its dangling comments before its
-- close. `options` is not consulted — one document has one spelling — so
-- `pretty` off changes nothing.

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == "\\" then return "\\\\" end
    if ch == "\b" then return "\\b" end
    if ch == "\f" then return "\\f" end
    if ch == "\n" then return "\\n" end
    if ch == "\r" then return "\\r" end
    if ch == "\t" then return "\\t" end
    return string.format("\\u%04x", ch:byte())
  end) .. '"'
end

local function write_comment(w, c)
  if c.style == "block" then
    w:put("/*", c.text ~= "" and (" " .. c.text .. " ") or "", "*/")
  else
    w:put("//", c.text ~= "" and (" " .. c.text) or "")
  end
end

-- A container with no items and no dangling comments prints inline, and
-- its trailing comment is written by whoever writes the line.
local function is_inline(row)
  return is_container(row) and #row.items == 0 and #row.dangling == 0
end

local function indent(w, depth) w:put(string.rep("  ", depth)) end

-- The rows a child's comments hang on: an entry's leading on its key, its
-- trailing after its value.
local function anchors_of(row)
  if row.kind == "keyvalue" then return row.key, row.value end
  return row, row
end

local write_node

local function write_container(w, row, open, close, depth)
  if is_inline(row) then return w:put(open, close) end
  w:put(open)
  if row.trailing[1] then
    w:put(" ")
    write_comment(w, row.trailing[1])
  end
  w:put("\n")
  for i, child in ipairs(row.items) do
    local lead, trail = anchors_of(child)
    for _, c in ipairs(lead.leading) do
      indent(w, depth + 1)
      write_comment(w, c)
      w:put("\n")
    end
    indent(w, depth + 1)
    write_node(w, child, depth + 1)
    if i < #row.items then w:put(",") end
    if (not is_container(trail) or is_inline(trail)) and trail.trailing[1] then
      w:put(" ")
      write_comment(w, trail.trailing[1])
    end
    w:put("\n")
  end
  for _, c in ipairs(row.dangling) do
    indent(w, depth + 1)
    write_comment(w, c)
    w:put("\n")
  end
  indent(w, depth)
  w:put(close)
end

write_node = function(w, row, depth)
  if row.anchor then w:put("&", row.anchor, " ") end
  if row.tag then w:put(row.tag, " ") end
  local k = row.kind
  if k == "null" then
    w:put("null")
  elseif k == "bool" then
    w:put(row.text)
  elseif k == "int" or k == "float" then
    if implied_kind(row.text) ~= k then w:put(k == "float" and "~f" or "~i") end
    w:put(row.text)
  elseif k == "string" then
    if row.ext_kind then w:put("@", row.ext_kind, " ") end
    w:put(quote(row.text or ""))
  elseif k == "alias" then
    w:put("*", row.text)
  elseif k == "sequence" then
    write_container(w, row, "[", "]", depth)
  elseif k == "mapping" then
    write_container(w, row, "{", "}", depth)
  elseif k == "keyvalue" then
    write_node(w, row.key, depth)
    w:put(": ")
    -- A comment between the `:` and the value is the value's leading
    -- comment, and stays between them: a block one on the line, a line
    -- one ending it, the value on the next. (The compiled printer writes
    -- an entry's leading comments from its key alone and loses these.)
    for _, c in ipairs(row.value.leading) do
      write_comment(w, c)
      if c.style == "block" then
        w:put(" ")
      else
        w:put("\n")
        indent(w, depth + 1)
      end
    end
    write_node(w, row.value, depth)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

function M.print(_dialect, t, _options)
  local root = t.byid(0)
  local w = fig.writer()
  for _, c in ipairs(root.leading) do
    write_comment(w, c)
    w:put("\n")
  end
  write_node(w, root, 0)
  if (not is_container(root) or is_inline(root)) and root.trailing[1] then
    w:put(" ")
    write_comment(w, root.trailing[1])
  end
  if not is_container(root) then
    for _, c in ipairs(root.dangling) do
      w:put("\n")
      write_comment(w, c)
    end
  end
  w:put("\n")
  return w:string()
end

return M
