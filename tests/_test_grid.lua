-- The host re-renders the card at different scales until it fits, so this
-- geometry runs a lot and must never return something unpaintable: a cell
-- below one pixel, or an extent wider than the box it was given.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Grid = dofile("micromodules/atlas/grid.lua")

t.test("fits inside the box it is given", function()
    local g = Grid.layout{ width = 300, height = 100, cols = 53, rows = 7 }
    assert(g.w <= 300, "width overflow: " .. g.w)
    assert(g.h <= 100, "height overflow: " .. g.h)
end)

t.test("cell is at least 1 pixel even in an absurdly small box", function()
    local g = Grid.layout{ width = 10, height = 10, cols = 53, rows = 7 }
    assert(g.cell >= 1, "cell was " .. tostring(g.cell))
end)

t.test("the limiting dimension decides the cell size", function()
    -- Very wide, very short: height must be what constrains a 7-row grid.
    local g = Grid.layout{ width = 10000, height = 70, cols = 53, rows = 7 }
    assert(g.h <= 70, "height overflow: " .. g.h)
    assert(g.cell <= 10, "cell should be limited by height, got " .. g.cell)
end)

t.test("extent matches cell and gap arithmetic exactly", function()
    local g = Grid.layout{ width = 400, height = 200, cols = 10, rows = 5 }
    eq(g.w, g.cell * 10 + g.gap * 9, "width must be cells plus inner gaps")
    eq(g.h, g.cell * 5 + g.gap * 4, "height must be cells plus inner gaps")
end)

t.test("a single column and row is valid", function()
    local g = Grid.layout{ width = 50, height = 50, cols = 1, rows = 1 }
    eq(g.gap, 0, "one cell has no inner gap to draw")
    assert(g.cell >= 1)
end)

t.test("zero or negative box still returns a paintable 1px cell", function()
    local g = Grid.layout{ width = 0, height = 0, cols = 7, rows = 7 }
    assert(g.cell >= 1, "cell was " .. tostring(g.cell))
end)

t.done()
