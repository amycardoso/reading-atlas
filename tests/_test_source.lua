-- The contract that bookshelf issue #194 paid for: the query runs once, off
-- the paint thread, and the three states are never conflated. A caller must
-- be able to tell "still loading" from "there are no statistics", because
-- they render as different cards.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Source = dofile("micromodules/atlas/source.lua")

-- Deferred scheduler: collects thunks so a test can decide when they run.
local function makeDeps(query)
    local pending = {}
    return {
        deps = {
            query = query,
            schedule = function(fn) pending[#pending + 1] = fn end,
            now = function() return 1000 end,
        },
        run = function()
            local queued = pending
            pending = {}
            for i = 1, #queued do queued[i]() end
        end,
        pendingCount = function() return #pending end,
    }
end

t.test("first call returns nil (loading) and does not query inline", function()
    Source.reset()
    local calls = 0
    local d = makeDeps(function() calls = calls + 1; return {} end)
    eq(Source.get(nil, d.deps), nil, "first call should report loading")
    eq(calls, 0, "query must NOT run on the paint thread")
    eq(d.pendingCount(), 1, "a fetch should have been scheduled")
end)

t.test("after the scheduled fetch runs, the rows are returned", function()
    Source.reset()
    local rows = { { hour = 10, secs = 60 } }
    local d = makeDeps(function() return rows end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), rows)
end)

t.test("a missing database resolves to false, not nil", function()
    Source.reset()
    local d = makeDeps(function() return nil end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), false, "no statistics must be false, not loading")
end)

t.test("concurrent renders schedule the query only once", function()
    Source.reset()
    local calls = 0
    local d = makeDeps(function() calls = calls + 1; return {} end)
    Source.get(nil, d.deps)
    Source.get(nil, d.deps)
    Source.get(nil, d.deps)
    eq(d.pendingCount(), 1, "the guard should collapse concurrent renders")
    d.run()
    eq(calls, 1, "the query should have run exactly once")
end)

t.test("the refresh callback fires once the data lands", function()
    Source.reset()
    local refreshed = 0
    local d = makeDeps(function() return {} end)
    Source.get(function() refreshed = refreshed + 1 end, d.deps)
    eq(refreshed, 0, "must not refresh before the data exists")
    d.run()
    eq(refreshed, 1)
end)

t.test("a query that raises resolves to false and does not wedge the guard", function()
    Source.reset()
    local d = makeDeps(function() error("boom") end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), false)
end)

t.test("every caller's refresh fires, not just the first in the frame", function()
    Source.reset()
    local heatmap_fired, clock_fired = 0, 0
    local d = makeDeps(function() return { { hour = 10, secs = 60 } } end)
    Source.get(function() heatmap_fired = heatmap_fired + 1 end, d.deps)
    Source.get(function() clock_fired = clock_fired + 1 end, d.deps)
    eq(d.pendingCount(), 1, "still only one query scheduled")
    d.run()
    eq(heatmap_fired, 1, "the first caller's refresh must fire")
    eq(clock_fired, 1, "the second caller's refresh must also fire")
end)

t.test("an empty rows table resolves to false, not an empty table", function()
    Source.reset()
    local d = makeDeps(function() return {} end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), false,
        "a statistics database with zero rows is the no-statistics state")
end)

t.test("separate keys keep separate caches", function()
    -- A map switched from languages to authors must query again, never be
    -- answered from the other axis's cache.
    Source.reset()
    local d = makeDeps(function() return { "languages" } end)
    Source.getKeyed("map:language", nil, d.deps)
    d.run()
    eq(Source.getKeyed("map:language", nil, d.deps)[1], "languages")

    local e = makeDeps(function() return { "authors" } end)
    eq(Source.getKeyed("map:author", nil, e.deps), nil,
        "a new key starts in the loading state")
    e.run()
    eq(Source.getKeyed("map:author", nil, e.deps)[1], "authors")
    eq(Source.getKeyed("map:language", nil, d.deps)[1], "languages",
        "the first key's cache is untouched")
end)

t.test("the hour rows and a keyed query do not share a guard", function()
    Source.reset()
    local d = makeDeps(function() return { { hour = 1, secs = 1 } } end)
    Source.get(nil, d.deps)
    Source.getKeyed("map:language", nil, d.deps)
    eq(d.pendingCount(), 2, "each key schedules its own query")
end)

t.test("accept decides what is usable: an empty table can be a real answer", function()
    -- The map distinguishes "the library is empty" (a table) from "bookshelf
    -- did not answer" (nil). Phase 1's non-empty rule would fold both into
    -- false, so the map passes its own accept.
    Source.reset()
    local d = makeDeps(function() return { territories = {}, unassigned = {} } end)
    d.deps.accept = function(r) return r ~= nil end
    Source.getKeyed("map:genre", nil, d.deps)
    d.run()
    local got = Source.getKeyed("map:genre", nil, d.deps)
    assert(type(got) == "table", "an empty library is data, not the false state")
end)

