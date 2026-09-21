-- Helper loader for Reading Atlas.
--
-- ── WHY NOT require() ───────────────────────────────────────────────────────
-- Bookshelf dofiles each micro-module, and notes that a dofile'd file can
-- still require("lib/...") because package.path is process-wide. That is
-- exactly the problem: package.path points at BOOKSHELF's plugin root, so
-- require("lib/aggregate") would look inside bookshelf's lib/, not ours. Our
-- helpers live in a sibling atlas/ directory that is on nobody's package.path.
--
-- So: resolve from the calling file's own location and dofile. Results are
-- memoized in package.loaded (process-wide) under an "atlas/" prefix, so the
-- two spec files share one instance of each helper.
local M = {}

-- `dir` is the directory holding the spec files, WITH a trailing slash. A spec
-- file gets it from:  debug.getinfo(1, "S").source:match("^@(.+/)")
function M.make(dir)
    return function(name)
        local key = "atlas/" .. name
        local hit = package.loaded[key]
        if hit ~= nil then return hit end
        local mod = dofile(dir .. "atlas/" .. name .. ".lua")
        package.loaded[key] = mod
        return mod
    end
end

return M
