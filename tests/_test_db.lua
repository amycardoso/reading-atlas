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
}

t.test("books and rows come back as plain Lua values", function()
    fake = newFake{ ["FROM book"] = BOOKS, ["FROM page_stat_data"] = ROWS }
    local got = DB.fingerprintRows(6)
    eq(got.books[1], { id = 7, title = "Grande Sertão: Veredas", pages = 624, last_open = 1700000000 })
    eq(type(got.books[2].title), "string")
    eq(#got.rows, 3)
    eq(got.rows[3], { id_book = 3, page = 10, total_pages = 688, day = 19650, secs = 90 })
end)

t.test("the title is read before the connection closes", function()
    fake = newFake{ ["FROM book"] = BOOKS, ["FROM page_stat_data"] = ROWS }
    local got = DB.fingerprintRows(6)
    assert(fake.closed, "connection closed")
    -- A wrapper kept past close() would raise here.
    eq(got.books[1].title .. "", "Grande Sertão: Veredas")
end)

t.test("opens read-only, limits the books, and asks only for their rows", function()
    fake = newFake{ ["FROM book"] = BOOKS, ["FROM page_stat_data"] = ROWS }
    DB.fingerprintRows(6)
    eq(fake.opened, { path = "/settings/statistics.sqlite3", mode = "ro" })
    local books_sql, rows_sql
    for _i, s in ipairs(fake.sql) do
        if s:find("FROM book", 1, true) then books_sql = s end
        if s:find("FROM page_stat_data", 1, true) then rows_sql = s end
    end
    assert(books_sql:find("LIMIT 6", 1, true), books_sql)
    assert(books_sql:find("total_read_time >= 600", 1, true), books_sql)
    assert(rows_sql:find("IN (7,3)", 1, true), rows_sql)
end)

t.test("no qualifying book: an empty answer, and no second query", function()
    fake = newFake{}
    local got = DB.fingerprintRows(6)
    eq(got, { books = {}, rows = {} })
    for _i, s in ipairs(fake.sql) do
        assert(not s:find("page_stat_data", 1, true), "queried rows for no books")
    end
end)

t.test("a missing database is nil, not an error", function()
    fake = newFake{}
    fake.refuse = true
    eq(DB.fingerprintRows(6), nil)
end)

t.test("a failing query is nil, and the connection is still closed", function()
    fake = newFake{ ["FROM book"] = BOOKS }
    fake.fail = "page_stat_data"
    eq(DB.fingerprintRows(6), nil)
    assert(fake.closed, "connection closed after a failure")
end)

t.done()
