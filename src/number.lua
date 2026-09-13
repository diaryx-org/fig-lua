-- `require("fig.number")`: how a number's lexeme is spelled for a format —
-- the twin of fig's `src/util/number.zig`.
--
-- A number row's `text` is its source lexeme, verbatim: `0xff`, `1_000`,
-- `.5`, `+7`. A printer's instinct is to write it back as it stands, and
-- that is right only when the format being written reads the lexeme back
-- as the same number. It often does not: YAML 1.2 reads `0b1010` as a
-- string, strict JSON refuses `.5` outright. So a printer asks
-- `N.spellable(raw, spelling)` first and falls back to `N.canonical(raw)` —
-- decimal, the one spelling every format shares. The value is unchanged;
-- only its notation degrades.
local N = {}

--- The spellings a format reads back as a number. A field left false
--- means that spelling is canonicalized to decimal before it is written:
--- `hex` (`0x1F`), `octal` (`0o17`), `binary` (`0b1010`), `underscores`
--- (`1_000`), `leading_zero` (`0755`), `bare_dot` (`.5`, `5.`), `plus` (a
--- leading `+`).
N.NONE = {}

--- Strict JSON: none of it.
N.JSON = N.NONE

--- JSON5's numbers are ES5.1 numeric literals: hex, a leading `+`, and
--- bare dots — not `0o`/`0b`, `_`, or a leading zero.
N.JSON5 = { hex = true, bare_dot = true, plus = true }

--- YAML 1.2 core: hex and octal, a bare dot, a leading `+`, and a leading
--- zero (read as decimal); no `0b` and no `_`, which 1.2 reads as strings.
N.YAML_1_2 = { hex = true, octal = true, leading_zero = true, bare_dot = true, plus = true }

--- Whether a format that spells `s` reads `raw` back as the same number.
function N.spellable(raw, s)
  s = s or N.NONE
  local body = raw
  local first = raw:sub(1, 1)
  if first == "+" or first == "-" then
    if first == "+" and not s.plus then return false end
    body = raw:sub(2)
  end
  if body == "" then return false end
  if not s.underscores and body:find("_", 1, true) then return false end
  if #body >= 2 and body:sub(1, 1) == "0" then
    local r = body:sub(2, 2):lower()
    if r == "x" then return s.hex == true end
    if r == "o" then return s.octal == true end
    if r == "b" then return s.binary == true end
  end
  if not s.bare_dot and (body:sub(1, 1) == "." or body:sub(-1) == ".") then return false end
  if not s.leading_zero then
    local m = body:find("[.eE]")
    local int_end = m and (m - 1) or #body
    if int_end > 1 and body:sub(1, 1) == "0" then return false end
  end
  return true
end

local RADIX = { x = 16, o = 8, b = 2 }
local DIGITS = { [16] = "^[0-9a-fA-F]+$", [8] = "^[0-7]+$", [2] = "^[01]+$" }

-- Decimal digits of `digits` read in `base`, as a string of any length.
local function to_decimal(digits, base)
  local out = { 0 }
  for i = 1, #digits do
    local d = tonumber(digits:sub(i, i), 16)
    local carry = d
    for j = 1, #out do
      local v = out[j] * base + carry
      out[j] = v % 10
      carry = v // 10
    end
    while carry > 0 do
      out[#out + 1] = carry % 10
      carry = carry // 10
    end
  end
  local s = {}
  for j = #out, 1, -1 do s[#s + 1] = tostring(out[j]) end
  return table.concat(s)
end

--- `raw` as the decimal lexeme every format reads: a radix converted, `_`
--- and a leading `+` dropped, a bare dot padded, leading zeros stripped.
--- A lexeme that is not a number at all comes back as it was.
function N.canonical(raw)
  local out = ""
  local s = raw
  if s:sub(1, 1) == "-" then
    out = "-"
    s = s:sub(2)
  elseif s:sub(1, 1) == "+" then
    s = s:sub(2)
  end
  if #s >= 2 and s:sub(1, 1) == "0" and RADIX[s:sub(2, 2):lower()] then
    local base = RADIX[s:sub(2, 2):lower()]
    local digits = s:sub(3):gsub("_", "")
    if digits == "" or not digits:match(DIGITS[base]) then return out .. s end
    return out .. to_decimal(digits, base)
  end
  local e_idx = s:find("[eE]")
  local mantissa = e_idx and s:sub(1, e_idx - 1) or s
  local exponent = e_idx and s:sub(e_idx) or ""
  local dot = mantissa:find(".", 1, true)
  local int_part = dot and mantissa:sub(1, dot - 1) or mantissa
  local int_digits = int_part:gsub("_", ""):gsub("^0+", "")
  out = out .. (int_digits == "" and "0" or int_digits)
  if dot then
    local frac = mantissa:sub(dot + 1):gsub("_", "")
    out = out .. "." .. (frac == "" and "0" or frac)
  end
  return out .. (exponent:gsub("_", ""))
end

--- `raw` as a format that spells `s` writes it: itself when spellable,
--- else canonical.
function N.text(raw, s)
  if N.spellable(raw, s) then return raw end
  return N.canonical(raw)
end

return N
