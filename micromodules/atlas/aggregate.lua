-- Pure bucketing of reading time. No KOReader, no I/O, no globals touched.
--
-- Input is always `hour_rows`: { { hour = <UTC hour number>, secs = n }, ... }
-- where hour = floor(start_time / 3600). One query produces it; both modules
-- consume it.
--
-- `localtime` is injected so the suites are timezone-independent. Production
-- callers omit it and get os.date("*t", ts), i.e. the device's local time,
-- which is what a reader means by "what did I read on Tuesday".
local M = {}

local function defaultLocaltime(ts) return os.date("*t", ts) end

-- { ["YYYY-MM-DD"] = seconds }, only for days that have reading.
function M.byDay(hour_rows, localtime)
    localtime = localtime or defaultLocaltime
    local out = {}
    for i = 1, #hour_rows do
        local row = hour_rows[i]
        local d = localtime(row.hour * 3600)
        local key = ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
        out[key] = (out[key] or 0) + row.secs
    end
    return out
end

-- Full 7x24 grid of seconds. Zeros are PRESENT, not absent: the widget paints
-- every cell, and a nil would make it decide between "no data" and "no
-- reading" at paint time, which is a decision that belongs here.
function M.byHourWeekday(hour_rows, localtime)
    localtime = localtime or defaultLocaltime
    local out = {}
    for wday = 1, 7 do
        out[wday] = {}
        for hour = 0, 23 do out[wday][hour] = 0 end
    end
    for i = 1, #hour_rows do
        local row = hour_rows[i]
        local d = localtime(row.hour * 3600)
        out[d.wday][d.hour] = out[d.wday][d.hour] + row.secs
    end
    return out
end

return M
