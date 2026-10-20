-- db.fingerprintRows against a fake lua-ljsqlite3. What this can check
-- off-device: the shape of the result, that every value is read before the
-- connection closes, that failures are nil and never raise, and that the
-- connection is opened read-only and always closed.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

package.loaded["datastorage"] = { getSettingsDir = function() return "/settings" end }

-- A fake connection. Each exec answers by matching the SQL, in the column
-- layout lua-ljsqlite3 uses: result[col][row]. Values are wrapped so that
-- reading them after close() raises, which is how a value still tied to the
-- connection would fail on a device.
local fake
local function newFake(answers)
    local f = { closed = false, opened = nil, sql = {} }
    local function wrap(v)
        if type(v) ~= "string" then return v end
        return setmetatable({}, { __tostring = function()
            if f.closed then error("read after close") end
            return v
        end })
    end
    f.conn = {
        exec = function(_, sql)
            f.sql[#f.sql + 1] = sql
            if f.fail and sql:find(f.fail, 1, true) then error("sqlite error") end
            for pattern, cols in pairs(answers) do
                if sql:find(pattern, 1, true) then
                    local out = {}
                    for c = 1, #cols do
                        out[c] = {}
                        for r = 1, #cols[c] do out[c][r] = wrap(cols[c][r]) end
                    end
                    return out
                end
            end
            return nil
        end,
        close = function() f.closed = true end,
    }
    return f
end
package.loaded["lua-ljsqlite3/init"] = {
    open = function(path, mode)
        fake.opened = { path = path, mode = mode }
        if fake.refuse then error("unable to open") end
        return fake.conn
    end,
}

local DB = dofile("micromodules/atlas/db.lua")

local BOOKS = {
    { 7, 3 },                       -- id
    { "Grande Sertão: Veredas", "Dune" }, -- title (TEXT)
    { 624, 688 },                   -- pages
    { 1700000000, 1690000000 },     -- last_open
}
local ROWS = {
    { 7, 7, 3 },        -- id_book
    { 1, 2, 10 },       -- page
    { 624, 624, 688 },  -- total_pages
    { 19700, 19700, 19650 }, -- day
    { 60, 75, 90 },     -- secs
    { 1, 2, 1 },        -- visits
    { 1702000000, 1702000100, 1698000000 }, -- last_seen
}
local STAMPS = {
    { 7, 3 },                    -- id_book
    { 2, 1 },                    -- COUNT(*)
    { 135, 90 },                 -- SUM(duration)
    { 1702000100, 1698000000 },  -- MAX(start_time)
}
-- db.lua puts the local UTC offset at the end of every sig.
local NOW = os.time()
local OFFSET = string.format("|%d", os.difftime(NOW, os.time(os.date("!*t", NOW))))
local SIG7 = "Grande Sertão: Veredas|624|1700000000|2:135:1702000100" .. OFFSET

t.test("books and rows come back as plain Lua values", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    local got = DB.fingerprintRows(6)
    eq(got.books[1], { id = 7, title = "Grande Sertão: Veredas", pages = 624,
        last_open = 1700000000, sig = SIG7 })
    eq(type(got.books[2].title), "string")
    eq(#got.rows, 3)
    eq(got.rows[3], { id_book = 3, page = 10, total_pages = 688, day = 19650, secs = 90,
        visits = 1, last_seen = 1698000000 })
    eq(got.rows[2].visits, 2)
end)

t.test("the title is read before the connection closes", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    local got = DB.fingerprintRows(6)
    assert(fake.closed, "connection closed")
    -- A wrapper kept past close() would raise here.
    eq(got.books[1].title .. "", "Grande Sertão: Veredas")
end)

t.test("opens read-only, limits the books, and asks only for their rows", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    DB.fingerprintRows(6)
    eq(fake.opened, { path = "/settings/statistics.sqlite3", mode = "ro" })
    local books_sql, rows_sql
    for _i, s in ipairs(fake.sql) do
        if s:find("SELECT id, title", 1, true) then books_sql = s end
        if s:find("SELECT id_book, page", 1, true) then rows_sql = s end
    end
    assert(books_sql:find("LIMIT 6", 1, true), books_sql)
    assert(books_sql:find("total_read_time >= 600", 1, true), books_sql)
    assert(books_sql:find("EXISTS (SELECT 1 FROM page_stat_data WHERE id_book = book.id)", 1, true),
        "a book without page rows must not take a slot: " .. books_sql)
    assert(rows_sql:find("IN (7,3)", 1, true), rows_sql)
    -- Days split at the reader's midnight, not UTC's.
    assert(rows_sql:find("'unixepoch', 'localtime'", 1, true), rows_sql)
    assert(rows_sql:find("strftime('%s'", 1, true), "the %% must survive string.format: " .. rows_sql)
    assert(rows_sql:find("MAX(start_time) AS last_seen", 1, true), rows_sql)
    assert(rows_sql:find("COUNT(*) AS visits", 1, true), rows_sql)
end)

t.test("a known book whose stamp is unchanged gets no page rows", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    DB.fingerprintRows(6, { [7] = SIG7 })
    local rows_sql
    for _i, s in ipairs(fake.sql) do
        if s:find("SELECT id_book, page", 1, true) then rows_sql = s end
    end
    assert(rows_sql:find("IN (3)", 1, true), "only Dune's rows: " .. rows_sql)
end)

t.test("when every book is known and unchanged, the page rows are not read at all", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    local got = DB.fingerprintRows(6, { [7] = SIG7, [3] = "Dune|688|1690000000|1:90:1698000000" .. OFFSET })
    eq(#got.books, 2)
    eq(got.rows, {})
    for _i, s in ipairs(fake.sql) do
        assert(not s:find("SELECT id_book, page", 1, true), "read rows for unchanged books")
    end
end)

t.test("a retitled book is not unchanged", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    local old = "Grande Sertao|624|1700000000|2:135:1702000100" .. OFFSET
    DB.fingerprintRows(6, { [7] = old })
    local asked
    for _i, s in ipairs(fake.sql) do
        if s:find("SELECT id_book, page", 1, true) then asked = s end
    end
    assert(asked and asked:find("7", 1, true), "the title is part of the sig")
end)

t.test("books are ordered by last_open, then id, in SQL", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS, ["SELECT id_book, page"] = ROWS, ["COUNT(*), SUM(duration)"] = STAMPS }
    DB.fingerprintRows(6)
    assert(fake.sql[2]:find("ORDER BY last_open DESC, id", 1, true), fake.sql[2])
end)

-- ── hourRows ───────────────────────────────────────────────────────────────
local HOURS = { { 470000, 470001 }, { 1200, 300 } }
local HSTAMP = { { 9068 }, { 1790723107 } }

t.test("hourRows carries a stamp, and a matching stamp skips the scan", function()
    fake = newFake{ ["COUNT(*), MAX(start_time)"] = HSTAMP, ["start_time / 3600"] = HOURS }
    local got = DB.hourRows()
    eq(#got, 2)
    eq(got[2], { hour = 470001, secs = 300 })
    eq(got.stamp, "9068:1790723107")
    fake = newFake{ ["COUNT(*), MAX(start_time)"] = HSTAMP, ["start_time / 3600"] = HOURS }
    eq(DB.hourRows("9068:1790723107"), { unchanged = true })
    for _i, s in ipairs(fake.sql) do
        assert(not s:find("start_time / 3600", 1, true), "scanned although nothing changed")
    end
end)

t.test("the hourly refresh of the year and clock keeps the same rows when nothing changed", function()
    local scheduled = {}
    package.loaded["ui/uimanager"] = { scheduleIn = function(_, _s, fn) scheduled[#scheduled + 1] = fn end }
    local Source = dofile("micromodules/atlas/source.lua")
    local real_time, clock = os.time, 1000000
    os.time = function(tt) if tt then return real_time(tt) end return clock end
    local ok, err = pcall(function()
        local repaints = 0
        local cb = function() repaints = repaints + 1 end
        fake = newFake{ ["COUNT(*), MAX(start_time)"] = HSTAMP, ["start_time / 3600"] = HOURS }
        Source.get(cb)
        scheduled[1](); scheduled = {}
        local first = Source.get(cb)
        eq(repaints, 1)
        clock = clock + Source.HOURS_MAX_AGE
        fake = newFake{ ["COUNT(*), MAX(start_time)"] = HSTAMP, ["start_time / 3600"] = HOURS }
        Source.get(cb)
        scheduled[1](); scheduled = {}
        assert(rawequal(Source.get(cb), first), "the same rows, not a new copy")
        eq(repaints, 1, "and no repaint")
    end)
    os.time = real_time
    if not ok then error(err, 0) end
end)

t.test("no qualifying book: an empty answer, and no second query", function()
    fake = newFake{}
    local got = DB.fingerprintRows(6)
    eq(got, { books = {}, rows = {} })
    for _i, s in ipairs(fake.sql) do
        assert(not s:find("SELECT id_book, page", 1, true), "queried rows for no books")
    end
end)

t.test("a missing database is nil, not an error", function()
    fake = newFake{}
    fake.refuse = true
    eq(DB.fingerprintRows(6), nil)
end)

t.test("a failing query is nil, and the connection is still closed", function()
    fake = newFake{ ["SELECT id, title"] = BOOKS }
    fake.fail = "SELECT id_book, page"
    eq(DB.fingerprintRows(6), nil)
    assert(fake.closed, "connection closed after a failure")
end)

t.done()
