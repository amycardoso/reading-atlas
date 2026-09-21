-- Five steps: 0 (no reading) plus four levels cut at quartiles of the days
-- that DO have reading. Quartiles, not fixed minutes, so a twenty-minute
-- reader and a three-hour reader each see the shape of their own year rather
-- than an empty grid or a saturated one.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Scale = dofile("micromodules/atlas/scale.lua")

t.test("zero is always level 0, whatever the thresholds", function()
    eq(Scale.level(0, { 10, 20, 30 }), 0)
end)

t.test("a value spreads across the four levels", function()
    local th = Scale.thresholds({ 10, 20, 30, 40 })
    eq(Scale.level(10, th), 1)
    eq(Scale.level(40, th), 4)
end)

t.test("levels are monotonic: more time never means a lower level", function()
    local vals = {}
    for i = 1, 100 do vals[i] = i * 7 end
    local th = Scale.thresholds(vals)
    local prev = 0
    for i = 1, 100 do
        local lv = Scale.level(vals[i], th)
        assert(lv >= prev, ("level dropped at %d: %d after %d"):format(i, lv, prev))
        prev = lv
    end
end)

t.test("every level from 1 to 4 is actually used on a wide spread", function()
    local vals = {}
    for i = 1, 100 do vals[i] = i end
    local th = Scale.thresholds(vals)
    local seen = {}
    for i = 1, 100 do seen[Scale.level(vals[i], th)] = true end
    for lv = 1, 4 do
        assert(seen[lv], "level " .. lv .. " was never used")
    end
end)

t.test("all-identical values still land on a single valid level", function()
    local vals = {}
    for i = 1, 10 do vals[i] = 600 end
    local th = Scale.thresholds(vals)
    local lv = Scale.level(600, th)
    assert(lv >= 1 and lv <= 4, "got level " .. tostring(lv))
end)

t.test("a single reading day does not crash and is not level 0", function()
    local th = Scale.thresholds({ 600 })
    assert(Scale.level(600, th) >= 1)
end)

t.test("no values at all yields nil thresholds, and level falls back to 0", function()
    eq(Scale.thresholds({}), nil)
    eq(Scale.level(0, nil), 0)
end)

t.test("a positive value with nil thresholds is level 1, never 0", function()
    -- Guards a real failure mode: if thresholds are missing for any reason,
    -- a day WITH reading must never be painted as a day without.
    eq(Scale.level(600, nil), 1)
end)

t.done()
