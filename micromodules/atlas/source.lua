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
local _pending = {}     -- refresh callbacks waiting on the in-flight query

local function defaultDeps()
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return {
        query = function() return dofile(dir .. "db.lua").hourRows() end,
        schedule = function(fn) require("ui/uimanager"):scheduleIn(0, fn) end,
    }
end

-- Tests only.
function M.reset()
    _cache = nil
    _querying = false
    _pending = {}
end

function M.get(refresh, deps)
    deps = deps or defaultDeps()
    if _cache ~= nil then return _cache end
    -- Every caller's refresh must survive to the query landing, even callers
    -- that arrive while a query is already in flight (the hero grid and the
    -- start menu can both render the same module in one frame). Collecting
    -- into _pending here, before the _querying guard below, is what makes
    -- that true.
    if refresh then _pending[#_pending + 1] = refresh end
    if _querying then return nil end
    _querying = true
    deps.schedule(function()
        local ok, rows = pcall(deps.query)
        -- A raised error, a nil return, and a zero-length result all mean
        -- the same thing to a reader: there are no statistics to show.
        -- Never leave the cache at nil here, or the module would re-query
        -- on every single render.
        if ok and rows and #rows > 0 then
            _cache = rows
        else
            _cache = false
        end
        _querying = false
        local callbacks = _pending
        _pending = {}
        for i = 1, #callbacks do pcall(callbacks[i]) end
    end)
    return nil
end

return M
