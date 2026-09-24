-- The territory map's logic, off-device: the grey each status gets, what the
-- card counts, and where every cell and label lands. The painting itself is
-- gridwidget's and is only verifiable on a Kindle.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local T = dofile("micromodules/atlas/territory.lua")
local Grid = dofile("micromodules/atlas/grid.lua")

-- Every glyph is 6 px, like the TextWidget stub in _test_gridwidget.lua.
local function measure(text) return #text * 6 end
local MIN = "abc"         -- 18 px
local OTHERS = "Others"

local function books(n, status, prefix)
    local out = {}
    for i = 1, n do
        out[i] = { path = (prefix or "b") .. i, status = status }
    end
    return out
end

local function territory(name, n, status)
    return { name = name, levels = (function()
        local lv = {}
        for i = 1, n do lv[i] = T.level(status) end
        return lv
    end)() }
end

local function plan(territories, width, height)
    return T.plan{ territories = territories, width = width, height = height,
        measure = measure, min_label = MIN, others_label = OTHERS, grid = Grid }
end

local function countCells(p)
    local n = 0
    for _, col in pairs(p.cells) do
        for _ in pairs(col) do n = n + 1 end
    end
    return n
end

-- ── level ──────────────────────────────────────────────────────────────────

t.test("each bookshelf status gets its own grey", function()
    eq(T.level("finished"), 4)
    eq(T.level("reading"), 2)
    eq(T.level("on_hold"), 1)
    eq(T.level("unread"), 0)
end)

t.test("KOReader's raw vocabulary maps to the same greys", function()
    eq(T.level("complete"), 4, "complete is finished")
    eq(T.level("abandoned"), 1, "abandoned is on hold")
end)

t.test("nil, new and unknown statuses are unread, never darker", function()
    eq(T.level(nil), 0)
    eq(T.level("new"), 0)
    eq(T.level("something-bookshelf-adds-later"), 0)
end)

-- ── prepare ────────────────────────────────────────────────────────────────

t.test("territories run largest first, ties by name", function()
    local p = T.prepare({ territories = {
        { name = "Spanish", books = books(2, "reading", "s") },
        { name = "English", books = books(5, "reading", "e") },
        { name = "French", books = books(2, "reading", "f") },
    } }, "language", "Unknown")
    eq(p.territories[1].name, "English")
    eq(p.territories[2].name, "French", "a tie is broken by name")
    eq(p.territories[3].name, "Spanish")
end)

t.test("inside a territory the books run darkest first", function()
    local p = T.prepare({ territories = {
        { name = "English", books = {
            { path = "a", status = nil },
            { path = "b", status = "finished" },
            { path = "c", status = "on_hold" },
            { path = "d", status = "reading" },
        } },
    } }, "language", "Unknown")
    eq(p.territories[1].levels, { 4, 2, 1, 0 })
end)

t.test("a book in two territories is one book in the counts", function()
    local p = T.prepare({ territories = {
        { name = "Gaiman", books = { { path = "good-omens", status = "finished" } } },
        { name = "Pratchett", books = { { path = "good-omens", status = "finished" },
                                        { path = "mort", status = "reading" } } },
    } }, "author", "No author")
    eq(p.books, 2, "good-omens counts once")
    eq(p.finished, 1)
    eq(p.count, 2, "but it is drawn in both territories")
end)

t.test("unassigned books become their own territory on most axes", function()
    local p = T.prepare({
        territories = { { name = "Fantasy", books = books(1, "finished", "f") } },
        unassigned = books(3, nil, "u"),
    }, "genre", "No genre")
    eq(p.count, 2)
    eq(p.territories[1].name, "No genre", "the largest territory comes first")
    eq(p.books, 4)
    eq(p.excluded, 0)
    eq(p.no_values, false)
end)

t.test("on the series axis unassigned books are left out and counted", function()
    local p = T.prepare({
        territories = { { name = "Discworld", books = books(2, "finished", "d") } },
        unassigned = books(41, nil, "u"),
    }, "series", "ignored")
    eq(p.count, 1, "no 'no series' territory")
    eq(p.books, 2)
    eq(p.excluded, 41)
end)

t.test("books but no values on the axis is its own state", function()
    local p = T.prepare({ territories = {}, unassigned = books(5, nil) },
        "genre", "No genre")
    eq(p.no_values, true)
end)

t.test("an empty library is not the no-values state", function()
    local p = T.prepare({ territories = {}, unassigned = {} }, "genre", "No genre")
    eq(p.books, 0)
    eq(p.no_values, false)
end)

t.test("a territory with no books is dropped", function()
    local p = T.prepare({ territories = {
        { name = "Empty", books = {} },
        { name = "English", books = books(1, "reading") },
    } }, "language", "Unknown")
    eq(p.count, 1)
end)

t.done()
