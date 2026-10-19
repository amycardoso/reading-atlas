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

-- ── The fingerprint ─────────────────────────────────────────────────────────
-- Books with more than ten minutes of reading, most recently opened first.
local FP_BOOKS = [[
    SELECT id, title, pages, last_open
    FROM book
    WHERE total_read_time >= 600
    ORDER BY last_open DESC
    LIMIT %d;
]]

-- Their pages, summed per page, layout and day. A day is all the re-read rule
-- needs, and it keeps a long book to a few thousand rows.
--
-- The day is the reader's LOCAL day: strftime('%s', …, 'localtime') is the
-- local wall-clock time counted as if it were UTC, so dividing it by 86400
-- splits at local midnight. A plain start_time / 86400 would split a
-- Brazilian evening at 21:00. last_seen breaks ties between two layouts read
-- on the same day (a font change today).
local FP_ROWS = [[
    SELECT id_book, page, total_pages,
           CAST(strftime('%%s', start_time, 'unixepoch', 'localtime') AS INTEGER) / 86400 AS day,
           SUM(duration) AS secs, MAX(start_time) AS last_seen
    FROM page_stat_data
    WHERE id_book IN (%s)
    GROUP BY id_book, page, total_pages, day;
]]

local function column(result, i, n)
    local col = result and result[i]
    return col and col[n]
end

-- Returns { books = { { id, title, pages, last_open } }, rows = { { id_book,
-- page, total_pages, day, secs } } }, or nil when there is no readable
-- statistics database. Never writes.
--
-- book.title is the first TEXT column Reading Atlas reads from this database.
-- Every value is turned into a plain Lua value INSIDE the pcall, before
-- conn:close() -- see CARRY-FORWARD.md.
function M.fingerprintRows(limit)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil end

    local conn
    local ok, out = pcall(function()
        conn = SQ3.open(path, "ro")
        conn:exec("PRAGMA busy_timeout=200;")
        local books, ids = {}, {}
        local res = conn:exec(string.format(FP_BOOKS, math.floor(limit or 6)))
        for n = 1, (res and res[1] and #res[1] or 0) do
            local id = tonumber(column(res, 1, n))
            if id then
                local title = column(res, 2, n)
                books[#books + 1] = {
                    id = id,
                    title = title ~= nil and tostring(title) or "",
                    pages = tonumber(column(res, 3, n)),
                    last_open = tonumber(column(res, 4, n)),
                }
                ids[#ids + 1] = string.format("%d", id)
            end
        end
        local rows = {}
        if #ids > 0 then
            local r = conn:exec(string.format(FP_ROWS, table.concat(ids, ",")))
            for n = 1, (r and r[1] and #r[1] or 0) do
                rows[n] = {
                    id_book = tonumber(column(r, 1, n)),
                    page = tonumber(column(r, 2, n)),
                    total_pages = tonumber(column(r, 3, n)),
                    day = tonumber(column(r, 4, n)),
                    secs = tonumber(column(r, 5, n)) or 0,
                    last_seen = tonumber(column(r, 6, n)),
                }
            end
        end
        return { books = books, rows = rows }
    end)

    if conn then pcall(function() conn:close() end) end

    if not ok then return nil end
    return out
end

return M
