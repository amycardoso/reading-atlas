-- Every query Reading Atlas makes against KOReader's statistics.sqlite3.
-- Read-only, always, through withConnection below.
--
-- hourRows (phase 1): grouping by UTC hour bounds the result at hours-with-reading (a few
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

-- Opens statistics.sqlite3 read-only, runs fn(conn) and closes it, always.
-- Returns fn's result, or nil when there is no readable database or anything
-- raises. nil is a real answer here -- callers turn it into the "no
-- statistics" state -- so failures are swallowed by design.
--
-- fn must turn every value into a plain Lua value before it returns: the
-- connection is closed right after (see CARRY-FORWARD.md).
local function withConnection(fn)
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil end

    local conn
    local ok, out = pcall(function()
        conn = SQ3.open(path, "ro")
        conn:exec("PRAGMA busy_timeout=200;")
        return fn(conn)
    end)

    if conn then pcall(function() conn:close() end) end

    if not ok then return nil end
    return out
end

-- Returns an array of { hour = n, secs = n }, or nil when there is no
-- readable statistics database.
function M.hourRows()
    return withConnection(function(conn)
        local result = conn:exec(SQL)
        local out = {}
        if not result or not result[1] then return out end
        for i = 1, #result[1] do
            out[i] = {
                hour = tonumber(result[1][i]),
                secs = tonumber(result[2][i]) or 0,
            }
        end
        return out
    end)
end

-- ── The fingerprint ─────────────────────────────────────────────────────────
-- Books with more than ten minutes of reading, most recently opened first.
-- This query owns the order and the cap; prepare() keeps them as they come.
-- Only books that still have page rows: one whose stats were reset would take
-- a slot of the LIMIT and then be dropped, leaving the card a book short.
-- EXISTS is cheap: page_stat_data's UNIQUE (id_book, page, start_time) gives
-- it an index that starts with id_book.
local FP_BOOKS = [[
    SELECT id, title, pages, last_open
    FROM book
    WHERE total_read_time >= 600
      AND EXISTS (SELECT 1 FROM page_stat_data WHERE id_book = book.id)
    ORDER BY last_open DESC, id
    LIMIT %d;
]]

-- A cheap stamp per book: how many page rows, how much time, the latest start.
-- If none of it moved, nobody read the book since, and the page rows below --
-- the expensive part -- need not be read or analyzed again.
local FP_STAMPS = [[
    SELECT id_book, COUNT(*), SUM(duration), MAX(start_time)
    FROM page_stat_data
    WHERE id_book IN (%s)
    GROUP BY id_book;
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

local function count(result)
    return result and result[1] and #result[1] or 0
end

-- Returns
--   { books = { { id, title, pages, last_open, sig } },
--     rows  = { { id_book, page, total_pages, day, secs, last_seen } } }
-- or nil when there is no readable statistics database. Never writes.
--
-- `known` maps a book id to the sig of an earlier answer; a book whose sig
-- still matches gets no rows -- its earlier analysis stands. sig covers
-- everything prepare() shows from the book table and from its page rows.
--
-- book.title is the first TEXT column Reading Atlas reads from this database;
-- like every value, it is converted before withConnection closes.
function M.fingerprintRows(limit, known)
    known = known or {}
    return withConnection(function(conn)
        local books, ids = {}, {}
        local res = conn:exec(string.format(FP_BOOKS, math.floor(limit or 6)))
        for n = 1, count(res) do
            local id = tonumber(column(res, 1, n))
            if id then
                local title = column(res, 2, n)
                local b = {
                    id = id,
                    title = title ~= nil and tostring(title) or "",
                    pages = tonumber(column(res, 3, n)),
                    last_open = tonumber(column(res, 4, n)),
                }
                books[#books + 1] = b
                ids[#ids + 1] = string.format("%d", id)
            end
        end
        local rows = {}
        if #ids == 0 then return { books = books, rows = rows } end

        local st = conn:exec(string.format(FP_STAMPS, table.concat(ids, ",")))
        local stamps = {}
        for n = 1, count(st) do
            stamps[tonumber(column(st, 1, n))] = string.format("%s:%s:%s",
                tostring(tonumber(column(st, 2, n))), tostring(tonumber(column(st, 3, n))),
                tostring(tonumber(column(st, 4, n))))
        end
        local changed = {}
        for _i, b in ipairs(books) do
            b.sig = string.format("%s|%s|%s|%s", b.title, tostring(b.pages),
                tostring(b.last_open), stamps[b.id] or "")
            if known[b.id] ~= b.sig then changed[#changed + 1] = string.format("%d", b.id) end
        end
        if #changed == 0 then return { books = books, rows = rows } end

        local r = conn:exec(string.format(FP_ROWS, table.concat(changed, ",")))
        for n = 1, count(r) do
            rows[n] = {
                id_book = tonumber(column(r, 1, n)),
                page = tonumber(column(r, 2, n)),
                total_pages = tonumber(column(r, 3, n)),
                day = tonumber(column(r, 4, n)),
                secs = tonumber(column(r, 5, n)) or 0,
                last_seen = tonumber(column(r, 6, n)),
            }
        end
        return { books = books, rows = rows }
    end)
end

return M
