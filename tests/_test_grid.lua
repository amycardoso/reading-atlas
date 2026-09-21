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

t.test("extent never overflows the width across the realistic range", function()
    -- Sweep widths 100..1200 with the year heatmap's shape (cols=53)
    for width = 100, 1200 do
        for _, rows in ipairs({1, 7}) do
            local g = Grid.layout{ width = width, height = 1000, cols = 53, rows = rows }
            if g.cell > 1 then
                assert(g.w <= width, ("overflow at w=%d rows=%d: cell=%d gap=%d extent=%d"):format(
                    width, rows, g.cell, g.gap, g.w))
            end
        end
    end
end)

t.test("extent never overflows the height across the realistic range", function()
    -- Sweep heights 50..500 with the year heatmap's shape (rows=7)
    for height = 50, 500 do
        for _, cols in ipairs({1, 53}) do
            local g = Grid.layout{ width = 1000, height = height, cols = cols, rows = 7 }
            if g.cell > 1 then
                assert(g.h <= height, ("overflow at h=%d cols=%d: cell=%d gap=%d extent=%d"):format(
                    height, cols, g.cell, g.gap, g.h))
            end
        end
    end
end)

t.test("a paintable cell always gets visible separation, even in a narrow band", function()
    -- The year heatmap's shape (53x7) at its shipped fallback height
    -- (height = width / 7). Below ~211px the old bump-to-1 logic never
    -- triggered, so cell >= 2 could still ship with gap == 0: a smear of
    -- touching squares on a panel with no antialiasing.
    for width = 160, 600 do
        local height = math.floor(width / 7)
        local g = Grid.layout{ width = width, height = height, cols = 53, rows = 7 }
        if g.cell >= 2 then
            assert(g.gap >= 1, ("width=%d height=%d: cell=%d but gap=%d"):format(
                width, height, g.cell, g.gap))
        end
        assert(g.w <= width, ("overflow at width=%d: w=%d"):format(width, g.w))
        assert(g.h <= height, ("overflow at width=%d: h=%d"):format(width, g.h))
    end
end)

t.test("non-default gap_ratio is actually used", function()
    local g1 = Grid.layout{ width = 200, height = 200, cols = 5, rows = 5, gap_ratio = 0.1 }
    local g2 = Grid.layout{ width = 200, height = 200, cols = 5, rows = 5, gap_ratio = 0.5 }
    -- With larger gap_ratio, gap should be larger (all else equal)
    assert(g2.gap > g1.gap, ("gap_ratio not used: 0.1 gap=%d, 0.5 gap=%d"):format(g1.gap, g2.gap))
end)

t.done()
