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

local _state = {}   -- key -> { cache = nil|false|table, due = time to refresh, querying = bool, pending = {} }

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
-- deps.max_age  -> optional seconds after which a settled result is stale.
--                  A stale result is still returned -- the card never drops
--                  back to "Reading…" -- while a fresh query runs off the
--                  paint thread; its refresh callbacks fire when it lands.
--                  Without it, a key is queried once per KOReader session.
-- deps.retry    -> seconds before trying again after a failed refresh;
--                  defaults to min(max_age, 300). A busy database (the
--                  statistics plugin flushing) should cost minutes, not
--                  another whole max_age of stale data.
-- deps.now      -> the clock for max_age; defaults to os.time.
--
-- A refresh whose query returns the very object already cached changed
-- nothing: the callbacks do not fire, so e-ink is not repainted with the same
-- card. A query that can tell its answer is unchanged returns the old object.
local function addPending(s, refresh)
    if not refresh then return end
    -- The host renders a card several times while fitting it; one refresh
    -- per caller is enough, or e-ink repaints the card N times.
    for i = 1, #s.pending do
        if s.pending[i] == refresh then return end
    end
    s.pending[#s.pending + 1] = refresh
end

local function startQuery(s, deps, revalidating)
    s.querying = true
    local schedule = deps.schedule or defaultSchedule
    local accept = deps.accept or nonEmpty
    local clock = deps.now or os.time
    schedule(function()
        local ok, result = pcall(deps.query)
        local unchanged = false
        if ok and accept(result) then
            unchanged = revalidating and rawequal(result, s.cache)
            s.cache = result
            s.due = deps.max_age and clock() + deps.max_age
        elseif revalidating and s.cache then
            -- A failed REfresh keeps the last good result: one bad read is no
            -- reason to blank a card that was showing data. Try again soon.
            local retry = deps.retry or math.min(deps.max_age, 300)
            s.due = clock() + retry
        elseif revalidating then
            -- Still nothing usable (no database yet): ask again in max_age,
            -- not every few minutes.
            s.due = clock() + deps.max_age
        else
            -- Never leave the cache at nil here, or the module would
            -- re-query on every single render.
            s.cache = false
            s.due = deps.max_age and clock() + deps.max_age
        end
        s.querying = false
        local callbacks = s.pending
        s.pending = {}
        if unchanged then return end
        for i = 1, #callbacks do pcall(callbacks[i]) end
    end)
end

function M.getKeyed(key, refresh, deps)
    local s = stateFor(key)
    if s.cache ~= nil then
        local clock = deps.now or os.time
        if deps.max_age and s.due and clock() >= s.due then
            addPending(s, refresh)
            if not s.querying then startQuery(s, deps, true) end
        end
        return s.cache
    end
    -- Every caller's refresh must survive to the query landing, even callers
    -- that arrive while a query is already in flight (the hero grid and the
    -- start menu can both render the same module in one frame). Collecting
    -- into pending here, before the querying guard below, is what makes
    -- that true.
    addPending(s, refresh)
    if s.querying then return nil end
    startQuery(s, deps, false)
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
