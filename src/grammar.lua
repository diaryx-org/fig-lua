-- `require("fig.grammar")`: a format as a description.
--
-- A *rule* is a function `(sc, ctx) -> result | nil` over a `fig.scanner`
-- and a binding context. `nil` means "not here" — the cursor is where it
-- was, and a `choice` tries the next alternative; a *hard* failure is
-- `fig.fail`, raised through `expect`, `fail` or a scanner, and refuses the
-- input with a message at an offset. The primitives (`lit`, `pat`, `eol`)
-- return spans; the fig-aware rules (`key`, `scalar`, `quoted`, `bare`,
-- `entry`, `map`, `sequence`) return tree nodes, with the spans, the
-- comment binding and the duplicate policy taken care of; `document` turns
-- a root rule into a `parse` function. `sections`, at the end, is not a
-- rule: it is what a format of header lines — INI, TOML, fig — shares
-- when its parser is written by hand.
--
-- Comments are bound by the context as trivia is skipped: a comment on the
-- same line as the last node completed is that node's trailing comment;
-- any other waits, and becomes the leading comment of the next entry (on
-- its key, by default) or, when a container closes with it still waiting,
-- a dangling comment of that container. That is the policy every format
-- fig compiles in shares; `G.context(sc, opts)` — or `G.document{ comments
-- = ... }` — takes the three refinements some of them add.
local G = {}

-- ── the context ───────────────────────────────────────────────────────────

local Context = {}
Context.__index = Context

local function is_container(n)
  return n.kind == "mapping" or n.kind == "sequence"
end

--- A binding context over `sc`. `opts` refines what trails: `ends_line`
--- (false) — a comment trails only when it is the last thing on its line,
--- so a block comment with more after it on the line waits instead; `one`
--- (false) — a node takes one trailing comment, a second on the same line
--- waiting like any other; `closing_line` (false) — a container that spans
--- lines takes the comment on its closing line as dangling rather than
--- trailing.
function G.context(sc, opts)
  opts = opts or {}
  return setmetatable({
    sc = sc,
    pending = {},
    last = nil,
    ends_line = opts.ends_line == true,
    one = opts.one == true,
    closing_line = opts.closing_line == true,
  }, Context)
end

--- Whether only spaces and tabs lie between `at` and the line's end.
function Context:rest_is_blank(at)
  local src = self.sc.src
  local i = at + 1
  while i <= #src do
    local b = src:byte(i)
    if b ~= 32 and b ~= 9 then return b == 10 or b == 13 end
    i = i + 1
  end
  return true
end

