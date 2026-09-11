-- `require("fig.xml")`: the XML shape, for an XML-shaped format.
--
-- What fig's shared XML tokenizer is to its compiled `plist` and `xml`
-- formats, this is to a script: purely lexical — tags, attributes,
-- character data, CDATA; comments, processing instructions and a DOCTYPE
-- skipped; entity references decoded — and knowing nothing about which
-- elements mean what. Every function speaks the grammar module's rule
-- shape, `(sc, ctx) -> result | nil`, so a tag is a rule and an element
-- body is a `G.map` or `G.sequence` closed by `X.close(name)`.
--
-- `X.with{ ... }` is the same kit with some of its messages replaced,
-- for a format that words a refusal its own way.
local DEFAULTS = {
  unclosed_comment = "unclosed comment; expected `-->`",
  unclosed_cdata = "unclosed CDATA section; expected `]]>`",
  doctype_subset = "a DOCTYPE with an internal subset is not supported",
  unterminated_doctype = "unterminated DOCTYPE",
  unclosed_pi = "unclosed processing instruction; expected `?>`",
  malformed = "markup is not well-formed here",
  unclosed_tag = "unclosed tag; expected `>`",
  unclosed_empty_tag = "unclosed tag; expected `/>`",
  lt_in_attribute = "`<` is not allowed in an attribute value",
  unclosed_attribute = "unclosed attribute value",
  bad_tag_char = "unexpected character inside a tag",
  text_not_allowed = "text is not allowed here; only markup",
  unexpected = "unexpected content here",
  no_attributes = function(name) return "an attribute is not allowed on `<" .. name .. ">`" end,
  wrong_close = function(name) return "expected `</" .. name .. ">` here" end,
  wrong_name = function(name) return "expected `<" .. name .. ">` here" end,
  no_element = function(name) return "`<" .. name .. ">` holds text only; an element is not allowed inside it" end,
  unknown_element = function(name) return "`<" .. name .. ">` is not an element this reader knows" end,
  entity_no_semicolon = "an entity reference here has no `;`",
  bad_char_ref = function(ent) return "`&" .. ent .. ";` is not a character reference" end,
  unknown_entity = function(ent) return "`&" .. ent .. ";` is not an entity this reader knows" end,
}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function is_name_start(c)
  return c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 58 or c >= 128)
end
local function is_name_char(c)
  return is_name_start(c) or (c >= 48 and c <= 57) or c == 45 or c == 46
end
local function is_space(c)
  return c == 32 or c == 9 or c == 13 or c == 10
end

