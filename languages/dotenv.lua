-- dotenv, in Lua: the twin of fig's compiled `dotenv` format, row for row.
--
-- `fig lang check lua-dotenv --against dotenv <files…>` holds this script to
-- the compiled parser's node table on every file given, and this script is
-- written against `fig lang table -i dotenv`, which prints that table. What
-- the compiled format accepts is stated in fig's `src/languages/dotenv/`,
-- and this follows it line for line:
--
--   * a key is a bash identifier, `[A-Za-z_][A-Za-z0-9_]*`; an `export `
--     before one is recognized and discarded;
--   * a value is unquoted (trimmed, to end of line, or to a `#` that at
--     least one space or tab precedes), double-quoted (`\n \t \r \\ \"`
--     decoded, may span lines) or single-quoted (raw, may span lines);
--     a `\r\n` inside a quoted value reads as `\n`;
--   * a full-line `#` is a comment, leading for the next key, or dangling
--     on the root when no key follows; a `#` after a value on its line is
--     the value's trailing comment; a `#` right after a closing quote
--     needs no space before it;
--   * a repeated key keeps the FIRST entry's place and takes the LAST
--     value; the later key's own leading comments go with it.
--
-- Every value is a string: dotenv has no typed scalars and does no `$VAR`
-- interpolation. Spans are byte offsets, 0-based, `[start, end)`.
--
-- The grammar refuses what the compiled parser refuses, in its words and
-- at its offsets, with one difference of order: the compiled tokenizer
-- runs over the whole file before its parser, so on a file with two
-- errors it may report the later one when that is the tokenizer's; this
-- reports the first.

local G = require("fig.grammar")

local M = {}

M.name = "lua-dotenv"
M.caps = { read = true, edit = true, serialize = true }
-- Flat: no mapping inside the root.
M.max_mapping_depth = 0
M.syntax = {
  comments = { style = "hash", line = { open = "#" }, trailing = { open = "#" } },
  kv_sep = "=",
  empty_map_literal = "{}",
  flow_containers = false,
}
M.dialects = {
  -- `env`, the extension: the compiled format owns `.env` too, and a
  -- compiled format's extension wins, so this is reached by `--lang`.
  { name = "lua-dotenv", extensions = { "env" }, splice = "raw", empty_doc_seed = "" },
}
M.samples = {
  "A=1\nB=\"two words\"\n",
  "# top\nexport C='raw \\n'\nD=x # trailing\n",
}
M.renderers = {}

-- ── errors, as the compiled parser words them ─────────────────────────────

local MESSAGES = {
  UnexpectedToken = "unexpected content here; expected `KEY=value` (optionally `export KEY=value`)",
  MissingEquals = "expected `=` after this key; every dotenv line is `KEY=value`",
  BadEscape = "invalid escape in a double-quoted value; supported: \\n \\t \\r \\\\ \\\" — use a single-quoted value for raw text with backslashes",
  InvalidUtf8 = "this file is not valid UTF-8; dotenv documents must be UTF-8 encoded",
  UnexpectedCarriageReturn = "a bare `\\r` must be followed by `\\n`; line endings must be `\\n` or `\\r\\n`",
  UnclosedString = "unclosed quoted value; expected a matching `\"`/`'` before the end of the file",
  UnexpectedChar = "not a valid key here; a dotenv key is a bash identifier (`[A-Za-z_][A-Za-z0-9_]*`)",
  TrailingContent = "unexpected content after this quoted value; only a `#` comment may follow it on the same line",
}

-- ── the grammar ───────────────────────────────────────────────────────────

-- A bare `\r` is refused wherever the compiled tokenizer meets one.
local bare_cr = G.fail_if(G.lit("\r"), MESSAGES.UnexpectedCarriageReturn)

-- After a closing quote only spaces, a comment or the line's end may
-- follow. Answers where a bad escape in the value is reported: at the
-- comment's text or the line end, as the compiled parser does.
local function after_quoted(sc)
  local save = sc.pos
  sc:match("[ \t]*")
  local at = sc.pos
  if sc:starts("#") then
    at = at + 1
  elseif not (sc:eof() or sc:starts("\n") or sc:starts("\r")) then
    sc:fail(MESSAGES.TrailingContent)
  end
  sc.pos = save
  return at
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"' }

