-- The one query Reading Atlas makes. Read-only, always.
--
-- Grouping by UTC hour bounds the result at hours-with-reading (a few
-- thousand over years) instead of one row per page read, and serves both the
-- day heatmap and the hour x weekday clock from a single scan. Converting to
-- local time is Lua's job, in aggregate.lua, where it can be tested.
--
-- Session time is attributed to the hour the page was opened in. Rows are
-- per page, so the error is bounded by one page's duration.
local M = {}

local SQL = [[
    SELECT start_time / 3600 AS hour, SUM(duration) AS secs
    FROM page_stat_data
    GROUP BY hour
    ORDER BY hour;
]]

-- Returns an array of { hour = n, secs = n }, or nil when there is no
-- readable statistics database. nil is a real answer here -- the caller turns
-- it into the "no statistics" state -- so failures are swallowed by design.
function M.hourRows()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil end

    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(path, "ro")
        conn:exec("PRAGMA busy_timeout=200;")
        return conn:exec(SQL)
    end)

    if conn then pcall(function() conn:close() end) end

    if not ok then return nil end
    if not result or not result[1] then return {} end

    local out = {}
    for i = 1, #result[1] do
        out[i] = {
            hour = tonumber(result[1][i]),
            secs = tonumber(result[2][i]) or 0,
        }
    end
    return out
end

return M