--- A comment `{s, e, text=, style=}` met in trivia.
function Context:comment(c)
  local last = self.last
  if last and self.sc:same_line(last.span[2], c[1]) and (not self.ends_line or self:rest_is_blank(c[2])) then
    if self.closing_line and is_container(last) and not self.sc:same_line(last.span[1], last.span[2]) then
      last:comment("dangling", c.text, c.style)
    else
      last:comment("trailing", c.text, c.style)
    end
    if self.one then self.last = nil end
  else
    self.pending[#self.pending + 1] = c
    self.last = nil
  end
end

--- Give every waiting comment to `node`, in `slot`.
function Context:flush(node, slot)
  for _, c in ipairs(self.pending) do node:comment(slot, c.text, c.style) end
  self.pending = {}
end

-- ── primitives ────────────────────────────────────────────────────────────

--- The span a result covers.
local function span_of(r)
  return r.span or r
end
G.span_of = span_of

--- The literal `s`.
function G.lit(s)
  return function(sc)
    local a, b = sc:lit(s)
    if a then return { a, b } end
  end
end

--- A Lua pattern, anchored at the cursor.
function G.pat(p)
  return function(sc)
    local a, b = sc:match(p)
    if a then return { a, b } end
  end
end

--- The end of the input.
function G.eof(sc)
  if sc:eof() then return { sc.pos, sc.pos } end
end

--- A line ending: `\n` or `\r\n`.
function G.eol(sc)
  local a, b = sc:lit("\n")
  if a then return { a, b } end
  a, b = sc:lit("\r\n")
  if a then return { a, b } end
end

--- Spaces and tabs, possibly none; at least one; all whitespace; at least
--- one whitespace.
G.hs = G.pat("[ \t]*")
G.hs1 = G.pat("[ \t]+")
G.ws = G.pat("[ \t\r\n]*")
G.ws1 = G.pat("[ \t\r\n]+")

-- ── combinators ───────────────────────────────────────────────────────────

--- Each rule in turn; the results as a list with the whole `span`.
function G.seq(rules)
  return function(sc, ctx)
    local s = sc.pos
    local out = {}
    for i, r in ipairs(rules) do
      local v = r(sc, ctx)
      if v == nil then
        sc.pos = s
        return nil
      end
      out[i] = v
    end
    out.span = { s, sc.pos }
    return out
  end
end

--- The first rule that matches.
function G.choice(rules)
  return function(sc, ctx)
    local s = sc.pos
    for _, r in ipairs(rules) do
      local v = r(sc, ctx)
      if v ~= nil then return v end
      sc.pos = s
    end
  end
end

--- `r`, or an empty result marked `absent`.
function G.opt(r)
  return function(sc, ctx)
    local s = sc.pos
    local v = r(sc, ctx)
    if v ~= nil then return v end
    sc.pos = s
    return { s, s, absent = true }
  end
end

--- `r` as many times as it matches and moves; the results as a list.
function G.many(r)
  return function(sc, ctx)
    local s = sc.pos
    local out = {}
    while true do
      local p = sc.pos
      local v = r(sc, ctx)
      if v == nil or sc.pos == p then
        sc.pos = p
        break
      end
      out[#out + 1] = v
    end
    out.span = { s, sc.pos }
    return out
  end
end

--- `r` at least once.
function G.many1(r)
  local many = G.many(r)
  return function(sc, ctx)
    local v = many(sc, ctx)
    if #v == 0 then return nil end
    return v
  end
end

--- Whether `r` matches here, without moving.
function G.ahead(r)
  return function(sc, ctx)
    local s = sc.pos
    local v = r(sc, ctx)
    sc.pos = s
    return v
  end
end

--- Matches, empty, only where `r` does not.
function G.none(r)
  return function(sc, ctx)
    local s = sc.pos
    local v = r(sc, ctx)
    sc.pos = s
    if v == nil then return { s, s } end
  end
end

--- `r`, or refuse the input with `message` at the cursor.
function G.expect(r, message)
  return function(sc, ctx)
    local v = r(sc, ctx)
    if v == nil then sc:fail(message) end
    return v
  end
end

--- Refuse the input with `message` at the cursor. `message` may be a
--- function of the scanner.
function G.fail(message)
  return function(sc)
    if type(message) == "function" then message = message(sc) end
    sc:fail(message)
  end
end

--- Refuse the input with `message` where `r` matches; otherwise empty.
function G.fail_if(r, message)
  return function(sc, ctx)
    local s = sc.pos
    local v = r(sc, ctx)
    sc.pos = s
    if v ~= nil then sc:fail(message) end
    return { s, s }
  end
end

--- `r`, with its result passed through `fn(result, sc, ctx)`.
function G.apply(r, fn)
  return function(sc, ctx)
    local v = r(sc, ctx)
    if v == nil then return nil end
    return fn(v, sc, ctx)
  end
end

-- ── nodes ─────────────────────────────────────────────────────────────────

local function text_of(opts, raw, span, sc)
  if opts and opts.text then return opts.text(raw, span, sc) end
  return raw
end

--- A scalar of `kind` over what `r` matched: its span, and its text — the
--- bytes matched, or `opts.text(raw, span, sc)` of them. `kind` may be a
--- function of the raw text. `opts.ext_kind` marks an extended scalar.
function G.scalar(kind, r, opts)
  return function(sc, ctx)
    local v = r(sc, ctx)
    if v == nil then return nil end
    local span = span_of(v)
    span = { span[1], span[2] }
    local raw = sc:slice(span[1], span[2])
    local k = type(kind) == "function" and kind(raw) or kind
    return fig.scalar(k, span, text_of(opts, raw, span, sc), opts and opts.ext_kind and { ext_kind = opts.ext_kind })
  end
end

--- A key: a string scalar over what `r` matched.
function G.key(r, opts)
  return G.scalar("string", r, opts)
end

--- A bare value: to the end of the line, or to where `opts.stop` matches
--- (a rule, or a function of the scanner that answers true), trimmed of
--- spaces and tabs unless `opts.trim` is false. May be empty. `opts.kind`
--- is the scalar kind (a string or a function of the text, "string").
function G.bare(opts)
  opts = opts or {}
  local stop = opts.stop
  local trim = opts.trim ~= false
  local kind = opts.kind or "string"
  return function(sc, ctx)
    local s = sc.pos
    while not sc:eof() do
      local c = sc:byte()
      if c == 10 or c == 13 then break end
      if stop then
        local p = sc.pos
        local hit = stop(sc, ctx)
        sc.pos = p
        if hit then break end
      end
      sc:advance()
    end
    local ts, te = s, sc.pos
    if trim then
      local src = sc.src
      while ts < te and (src:byte(ts + 1) == 32 or src:byte(ts + 1) == 9) do ts = ts + 1 end
      while te > ts and (src:byte(te) == 32 or src:byte(te) == 9) do te = te - 1 end
    end
    if opts.empty == false and ts == te then
      sc.pos = s
      return nil
    end
    local raw = sc:slice(ts, te)
    local span = { ts, te }
    local k = type(kind) == "function" and kind(raw) or kind
    return fig.scalar(k, span, text_of(opts, raw, span, sc), opts.ext_kind and { ext_kind = opts.ext_kind })
  end
end

--- A quoted value: `opts.open` through `opts.close` (the same), the span
--- including both. `opts.escapes` is a table from the character after
--- `opts.escape` (`\`) to what it means; without it, nothing escapes.
--- `\r\n` inside reads as `\n` unless `opts.crlf` is false; a bare `\r`
--- refuses the input with `opts.bare_cr` when that is given. Messages:
--- `unclosed`, `bad_escape`. `opts.after(sc, span)` runs once the closing
--- quote is passed — to check what follows on the line — and may return
--- the offset a bad escape is reported at.
function G.quoted(opts)
  local open = opts.open
  local close = opts.close or open
  local escapes = opts.escapes
  local escape = opts.escape or (escapes and "\\")
  local esc_byte = escape and escape:byte()
  local close_byte = close:byte()
  local crlf = opts.crlf ~= false
  local kind = opts.kind or "string"
  return function(sc)
    local s = sc.pos
    if not sc:lit(open) then return nil end
    local src, n = sc.src, sc.n
    local i = sc.pos
    local unclosed = opts.unclosed or ("unclosed quoted value; expected a matching `" .. close .. "`")
    while true do
      if i >= n then fig.fail(unclosed, i) end
      local c = src:byte(i + 1)
      if c == 13 then
        if src:byte(i + 2) == 10 then
          i = i + 2
        elseif opts.bare_cr then
          fig.fail(opts.bare_cr, i)
        else
          i = i + 1
        end
      elseif esc_byte and c == esc_byte then
        if i + 1 >= n then fig.fail(unclosed, i) end
        i = i + 2
      elseif c == close_byte and src:sub(i + 1, i + #close) == close then
        i = i + #close
        break
      else
        i = i + 1
      end
    end
    sc.pos = i
    local span = { s, i }
    local err_at = i
    if opts.after then err_at = opts.after(sc, span) or i end
    local inner = src:sub(s + #open + 1, i - #close)
    local text
    if not escapes and not crlf then
      text = inner
    else
      local out = {}
      local j, len = 1, #inner
      while j <= len do
        local ch = inner:sub(j, j)
        if crlf and ch == "\r" and inner:sub(j + 1, j + 1) == "\n" then
          out[#out + 1] = "\n"
          j = j + 2
        elseif escapes and ch == escape then
          local nxt = inner:sub(j + 1, j + 1)
          local rep = escapes[nxt]
          if rep == nil then
            fig.fail(opts.bad_escape or ("invalid escape `" .. escape .. nxt .. "` in a quoted value"), err_at)
          end
          out[#out + 1] = rep
          j = j + 2
        else
          out[#out + 1] = ch
          j = j + 1
        end
      end
      text = table.concat(out)
    end
    local k = type(kind) == "function" and kind(text) or kind
    return fig.scalar(k, span, text_of(opts, text, span, sc), opts.ext_kind and { ext_kind = opts.ext_kind })
  end
end

--- A comment: `opts.open` to the end of the line, or to `opts.close`.
--- The text is trimmed unless `opts.trim` is false; `opts.style` is
--- "line" or "block" (by whether there is a `close`). A string is the
--- opener alone. The result is `{s, e, text=, style=}`, which trivia
--- binds.
function G.comment(opts)
  if type(opts) == "string" then opts = { open = opts } end
  local open, close = opts.open, opts.close
  local trim = opts.trim ~= false
  local style = opts.style or (close and "block" or "line")
  return function(sc)
    local s = sc.pos
    if not sc:lit(open) then return nil end
    local body_s, body_e = sc.pos, nil
    if close then
      local at = sc:find(close)
      if not at then fig.fail(opts.unclosed or ("unclosed comment; expected `" .. close .. "`"), s) end
      body_e = at
      sc.pos = at + #close
    else
      local at = sc.src:find("[\r\n]", sc.pos + 1)
      body_e = at and at - 1 or sc.n
      sc.pos = body_e
    end
    local text = sc:slice(body_s, body_e)
    if trim then
      text = close and text:match("^%s*(.-)%s*$") or text:match("^[ \t\r]*(.-)[ \t\r]*$")
    end
    return { s, sc.pos, text = text, style = style }
  end
end

--- What lies between the things that matter: `opts.space` (spaces, tabs
--- and line endings) and `opts.comment` (a `comment` rule, or a `choice`
--- of them), in any order, comments bound to the context as they pass.
--- Always matches.
function G.trivia(opts)
  opts = opts or {}
  local space = opts.space or G.choice({ G.hs1, G.eol })
  local comment = opts.comment
  return function(sc, ctx)
    local s = sc.pos
    while not sc:eof() do
      local p = sc.pos
      local v = space(sc, ctx)
      if v == nil or sc.pos == p then
        sc.pos = p
        if not comment then break end
        local c = comment(sc, ctx)
        if c == nil then break end
        if ctx then ctx:comment(c) end
      end
    end
    return { s, sc.pos }
  end
end

--- A keyvalue: `opts.prefix` (optional by nature), `opts.key`,
--- `opts.between` (`hs`), `opts.sep`, `between` again, `opts.value`. Once
--- the key has matched the rest is expected: a missing separator refuses
--- the input with `opts.missing_sep`, a missing value with
--- `opts.missing_value`. Waiting comments become leading comments of the
--- key (`opts.comments.leading`: "key", "value" or "entry").
function G.entry(opts)
  local prefix, key, sep, value = opts.prefix, opts.key, opts.sep, opts.value
  local between = opts.between or G.hs
  local leading = opts.comments and opts.comments.leading or "key"
  return function(sc, ctx)
    local s = sc.pos
    if prefix and prefix(sc, ctx) == nil then sc.pos = s end
    local k = key(sc, ctx)
    if k == nil then
      sc.pos = s
      return nil
    end
    between(sc, ctx)
    if sep then
      if sep(sc, ctx) == nil then sc:fail(opts.missing_sep or "expected a separator after this key") end
      between(sc, ctx)
    end
    local v
    if value then
      v = value(sc, ctx)
      if v == nil then sc:fail(opts.missing_value or "expected a value here") end
    end
    local e = fig.entry(k, v, v == nil and { k.span[1], sc.pos } or nil)
    if ctx then
      ctx:flush((leading == "key" and k) or (leading == "value" and v) or e, "leading")
    end
    return e
  end
end

local function trailing_target(opts, e)
  local on = opts.comments and opts.comments.trailing or "value"
  return (on == "value" and e.value) or (on == "key" and e.key) or e
end

--- A mapping: `opts.open` (none), then entries by `opts.entry` separated
--- by `opts.trivia` (whitespace), until `opts.close` (none: the end of
--- the input). Where an entry is expected and none matches,
--- `opts.otherwise(sc, ctx)` may refuse the input with its own message;
--- otherwise `opts.expected` is the message. `opts.after` runs after every
--- entry (an entry terminator). `opts.duplicates` is the policy
--- (`fig.mapping`); `opts.whole` makes the span the whole input, for a
--- root. Comments still waiting at the close are the mapping's dangling
--- comments.
function G.map(opts)
  local entry = opts.entry
  local trivia = opts.trivia or G.trivia()
  local open, close = opts.open, opts.close
  return function(sc, ctx)
    local s = sc.pos
    if open and open(sc, ctx) == nil then return nil end
    local m = fig.mapping(nil, { duplicates = opts.duplicates })
    while true do
      trivia(sc, ctx)
      if close then
        local p = sc.pos
        if close(sc, ctx) ~= nil then break end
        sc.pos = p
        if sc:eof() then sc:fail(opts.unclosed or "unclosed mapping; expected its close before the end of the input") end
      elseif sc:eof() then
        break
      end
      local e = entry(sc, ctx)
      if e == nil then
        if opts.otherwise then opts.otherwise(sc, ctx) end
        sc:fail(opts.expected or "expected an entry here")
      end
      m:put(e)
      if ctx then ctx.last = trailing_target(opts, e) end
      if opts.after then opts.after(sc, ctx) end
    end
    m.span = opts.whole and { 0, sc.n } or { s, sc.pos }
    if ctx then
      ctx:flush(m, "dangling")
      ctx.last = m
    end
    return m
  end
end

--- A sequence: as `map`, with `opts.item` for `entry`.
function G.sequence(opts)
  local item = opts.item
  local trivia = opts.trivia or G.trivia()
  local open, close = opts.open, opts.close
  return function(sc, ctx)
    local s = sc.pos
    if open and open(sc, ctx) == nil then return nil end
    local q = fig.sequence(nil)
    while true do
      trivia(sc, ctx)
      if close then
        local p = sc.pos
        if close(sc, ctx) ~= nil then break end
        sc.pos = p
        if sc:eof() then sc:fail(opts.unclosed or "unclosed sequence; expected its close before the end of the input") end
      elseif sc:eof() then
        break
      end
      local v = item(sc, ctx)
      if v == nil then
        if opts.otherwise then opts.otherwise(sc, ctx) end
        sc:fail(opts.expected or "expected an item here")
      end
      q:add(v)
      if ctx then
        ctx:flush(v, "leading")
        ctx.last = v
      end
      if opts.after then opts.after(sc, ctx) end
    end
    q.span = opts.whole and { 0, sc.n } or { s, sc.pos }
    if ctx then
      ctx:flush(q, "dangling")
      ctx.last = q
    end
    return q
  end
end

--- A `parse` function over `opts.root`: `opts.trivia` before and after
--- it, then the end of the input, or `opts.trailing` (a message, or a
--- function of the scanner giving one). `opts.utf8` is the message for
--- input that is not UTF-8; `opts.bom` skips a byte-order mark;
--- `opts.missing` is the message when the root does not match. Comments
--- left waiting are the root's dangling comments.
function G.document(opts)
  local root, trivia = opts.root, opts.trivia
  return function(_dialect, input)
    if opts.utf8 then
      local ok, bad = utf8.len(input)
      if not ok then fig.fail(opts.utf8, bad and bad - 1 or nil) end
    end
    local sc = fig.scanner(input)
    if opts.bom and sc:starts("\239\187\191") then sc.pos = 3 end
    local ctx = G.context(sc, opts.comments)
    if trivia then trivia(sc, ctx) end
    local r = root(sc, ctx)
    if r == nil then sc:fail(opts.missing or "no document here") end
    if trivia then trivia(sc, ctx) end
    if not sc:eof() then
      local message = opts.trailing or "unexpected content after the document"
      if type(message) == "function" then message = message(sc) end
      sc:fail(message)
    end
    ctx:flush(r, "dangling")
    return r
  end
end

-- ── sections ──────────────────────────────────────────────────────────────
-- A section format — INI, TOML, fig — opens a container with a header
-- line and may re-enter it with another, and the wire asks the same of
-- each: a *region* for every line that opened or re-entered the
-- container, the whole physical line, newline included; a *mention* for
-- every place its name is written; and comments placed by where they
-- fell — waiting until the next key claims them as leading, or dangling
-- on the container that was open when its run ended. What a header
-- *means* — which containers it may re-enter, what its dots and brackets
-- say, where the cursor goes — differs in each, and stays in the parser.

--- The whole physical line holding `at`, newline included: what a header
--- line contributes to its container's regions.
function G.line_region(src, at)
  local s = at
  while s > 0 and src:byte(s) ~= 10 do s = s - 1 end
  local e = at
  while e < #src and src:byte(e + 1) ~= 10 do e = e + 1 end
  if e < #src then e = e + 1 end
  return { s, e }
end

local Sections = {}
Sections.__index = Sections

--- A section context over `src`.
function G.sections(src)
  return setmetatable({ src = src, pending = {} }, Sections)
end

function Sections:line_region(at)
  return G.line_region(self.src, at)
end

--- The line holding `at`, as a region of `node`.
function Sections:region(node, at)
  node.regions = node.regions or {}
  node.regions[#node.regions + 1] = self:line_region(at)
end

--- `span`, where the name of `node` is written, as a mention of `kind`
--- ("header" or "entry").
function Sections:mention(node, span, kind)
  node.mentions = node.mentions or {}
  node.mentions[#node.mentions + 1] = { span = span, kind = kind }
end

--- Open a section: `entry`, a keyvalue over the container, goes into
--- `parent`; the line holding its key is the container's first region,
--- and the key its first mention, of `kind`. Returns the container.
function Sections:open(parent, entry, kind)
  parent:put(entry)
  self:region(entry.value, entry.key.span[1])
  self:mention(entry.value, entry.key.span, kind)
  return entry.value
end

--- Re-enter `node` by a header that names it at `span`: another region,
--- another mention, of `kind`.
function Sections:reopen(node, span, kind)
  self:region(node, span[1])
  self:mention(node, span, kind)
end

--- A comment waiting for its key, met on a line at `depth` (0) — a format
--- whose lines have no depth leaves it — of `style` ("line").
function Sections:comment(text, depth, style)
  self.pending[#self.pending + 1] = { text = text, depth = depth or 0, style = style or "line" }
end

--- Take the waiting comments from lines at `depth` (0: every one) or
--- deeper, in order; the shallower ones keep waiting.
function Sections:take(depth)
  depth = depth or 0
  local taken, kept = {}, {}
  for _, c in ipairs(self.pending) do
    if c.depth >= depth then taken[#taken + 1] = c else kept[#kept + 1] = c end
  end
  self.pending = kept
  return taken
end

--- Give the waiting comments at `depth` or deeper to `node`, in `slot`
--- ("leading" for a key, "dangling" for a container).
function Sections:claim(node, slot, depth)
  for _, c in ipairs(self:take(depth)) do node:comment(slot, c.text, c.style) end
end

return G
