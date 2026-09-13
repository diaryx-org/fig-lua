-- `require("fig.datetime")`: which datetime shape a bare token is — the
-- twin of fig's `src/util/datetime.zig`.
--
-- TOML, YAML and fig all read `2024-01-02`, `12:30:00`, `2024-01-02T12:30:00`
-- and `2024-01-02T12:30:00+01:00` as typed scalars whose `ext_kind` is one
-- of `local_date`, `local_time`, `local_datetime` and `offset_datetime`,
-- and validate them the same way: a real calendar date, a time of day
-- with optional fraction, an offset within a day. What differs per format
-- is only what is allowed — whether seconds may be omitted, and whether a
-- bare time with no date is a time at all — and that is `opts`.
local DT = {}

local function two(s, at)
  return tonumber(s:sub(at + 1, at + 2), 10)
end

local function both_digits(s, at)
  return s:sub(at + 1, at + 2):match("^%d%d$") ~= nil
end

local function days_in_month(year, month)
  if month == 2 then
    if (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0 then return 29 end
    return 28
  end
  if month == 4 or month == 6 or month == 9 or month == 11 then return 30 end
  return 31
end

--- Whether `s` is `YYYY-MM-DD` and a day that exists.
function DT.valid_date(s)
  if #s ~= 10 or s:sub(5, 5) ~= "-" or s:sub(8, 8) ~= "-" then return false end
  if not (both_digits(s, 0) and both_digits(s, 2) and both_digits(s, 5) and both_digits(s, 8)) then return false end
  local year = two(s, 0) * 100 + two(s, 2)
  local month = two(s, 5)
  local day = two(s, 8)
  if month < 1 or month > 12 then return false end
  return day >= 1 and day <= days_in_month(year, month)
end

--- Whether `s` is `HH:MM:SS[.frac]` — or `HH:MM`, when
--- `opts.minute_precision` (true) allows the seconds to be omitted. A
--- second of 60 is allowed, for a leap second.
function DT.valid_time(s, opts)
  local minute_precision = not (opts and opts.minute_precision == false)
  if #s < 5 or s:sub(3, 3) ~= ":" then return false end
  if not (both_digits(s, 0) and both_digits(s, 3)) then return false end
  if two(s, 0) > 23 or two(s, 3) > 59 then return false end
  if #s == 5 then return minute_precision end
  if s:sub(6, 6) ~= ":" or #s < 8 then return false end
  if not both_digits(s, 6) or two(s, 6) > 60 then return false end
  if #s == 8 then return true end
  if s:sub(9, 9) ~= "." or #s < 10 then return false end
  return s:sub(10):match("^%d+$") ~= nil
end

--- Whether `s` is `±HH:MM`, an offset within a day.
function DT.valid_offset(s)
  if #s ~= 6 or s:sub(4, 4) ~= ":" then return false end
  if not (both_digits(s, 1) and both_digits(s, 4)) then return false end
  return two(s, 1) <= 23 and two(s, 4) <= 59
end

--- The shape of `raw` — "offset_datetime", "local_datetime", "local_date"
--- or "local_time" — or nil when it is not a datetime. `opts`:
--- `minute_precision` (true) accepts `HH:MM` with no seconds, as TOML 1.1
--- and YAML do and TOML 1.0 does not; `time_only` (true) accepts a bare
--- time with no date, as TOML does and YAML 1.1 does not (there a `:`-run
--- with no date is a sexagesimal number). The date and the time are joined
--- by `T`, `t` or a space; an offset is `Z`, `z` or `±HH:MM`.
function DT.classify(raw, opts)
  local time_only = not (opts and opts.time_only == false)
  if time_only and #raw >= 3 and raw:sub(3, 3) == ":" then
    if DT.valid_time(raw, opts) then return "local_time" end
    return nil
  end
  if #raw < 10 then return nil end
  if not DT.valid_date(raw:sub(1, 10)) then return nil end
  if #raw == 10 then return "local_date" end
  local sep = raw:sub(11, 11)
  if sep ~= "T" and sep ~= "t" and sep ~= " " then return nil end
  local rest = raw:sub(12)
  local time = rest
  local has_offset = false
  local last = rest:sub(-1)
  if last == "Z" or last == "z" then
    time = rest:sub(1, -2)
    has_offset = true
  elseif #rest >= 6 and (rest:sub(-6, -6) == "+" or rest:sub(-6, -6) == "-") and rest:sub(-3, -3) == ":" then
    if not DT.valid_offset(rest:sub(-6)) then return nil end
    time = rest:sub(1, -7)
    has_offset = true
  end
  if not DT.valid_time(time, opts) then return nil end
  if has_offset then return "offset_datetime" end
  return "local_datetime"
end

--- The four kinds `classify` answers, as a set, for a printer deciding
--- whether an `ext_kind` is a datetime.
DT.KINDS = { offset_datetime = true, local_datetime = true, local_date = true, local_time = true }

return DT
