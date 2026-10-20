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

local _state = {}   -- key -> { cache, at = time settled, due = time to refresh, failures, querying, pending }

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
-- deps.retry    -> with max_age: seconds before trying again after a failure,
--                  doubling with each failure in a row up to max_age;
--                  defaults to min(max_age, 300). A busy database (the
--                  statistics plugin flushing) should cost minutes, whether
--                  it hits the first query or a refresh; a database that is
--                  really not there backs off to max_age.
-- deps.now      -> the clock for max_age; defaults to os.time.
--
-- Callbacks fire only when what the card shows changed: a refresh whose
-- query returns the very object already cached, or a failure that leaves the
-- cache as it was, repaints nothing on e-ink. A query that can tell its
-- answer is unchanged returns the old object.
local function addPending(s, refresh)
    if not refresh then return end
    -- The host renders a card several times while fitting it; one refresh
    -- per caller is enough, or e-ink repaints the card N times.
    for i = 1, #s.pending do
        if s.pending[i] == refresh then return end
    end
    s.pending[#s.pending + 1] = refresh
end

local function startQuery(s, deps)
    s.querying = true
    local schedule = deps.schedule or defaultSchedule
    local accept = deps.accept or nonEmpty
    local clock = deps.now or os.time
    schedule(function()
        local ok, result = pcall(deps.query)
        local before = s.cache
        if ok and accept(result) then
            s.cache = result
            s.failures = 0
            s.at = clock()
            s.due = deps.max_age and s.at + deps.max_age
        else
            -- A failed refresh keeps the last good result: one bad read is no
            -- reason to blank a card that was showing data. A failed first
            -- query settles at false -- never nil, or the module would
            -- re-query on every single render.
            if s.cache == nil then s.cache = false end
            s.failures = (s.failures or 0) + 1
            if deps.max_age then
                local retry = deps.retry or math.min(deps.max_age, 300)
                s.at = clock()
                s.due = s.at + math.min(deps.max_age, retry * 2 ^ (s.failures - 1))
            end
        end
        local unchanged = rawequal(before, s.cache)
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
        -- Due, or the clock went backwards past the last query: an e-reader's
        -- clock is often corrected mid-session (it boots wrong, then syncs),
        -- and an absolute due time set by a clock a year ahead would
        -- otherwise freeze the card for that year.
        local now = deps.max_age and s.due and clock()
        if now and (now >= s.due or now < s.at) then
            addPending(s, refresh)
            if not s.querying then startQuery(s, deps) end
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
    startQuery(s, deps)
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
