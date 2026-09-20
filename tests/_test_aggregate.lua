-- Bucketing is where every "when did I read" claim is decided, so it is
-- tested against an INJECTED clock: the same input must bucket identically
-- regardless of the machine's timezone.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Agg = dofile("micromodules/atlas/aggregate.lua")

-- A fake "local time" that is UTC+0, so expectations are readable.
local function utc(ts) return os.date("!*t", ts) end

-- 2026-01-05 was a Monday. os.date wday: 1=Sunday, so Monday is 2.
local MON_0900 = 1767603600  -- 2026-01-05T09:00:00Z

t.test("byDay sums a single hour into its day", function()
    local rows = { { hour = math.floor(MON_0900 / 3600), secs = 600 } }
    eq(Agg.byDay(rows, utc), { ["2026-01-05"] = 600 })
end)

t.test("byDay sums several hours of the same day", function()
    local rows = {
        { hour = math.floor(MON_0900 / 3600),            secs = 600 },
        { hour = math.floor((MON_0900 + 3600) / 3600),   secs = 300 },
    }
    eq(Agg.byDay(rows, utc), { ["2026-01-05"] = 900 })
end)

t.test("byDay separates days", function()
    local rows = {
        { hour = math.floor(MON_0900 / 3600),             secs = 600 },
        { hour = math.floor((MON_0900 + 86400) / 3600),   secs = 100 },
    }
    eq(Agg.byDay(rows, utc), { ["2026-01-05"] = 600, ["2026-01-06"] = 100 })
end)

t.test("byDay on no rows is an empty table, not nil", function()
    eq(Agg.byDay({}, utc), {})
end)

t.test("byHourWeekday puts Monday 09:00 at wday 2, hour 9", function()
    local rows = { { hour = math.floor(MON_0900 / 3600), secs = 600 } }
    local got = Agg.byHourWeekday(rows, utc)
    eq(got[2][9], 600)
end)

t.test("byHourWeekday sums the same slot across weeks", function()
    local rows = {
        { hour = math.floor(MON_0900 / 3600),                secs = 600 },
        { hour = math.floor((MON_0900 + 7 * 86400) / 3600),  secs = 400 },
    }
    local got = Agg.byHourWeekday(rows, utc)
    eq(got[2][9], 1000)
end)

t.test("byHourWeekday returns a full 7x24 grid, zeros included", function()
    local got = Agg.byHourWeekday({ { hour = math.floor(MON_0900 / 3600), secs = 60 } }, utc)
    local cells, sum = 0, 0
    for wday = 1, 7 do
        for hour = 0, 23 do
            assert(got[wday][hour] ~= nil,
                ("missing cell wday=%d hour=%d"):format(wday, hour))
            cells = cells + 1
            sum = sum + got[wday][hour]
        end
    end
    eq(cells, 168, "grid should have 7*24 cells")
    eq(sum, 60, "only the seeded minute should be counted")
end)

t.test("byDay respects the injected localtime crossing a day boundary", function()
    -- +3h offset makes Monday 23:00 UTC become Tuesday 02:00 local.
    local plus3h = function(ts) return os.date("!*t", ts + 3 * 3600) end
    local MON_2300 = 1767654000  -- 2026-01-05T23:00:00Z
    local rows = { { hour = math.floor(MON_2300 / 3600), secs = 500 } }
    eq(Agg.byDay(rows, plus3h), { ["2026-01-06"] = 500 })
end)

t.test("byHourWeekday respects the injected localtime changing weekday", function()
    -- +3h offset makes Monday 23:00 UTC become Tuesday 02:00 local.
    local plus3h = function(ts) return os.date("!*t", ts + 3 * 3600) end
    local MON_2300 = 1767654000  -- 2026-01-05T23:00:00Z
    local rows = { { hour = math.floor(MON_2300 / 3600), secs = 500 } }
    local got = Agg.byHourWeekday(rows, plus3h)
    eq(got[3][2], 500)  -- Tuesday (wday=3) at 02:00 (hour=2)
end)

t.done()
