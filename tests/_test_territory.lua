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
    eq(p.count, 1, "the pseudo-territory built from unassigned books is not counted")
    eq(p.territories[1].name, "No genre", "the largest territory comes first")
    eq(p.books, 4)
    eq(p.excluded, 0)
    eq(p.no_values, false)
end)

t.test("count is the real territories only, not the unassigned pseudo-territory", function()
    -- "12 authors" would be wrong if one of those twelve were "No author".
    local p = T.prepare({
        territories = {
            { name = "Gaiman", books = books(2, "finished", "g") },
            { name = "Pratchett", books = books(3, "reading", "p") },
        },
        unassigned = books(5, nil, "u"),
    }, "author", "No author")
    eq(p.count, 2, "only Gaiman and Pratchett are real territories")
    eq(#p.territories, 3, "the map still draws No author as a block")
end)

t.test("unassigned books merge into a real territory sharing its name", function()
    -- Bookshelf already names its unknown-language group "Unknown"; books
    -- that escape even that grouping come back as `unassigned`, and prepare
    -- must not draw a second "Unknown" territory for them.
    local p = T.prepare({
        territories = { { name = "Unknown", books = books(2, "reading", "k") } },
        unassigned = books(3, nil, "u"),
    }, "language", "Unknown")
    local names = {}
    for _, t in ipairs(p.territories) do names[#names + 1] = t.name end
    eq(names, { "Unknown" }, "one Unknown territory, not two")
    eq(#p.territories[1].levels, 5, "the merged books are drawn there too")
    eq(p.books, 5)
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

-- ── plan ───────────────────────────────────────────────────────────────────

t.test("the row count giving the largest cell wins", function()
    -- Four books in 100x100. One row: 4 columns, cell 22. Two rows: 2x2,
    -- cell 45. Three rows: 2 columns, 3 rows, cell 29. Four rows: cell 22.
    local p = plan({ territory("English", 4, "reading") }, 100, 100)
    eq(p.rows, 2)
    eq(p.cols, 2)
    eq(p.geom.cell, 45)
end)

t.test("books fill each column top to bottom, darkest first", function()
    local p = plan({ { name = "English", levels = { 4, 2, 1, 0 } } }, 100, 100)
    eq(p.cells[1][1], 4)
    eq(p.cells[1][2], 2)
    eq(p.cells[2][1], 1)
    eq(p.cells[2][2], 0)
end)

t.test("a blank column separates two territories", function()
    local p = plan({ territory("English", 4, "finished"),
                     territory("French", 4, "reading") }, 400, 100)
    local span = math.ceil(4 / p.rows)
    eq(p.cells[span + 1], nil, "the border column must be blank")
    eq(p.cells[span + 2][1], 2, "the second territory starts after it")
    eq(p.labels[2].col, span + 2)
end)

t.test("the end of a territory's last column stays blank", function()
    -- Three books in two rows: the last column holds one book and one blank.
    local p = T.plan{ territories = { territory("English", 3, "finished") },
        width = 60, height = 60, measure = measure, min_label = MIN,
        others_label = OTHERS, grid = Grid }
    eq(p.rows, 2)
    eq(p.cells[2][1], 4)
    eq(p.cells[2][2], nil, "no book there, so no cell")
end)

t.test("every book is drawn exactly once", function()
    local ts = {}
    for i = 1, 12 do ts[i] = territory("T" .. i, 25 - i, "reading") end
    local total = 0
    for i = 1, 12 do total = total + (25 - i) end
    local p = plan(ts, 500, 120)
    eq(countCells(p), total)
end)

t.test("a territory too narrow to name is folded into Others", function()
    -- One big territory and thirty single books in a narrow card: the singles
    -- cannot each hold "abc", so most of them must fold.
    local ts = { territory("Big", 40, "finished") }
    for i = 1, 30 do ts[#ts + 1] = territory(("S%02d"):format(i), 1, "reading") end
    local p = plan(ts, 200, 60)
    assert(p.shown < #ts, "expected folding, showed all " .. p.shown)
    assert(p.shown >= 1, "the big territory must survive")
    eq(p.labels[1].text, "Big")
    eq(countCells(p), 70, "folded books are still drawn, inside Others")
end)

t.test("every territory shown keeps a label at least min_label wide", function()
    local minw = measure(MIN)
    for width = 80, 600, 7 do
        local ts = {}
        for i = 1, 20 do ts[i] = territory("T" .. i, 21 - i, "reading") end
        local p = plan(ts, width, 90)
        local named = 0
        for _, lb in ipairs(p.labels) do
            if lb.text ~= OTHERS then
                named = named + 1
                assert(lb.width >= minw, ("width %d: label %s has %d px"):format(
                    width, lb.text, lb.width))
            end
        end
        eq(named, p.shown, "width " .. width .. ": every shown territory is named")
    end
end)

t.test("labels never run into the next territory", function()
    for width = 80, 600, 7 do
        local ts = {}
        for i = 1, 20 do ts[i] = territory("T" .. i, 21 - i, "reading") end
        local p = plan(ts, width, 90)
        local step = p.geom.cell + p.geom.gap
        for i = 2, #p.labels do
            local prev = p.labels[i - 1]
            local prev_end = (prev.col - 1) * step + prev.width
            local this_x = (p.labels[i].col - 1) * step
            assert(prev_end < this_x, ("width %d: label %d ends at %d, next starts at %d")
                :format(width, i - 1, prev_end, this_x))
        end
    end
end)

t.test("the grid never overflows its box across a realistic range", function()
    for width = 100, 700, 13 do
        for _, height in ipairs({ 40, 90, 160 }) do
            local ts = {}
            for i = 1, 8 do ts[i] = territory("T" .. i, 40 - 4 * i, "reading") end
            local p = plan(ts, width, height)
            assert(p.geom.w <= width, ("%dx%d: width %d"):format(width, height, p.geom.w))
            assert(p.geom.h <= height, ("%dx%d: height %d"):format(width, height, p.geom.h))
        end
    end
end)

t.test("no cell lands outside the planned columns and rows", function()
    local ts = {}
    for i = 1, 6 do ts[i] = territory("T" .. i, 7 * i, "reading") end
    local p = plan(ts, 300, 80)
    for col, rows in pairs(p.cells) do
        assert(col >= 1 and col <= p.cols, "column " .. col .. " out of range")
        for row in pairs(rows) do
            assert(row >= 1 and row <= p.rows, "row " .. row .. " out of range")
        end
    end
end)

t.test("a single territory in a card too small to name it still draws", function()
    local p = plan({ territory("Portuguese", 10, "finished") }, 10, 10)
    eq(countCells(p), 10, "every book still has a cell")
end)

t.test("three hundred books in sixty small territories still all draw, inside the box", function()
    -- No territory here is wide enough to name in 260 px, so the honest
    -- answer is one "Others" block -- but every book must still have a cell.
    local ts, total = {}, 0
    for i = 1, 60 do
        ts[i] = territory("A" .. i, (i % 9) + 1, "reading")
        total = total + (i % 9) + 1
    end
    local p = plan(ts, 260, 70)
    eq(countCells(p), total)
    assert(p.geom.w <= 260 and p.geom.h <= 70, "the grid must stay inside the card")
end)

t.test("the search names as many territories as brute force would", function()
    -- plan() binary-searches the number of named territories, which assumes
    -- that folding one more territory never makes naming the rest harder.
    -- Check that assumption against trying every count, on random libraries.
    local minw = measure(MIN)
    math.randomseed(7)
    for _ = 1, 300 do
        local ts = {}
        for i = 1, math.random(1, 40) do
            local lv = {}
            for j = 1, math.random(1, 30) do lv[j] = math.random(0, 4) end
            ts[i] = { name = "T" .. i, levels = lv }
        end
        table.sort(ts, function(a, b) return #a.levels > #b.levels end)
        local o = { territories = ts, width = math.random(80, 700),
            height = math.random(30, 200), measure = measure, min_label = MIN,
            others_label = OTHERS, grid = Grid }
        local brute = 0
        for keep = 0, #ts do
            if T._solve(o, keep, minw) then brute = keep end
        end
        eq(T.plan(o).shown, brute, ("%d territories in %dx%d"):format(#ts, o.width, o.height))
    end
end)

t.done()
