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

t.done()
