-- Three-state, query-once cache over db.hourRows().
--
-- ── WHY ─────────────────────────────────────────────────────────────────────
-- Bookshelf's reading_streak carries the scar of issue #194: a synchronous
-- query against a large statistics database froze the menu as it opened. Two
-- rules follow, and both are asserted in tests/_test_source.lua:
--
--   1. The query never runs on the paint thread. render() schedules it and
--      returns whatever is known right now.
--   2. A guard collapses concurrent renders (the hero grid and the start menu
--      can both render the same module in one frame) into one query.
--
-- Three states, deliberately distinct:
--   nil   -> not queried yet; a fetch is scheduled. Render "Reading…".
--   false -> queried; no statistics database. Render an explanation.
--   table -> hour rows.
local M = {}

local _cache = nil      -- nil | false | table
local _querying = false

local function defaultDeps()
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return {
        query = function() return dofile(dir .. "db.lua").hourRows() end,
        schedule = function(fn) require("ui/uimanager"):scheduleIn(0, fn) end,
        now = os.time,
    }
end

-- Tests only.
function M.reset()
    _cache = nil
    _querying = false
end

function M.get(refresh, deps)
    deps = deps or defaultDeps()
    if _cache ~= nil then return _cache end
    if _querying then return nil end
    _querying = true
    deps.schedule(function()
        local ok, rows = pcall(deps.query)
        -- Both a raised error and a nil return mean the same thing to a
        -- reader: there are no statistics to show. Never leave the cache at
        -- nil here, or the module would re-query on every single render.
        _cache = (ok and rows) or false
        _querying = false
        if refresh then pcall(refresh) end
    end)
    return nil
end

return M
