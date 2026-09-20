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

t.done()