t.test("with a custom accept, nil still resolves to false", function()
    Source.reset()
    local d = makeDeps(function() return nil end)
    d.deps.accept = function(r) return r ~= nil end
    Source.getKeyed("map:series", nil, d.deps)
    d.run()
    eq(Source.getKeyed("map:series", nil, d.deps), false)
end)

-- ── peek ─────────────────────────────────────────────────────────────────
-- The Add picker renders every module's preview cold: peek must answer
-- straight from whatever is cached, without ever scheduling a query.

t.test("peek on an unknown key is nil and schedules nothing", function()
    Source.reset()
    eq(Source.peek("map:language"), nil)
end)

t.test("peek returns the settled value after a query lands", function()
    Source.reset()
    local rows = { territories = {}, unassigned = {} }
    local d = makeDeps(function() return rows end)
    d.deps.accept = function(r) return r ~= nil end
    eq(Source.peek("map:genre"), nil, "nothing queried yet")
    Source.getKeyed("map:genre", nil, d.deps)
    eq(Source.peek("map:genre"), nil, "still loading, no query has run")
    eq(d.pendingCount(), 1, "getKeyed itself scheduled the query, not peek")
    d.run()
    eq(Source.peek("map:genre"), rows)
end)

-- ── max_age ────────────────────────────────────────────────────────────────
-- A key with max_age re-queries once its result is old, but never makes the
-- card fall back to "Reading…" in the meantime.

local function agedDeps(results)
    local clock, n = 1000, 0
    local d = makeDeps(function() n = n + 1; return results[n] end)
    d.deps.accept = function(r) return r ~= nil end
    d.deps.max_age = 3600
    d.deps.now = function() return clock end
    d.advance = function(secs) clock = clock + secs end
    d.calls = function() return n end
    return d
end

t.test("a fresh result is served without re-querying", function()
    Source.reset()
    local d = agedDeps({ { "a" }, { "b" } })
    Source.getKeyed("fp", nil, d.deps)
    d.run()
    d.advance(3599)
    eq(Source.getKeyed("fp", nil, d.deps)[1], "a")
    eq(d.pendingCount(), 0, "not stale yet")
end)

t.test("a stale result is served while a fresh query runs off the paint path", function()
    Source.reset()
    local d = agedDeps({ { "a" }, { "b" } })
    Source.getKeyed("fp", nil, d.deps)
    d.run()
    d.advance(3600)
    local refreshed = 0
    eq(Source.getKeyed("fp", function() refreshed = refreshed + 1 end, d.deps)[1], "a",
        "stale data, never nil")
    eq(d.calls(), 1, "the new query must not run inside render")
    eq(Source.getKeyed("fp", nil, d.deps)[1], "a", "a second render does not queue twice")
    eq(d.pendingCount(), 1)
    d.run()
    eq(refreshed, 1, "the card is told to redraw")
    eq(Source.getKeyed("fp", nil, d.deps)[1], "b")
end)

t.test("a failed refresh keeps the last good result and retries in minutes", function()
    Source.reset()
    local d = agedDeps({ { "a" }, nil, { "c" } })
    Source.getKeyed("fp", nil, d.deps)
    d.run()
    d.advance(4000)
    Source.getKeyed("fp", nil, d.deps)
    d.run()
    eq(Source.getKeyed("fp", nil, d.deps)[1], "a", "the last good result stays")
    eq(d.pendingCount(), 0, "not retried on every render")
    d.advance(299)
    Source.getKeyed("fp", nil, d.deps)
    eq(d.pendingCount(), 0, "not before the retry delay")
    d.advance(1)
    Source.getKeyed("fp", nil, d.deps)
    eq(d.pendingCount(), 1, "retried after five minutes, not another hour")
    d.run()
    eq(Source.getKeyed("fp", nil, d.deps)[1], "c")
end)

t.test("the same refresh callback fires once, however many renders asked", function()
    Source.reset()
    local d = agedDeps({ { "a" }, { "b" } })
    local fired = 0
    local cb = function() fired = fired + 1 end
    Source.getKeyed("fp", cb, d.deps)
    Source.getKeyed("fp", cb, d.deps)
    d.run()
    eq(fired, 1, "first load")
    d.advance(3600)
    for _i = 1, 4 do Source.getKeyed("fp", cb, d.deps) end
    d.run()
    eq(fired, 2, "one more for the refresh, not four")
end)

t.test("without max_age a key is queried once per session, as before", function()
    Source.reset()
    local d = agedDeps({ { "a" }, { "b" } })
    d.deps.max_age = nil
    Source.getKeyed("fp", nil, d.deps)
    d.run()
    d.advance(10 * 86400)
    eq(Source.getKeyed("fp", nil, d.deps)[1], "a")
    eq(d.pendingCount(), 0)
end)

t.done()