local value = G.choice({
  G.quoted({
    open = '"',
    escapes = ESCAPES,
    unclosed = MESSAGES.UnclosedString,
    bad_escape = MESSAGES.BadEscape,
    bare_cr = MESSAGES.UnexpectedCarriageReturn,
    after = after_quoted,
  }),
  G.quoted({
    open = "'",
    unclosed = MESSAGES.UnclosedString,
    bare_cr = MESSAGES.UnexpectedCarriageReturn,
    after = after_quoted,
  }),
  -- Unquoted: to the line's end, or to a `#` that a space or tab
  -- precedes — the one right after `=` counts, since `A= #c` is empty.
  G.bare({
    stop = function(sc)
      local before = sc:byte(-1)
      return sc:starts("#") and (before == 32 or before == 9)
    end,
  }),
})

local entry = G.entry({
  -- `export` is a prefix only when a key follows it on the line; alone
  -- before `=` it is the key.
  prefix = G.seq({ G.lit("export"), G.hs1, G.ahead(G.pat("[A-Za-z_]")) }),
  key = G.key(G.pat("[A-Za-z_][A-Za-z0-9_]*")),
  sep = G.lit("="),
  value = value,
  missing_sep = MESSAGES.MissingEquals,
})

M.parse = G.document({
  utf8 = MESSAGES.InvalidUtf8,
  bom = true,
  root = G.map({
    whole = true,
    entry = entry,
    trivia = G.trivia({
      space = G.choice({ G.hs1, G.eol, bare_cr }),
      comment = G.comment("#"),
    }),
    -- Where a key should be: `=` is a token the compiled parser refuses;
    -- anything else is a byte its tokenizer refuses.
    otherwise = function(sc)
      if sc:starts("=") then sc:fail(MESSAGES.UnexpectedToken) end
      sc:fail(MESSAGES.UnexpectedChar)
    end,
  }),
})

-- ── the printer ───────────────────────────────────────────────────────────
-- Canonical `.env`, as the compiled printer writes it: one `KEY=value` line
-- per entry, a value bare when that is unambiguous and double-quoted with
-- escapes otherwise (never a literal embedded newline), leading comments
-- as `# …` lines above the key, a trailing comment inline after the value,
-- dangling comments at the end.

local function is_identifier(name)
  return name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function needs_quoting(v)
  if v == "" then return false end
  local first, last = v:sub(1, 1), v:sub(-1)
  if first == " " or first == "\t" or last == " " or last == "\t" then return true end
  return v:find("[\n\r\"\\#]") ~= nil
end

local QUOTE = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\" }

local function write_value(w, row)
  local k = row.kind
  if k == "string" then
    local v = row.text or ""
    if needs_quoting(v) then
      w:put('"', (v:gsub('[\n\r\t"\\]', QUOTE)), '"')
    else
      w:put(v)
    end
  elseif k == "int" or k == "float" or k == "bool" then
    w:put(row.text or "")
  elseif k == "null" then
    error("dotenv has no null; a null value cannot be written", 0)
  elseif k == "sequence" or k == "mapping" then
    error("dotenv holds a flat map of strings; a nested value cannot be written", 0)
  elseif k == "alias" then
    error("an alias must be resolved before it is written as dotenv", 0)
  else
    error("a " .. k .. " is not a value", 0)
  end
end

local function comment_lines(w, c)
  for line in (c.text .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^[ \t]*(.-)[ \t]*$")
    w:put(trimmed == "" and "#\n" or ("# " .. trimmed .. "\n"))
  end
end

function M.print(_dialect, t, _options)
  local w = fig.writer()
  local root = t.byid(0)
  if root.kind ~= "mapping" then
    -- A fragment: the scalar as it stands alone.
    write_value(w, root)
    return w:string()
  end
  for _, kv in ipairs(root.items) do
    local key, value = kv.key, kv.value
    if key.kind ~= "string" then error("a dotenv key must be a string", 0) end
    if not is_identifier(key.text or "") then
      error("`" .. (key.text or "") .. "` is not a dotenv key; a key is a bash identifier", 0)
    end
    for _, c in ipairs(key.leading) do comment_lines(w, c) end
    w:put(key.text, "=")
    write_value(w, value)
    local trailing = value.trailing[1]
    if trailing then
      w:put(" #")
      if trailing.text ~= "" then w:put(" ", (trailing.text:gsub("\n", " "))) end
    end
    w:put("\n")
  end
  for _, c in ipairs(root.dangling) do comment_lines(w, c) end
  return w:string()
end

return M