local function build(M)
  local X = { messages = M }
  X.is_name_start = is_name_start
  X.is_name_char = is_name_char

  local function msg(key, arg)
    local m = M[key]
    if type(m) == "function" then return m(arg) end
    return m
  end

  --- The kit with some messages replaced.
  function X.with(overrides)
    local merged = {}
    for k, v in pairs(M) do merged[k] = v end
    for k, v in pairs(overrides) do merged[k] = v end
    return build(merged)
  end

  --- Decode entity and character references in `raw`, which began at
  --- byte `at`.
  function X.decode_entities(raw, at)
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
        if not semi then fig.fail(msg("entity_no_semicolon"), at + i - 1) end
        local ent = raw:sub(i + 1, semi - 1)
        if ent:sub(1, 1) == "#" then
          local hex = ent:sub(2, 2) == "x" or ent:sub(2, 2) == "X"
          local digits = hex and ent:sub(3) or ent:sub(2)
          local cp = tonumber(digits, hex and 16 or 10)
          if not cp or digits == "" or cp > 0x10FFFF then fig.fail(msg("bad_char_ref", ent), at + i - 1) end
          out[#out + 1] = utf8.char(cp)
        else
          local r = ENTITIES[ent]
          if not r then fig.fail(msg("unknown_entity", ent), at + i - 1) end
          out[#out + 1] = r
        end
        i = semi + 1
      end
    end
    return table.concat(out)
  end

  --- At a `<`: skip a comment, a processing instruction or a DOCTYPE and
  --- answer true; answer false where a tag, a close tag or a CDATA
  --- section begins; refuse other `<!` markup.
  function X.skip_markup(sc)
    local s = sc.pos
    if sc:starts("<!--") then
      sc:advance(4)
      local at = sc:find("-->")
      if not at then fig.fail(msg("unclosed_comment"), s) end
      sc.pos = at + 3
      return true
    elseif sc:starts("<![CDATA[") then
      return false
    elseif sc:starts("<!DOCTYPE") then
      sc:advance(9)
      while not sc:eof() do
        local c = sc:byte()
        if c == 91 then sc:fail(msg("doctype_subset")) end
        sc:advance()
        if c == 62 then return true end
      end
      sc:fail(msg("unterminated_doctype"))
    elseif sc:starts("<!") then
      sc:fail(msg("malformed"))
    elseif sc:starts("<?") then
      sc:advance(2)
      local at = sc:find("?>")
      if not at then fig.fail(msg("unclosed_pi"), s) end
      sc.pos = at + 2
      return true
    end
    return false
  end

  --- Skip whitespace and ignorable markup until a tag begins or the input
  --- ends; text where markup is expected refuses the input with `message`
  --- at the start of the run it is in.
  function X.skip(sc, message)
    while true do
      local run_s = sc.pos
      while not sc:eof() and is_space(sc:byte()) do sc:advance() end
      if sc:eof() then return end
      if sc:byte() ~= 60 then fig.fail(message, run_s) end
      if sc:starts("<![CDATA[") then fig.fail(message, sc.pos + 9) end
      if not X.skip_markup(sc) then return end
    end
  end

  --- The trivia rule between elements.
  function X.trivia(sc)
    local s = sc.pos
    X.skip(sc, msg("text_not_allowed"))
    return { s, sc.pos }
  end

  --- A tag rule: `<name>`, `<name/>`, with attributes as
  --- `opts.attributes` allows — false (the default: one refuses the input
  --- with `no_attributes`), true, or a function of the element name. The
  --- result is `{s, e, name=, name_s=, empty=, attrs={{name=, value=, s=}}}`;
  --- nil where no tag begins (a close tag, or not markup).
  function X.tag(opts)
    opts = opts or {}
    local allowed = opts.attributes
    return function(sc)
      local s = sc.pos
      if sc:byte() ~= 60 or not is_name_start(sc:byte(1)) then
        if sc:byte() == 60 and not sc:starts("</") and not sc:starts("<!") and not sc:starts("<?") then
          sc:fail(msg("malformed"))
        end
        return nil
      end
      sc:advance()
      local name_s = sc.pos
      sc:advance()
      while not sc:eof() and is_name_char(sc:byte()) do sc:advance() end
      local name = sc:slice(name_s, sc.pos)
      local may = allowed
      if type(may) == "function" then may = may(name) end
      local tag = { s, nil, name = name, name_s = name_s, empty = false, attrs = {} }
      while true do
        while not sc:eof() and is_space(sc:byte()) do sc:advance() end
        if sc:eof() then sc:fail(msg("unclosed_tag")) end
        local c = sc:byte()
        if c == 62 then
          sc:advance()
          break
        elseif c == 47 then
          if not sc:starts("/>") then sc:fail(msg("unclosed_empty_tag")) end
          sc:advance(2)
          tag.empty = true
          break
        elseif is_name_start(c) then
          if not may then sc:fail(msg("no_attributes", name)) end
          local a_s = sc.pos
          sc:advance()
          while not sc:eof() and is_name_char(sc:byte()) do sc:advance() end
          local a_name = sc:slice(a_s, sc.pos)
          while not sc:eof() and is_space(sc:byte()) do sc:advance() end
          if sc:byte() ~= 61 then sc:fail(msg("unexpected")) end
          sc:advance()
          while not sc:eof() and is_space(sc:byte()) do sc:advance() end
          local q = sc:byte()
          if q ~= 34 and q ~= 39 then sc:fail(msg("unexpected")) end
          sc:advance()
          local v_s = sc.pos
          while not sc:eof() and sc:byte() ~= q do
            if sc:byte() == 60 then sc:fail(msg("lt_in_attribute")) end
            sc:advance()
          end
          if sc:eof() then sc:fail(msg("unclosed_attribute")) end
          tag.attrs[#tag.attrs + 1] = { name = a_name, value = sc:slice(v_s, sc.pos), s = a_s }
          sc:advance()
        elseif c == 61 or c == 34 or c == 39 then
          sc:fail(msg("unexpected"))
        else
          sc:fail(msg("bad_tag_char"))
        end
      end
      tag[2] = sc.pos
      return tag
    end
  end

  --- A close-tag rule for `name`: nil where no close tag begins; a close
  --- tag of another name refuses the input.
  function X.close(name)
    return function(sc)
      local s = sc.pos
      if not sc:starts("</") then return nil end
      sc:advance(2)
      while not sc:eof() and is_space(sc:byte()) do sc:advance() end
      local name_s = sc.pos
      if not is_name_start(sc:byte()) then sc:fail(msg("wrong_close", name)) end
      sc:advance()
      while not sc:eof() and is_name_char(sc:byte()) do sc:advance() end
      if sc:slice(name_s, sc.pos) ~= name then fig.fail(msg("wrong_close", name), name_s) end
      while not sc:eof() and is_space(sc:byte()) do sc:advance() end
      if sc:byte() ~= 62 then sc:fail(msg("unexpected")) end
      sc:advance()
      return { s, sc.pos }
    end
  end

  --- The text content of an opened `tag`, entity references decoded and
  --- CDATA taken raw, through its close tag. An element inside refuses
  --- the input.
  function X.content(sc, tag)
    if tag.empty then return "" end
    local out = {}
    while true do
      if sc:eof() then sc:fail(msg("unexpected")) end
      if sc:byte() == 60 then
        if sc:starts("</") then break end
        if sc:starts("<![CDATA[") then
          sc:advance(9)
          local at = sc:find("]]>")
          if not at then fig.fail(msg("unclosed_cdata"), sc.pos - 9) end
          out[#out + 1] = sc:slice(sc.pos, at)
          sc.pos = at + 3
        elseif not X.skip_markup(sc) then
          sc:fail(msg("no_element", tag.name))
        end
      else
        local s = sc.pos
        local at = sc:find("<") or sc.n
        sc.pos = at
        out[#out + 1] = X.decode_entities(sc:slice(s, at), s)
      end
    end
    X.close(tag.name)(sc)
    return table.concat(out)
  end

  --- A rule for `<name>text</name>`: a string scalar over the whole
  --- element, its text decoded. nil where no tag begins; another
  --- element's tag refuses the input with `opts.wrong_name`.
  function X.text_element(name, opts)
    opts = opts or {}
    local tag_rule = X.tag({ attributes = opts.attributes })
    return function(sc)
      local tag = tag_rule(sc)
      if tag == nil then return nil end
      if tag.name ~= name then fig.fail(opts.wrong_name or msg("wrong_name", name), tag.name_s) end
      local text = X.content(sc, tag)
      return fig.scalar("string", { tag[1], sc.pos }, text)
    end
  end

  --- A rule that reads a tag and hands it to `handlers[name](sc, ctx,
  --- tag)`, or to `opts.otherwise(sc, ctx, tag)`; with neither, the
  --- input is refused with `unknown_element` at the tag.
  function X.element(handlers, opts)
    opts = opts or {}
    local tag_rule = X.tag({ attributes = opts.attributes })
    return function(sc, ctx)
      local tag = tag_rule(sc)
      if tag == nil then return nil end
      local h = handlers[tag.name] or opts.otherwise
      if not h then fig.fail(msg("unknown_element", tag.name), tag[1]) end
      return h(sc, ctx, tag)
    end
  end

  --- Escape `&`, `<` and `>` for text content.
  function X.escape(s)
    return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
  end

  return X
end

return build(DEFAULTS)
