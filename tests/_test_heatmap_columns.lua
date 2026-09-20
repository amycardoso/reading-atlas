-- The calendar mapping is where an off-by-one becomes a year drawn one day
-- skewed, which is the kind of bug you only notice in December.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Cal = dofile("micromodules/atlas/calendar.lua")
local function utc(ts) return os.date("!*t", ts) end

t.test("a year needs 53 columns at most and 52 at least", function()
    local c = Cal.columns(2026, utc)
    assert(c.weeks >= 52 and c.weeks <= 54, "got " .. c.weeks)
end)

t.test("2026-01-01 was a Thursday: row 5, column 1", function()
    local c = Cal.columns(2026, utc)
    eq(c.dayKey(1, 5), "2026-01-01")
end)

t.test("cells before the first day of the year are empty", function()
    local c = Cal.columns(2026, utc)
    eq(c.dayKey(1, 1), nil, "Sunday of week 1 precedes Jan 1 in 2026")
end)

t.test("the last day of the year is present exactly once", function()
    local c = Cal.columns(2026, utc)
    local seen = 0
    for col = 1, c.weeks do
        for row = 1, 7 do
            if c.dayKey(col, row) == "2026-12-31" then seen = seen + 1 end
        end
    end
    eq(seen, 1)
end)

t.test("every day of a leap year appears exactly once", function()
    local c = Cal.columns(2024, utc)
    local count = 0
    for col = 1, c.weeks do
        for row = 1, 7 do
            if c.dayKey(col, row) then count = count + 1 end
        end
    end
    eq(count, 366, "2024 is a leap year")
end)

t.done()
