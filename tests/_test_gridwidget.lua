-- Only the size contract is testable off-device: paintTo needs a real
-- blitbuffer. What matters here is that the widget reports the size it will
-- actually paint, because the host lays out around that number.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

-- Stub the two KOReader modules the widget pulls in at load.
package.loaded["ui/geometry"] = {
    new = function(_, o) return o end,
}
package.loaded["ffi/blitbuffer"] = {
    Color8 = function(v) return { v = v } end,
}

local GW = dofile("micromodules/atlas/gridwidget.lua")

t.test("getSize matches the grid extent", function()
    local Grid = dofile("micromodules/atlas/grid.lua")
    local want = Grid.layout{ width = 400, height = 200, cols = 10, rows = 5 }
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local size = w:getSize()
    eq(size.w, want.w)
    eq(size.h, want.h)
end)

t.test("exposes one ink value per step, 0 through 4", function()
    for lv = 0, 4 do
        assert(GW.INK[lv] ~= nil, "no ink for level " .. lv)
    end
end)

t.test("ink darkens monotonically as the level rises", function()
    for lv = 1, 4 do
        assert(GW.INK[lv] < GW.INK[lv - 1],
            ("level %d should be darker than %d"):format(lv, lv - 1))
    end
end)

t.test("step 0 is grey, not white: an unread day stays part of the grid", function()
    assert(GW.INK[0] < 255, "level 0 must not be pure white")
end)

t.done()
