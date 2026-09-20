-- Maps a year onto GitHub's layout: one column per week, one row per weekday,
-- row 1 = Sunday to match os.date("*t").wday. Cells before January 1st and
-- after December 31st are empty.
local M = {}

local function defaultLocaltime(ts) return os.date("*t", ts) end

function M.columns(year, localtime)
    localtime = localtime or defaultLocaltime
    -- Noon avoids DST midnight shifts moving a day into its neighbour.
    local jan1 = os.time{ year = year, month = 1, day = 1, hour = 12 }
    local dec31 = os.time{ year = year, month = 12, day = 31, hour = 12 }
    local first_wday = localtime(jan1).wday          -- 1..7, 1 = Sunday
    local days = math.floor((dec31 - jan1) / 86400) + 1
    local weeks = math.ceil((first_wday - 1 + days) / 7)

    local function dayKey(col, row)
        -- Cell index counted from the Sunday that opens week 1.
        local idx = (col - 1) * 7 + row
        local day_of_year = idx - (first_wday - 1)
        if day_of_year < 1 or day_of_year > days then return nil end
        local d = localtime(jan1 + (day_of_year - 1) * 86400)
        return ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
    end

    return { weeks = weeks, dayKey = dayKey }
end

return M
