-- dotenv, with a `print` that marks what it prints as splice text: a value
-- printed with `options.splice` comes back as `S` and the value, so an edit
-- through a binding shows what fig asked for. A whole document printed so
-- would not reparse, so the registration harness is a check too.
--
-- `dotenv` is the table `languages/dotenv.lua` returns: a script cannot
-- `require` another script, so `tests/splice.rs` loads this one after it,
-- in one chunk.

local M = {}
for k, v in pairs(dotenv) do M[k] = v end

local dialect = {}
for k, v in pairs(dotenv.dialects[1]) do dialect[k] = v end
dialect.name = "splice-spy"
dialect.extensions = { "splice-spy" }

M.name = "splice-spy"
M.dialects = { dialect }

function M.print(_dialect, t, options)
  local out = dotenv.print("lua-dotenv", t, options)
  return options.splice == true and ("S" .. out) or out
end

return M
