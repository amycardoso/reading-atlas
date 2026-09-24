-- Three-state, query-once caches, one per key.
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
-- Three states per key, deliberately distinct:
--   nil   -> not queried yet; a fetch is scheduled. Render "Reading…".
--   false -> queried; nothing usable came back. Render an explanation.
--   table -> the result.
--
-- Keys keep unrelated queries apart: phase 1's hour rows live under "hours",
-- and each axis of the territory map under its own "map:<axis>", so switching
-- a map from languages to authors can never be answered from the wrong cache.
local M = {}

local _state = {}   -- key -> { cache = nil|false|table, querying = bool, pending = {} }

local function stateFor(key)
    local s = _state[key]
    if not s then
        s = { cache = nil, querying = false, pending = {} }
        _state[key] = s
    end
    return s
end

-- Phase 1's rule: an empty result is the no-statistics state.
local function nonEmpty(result) return result ~= nil and #result > 0 end

local function defaultSchedule(fn) require("ui/uimanager"):scheduleIn(0, fn) end

local function hourDeps()
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return {
        query = function() return dofile(dir .. "db.lua").hourRows() end,
    }
end

-- Tests only.
function M.reset()
    _state = {}
end

-- deps.query    -> the result, or nil. Runs once, off the paint thread.
-- deps.schedule -> defers a function; defaults to UIManager:scheduleIn(0, …).
-- deps.accept   -> whether a result is usable; defaults to "a non-empty
--                  array". Anything it rejects, and any error, caches false.
function M.getKeyed(key, refresh, deps)
    local s = stateFor(key)
    if s.cache ~= nil then return s.cache end
    -- Every caller's refresh must survive to the query landing, even callers
    -- that arrive while a query is already in flight (the hero grid and the
    -- start menu can both render the same module in one frame). Collecting
    -- into pending here, before the querying guard below, is what makes
    -- that true.
    if refresh then s.pending[#s.pending + 1] = refresh end
    if s.querying then return nil end
    s.querying = true
    local schedule = deps.schedule or defaultSchedule
    local accept = deps.accept or nonEmpty
    schedule(function()
        local ok, result = pcall(deps.query)
        -- Never leave the cache at nil here, or the module would re-query
        -- on every single render.
        if ok and accept(result) then
            s.cache = result
        else
            s.cache = false
        end
        s.querying = false
        local callbacks = s.pending
        s.pending = {}
        for i = 1, #callbacks do pcall(callbacks[i]) end
    end)
    return nil
end

-- Phase 1's hour rows. A raised error, a nil return and a zero-length result
-- all mean the same thing to a reader: there are no statistics to show.
function M.get(refresh, deps)
    return M.getKeyed("hours", refresh, deps or hourDeps())
end

-- Read-only: a preview render (the Add picker draws every module's card
-- cold) must be able to show whatever is already cached without ever
-- scheduling a query of its own. Unlike getKeyed, a key peek() has not seen
-- yet stays nil forever -- peeking never starts the guard.
function M.peek(key)
    local s = _state[key]
    return s and s.cache
end

return M
