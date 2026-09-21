-- Two things are testable off-device: the size contract, and that the object
-- is a real KOReader Widget.
--
-- The second one is here because its absence crashed a Kindle. The widget was
-- once a bare table with getSize/paintTo. It painted correctly -- every test
-- and every review passed -- and then the first event a container propagated
-- into it called a nil handleEvent, the error escaped the UI loop, and
-- KOReader died to the launcher. Painting correctly is not the same as being
-- a widget.
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
-- Mimics KOReader's Widget closely enough to matter: extend/new with
-- inheritance, init called on construction, and the protocol methods a
-- container will reach for.
local WidgetStub = {}
function WidgetStub:extend(subclass)
    subclass = subclass or {}
    setmetatable(subclass, { __index = self })
    return subclass
end
function WidgetStub:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
function WidgetStub:handleEvent() return false end
function WidgetStub:free() end
function WidgetStub:onCloseWidget() end
package.loaded["ui/widget/widget"] = WidgetStub

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

t.test("per-instance grid injection via opts.grid", function()
    local fakeGrid = {
        layout = function()
            return { cell = 10, gap = 2, w = 123, h = 45 }
        end
    }
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end,
                      grid = fakeGrid }
    local size = w:getSize()
    eq(size.w, 123)
    eq(size.h, 45)
end)

t.test("isolation: widget unaffected by setGrid after creation", function()
    local fakeGrid1 = {
        layout = function()
            return { cell = 10, gap = 2, w = 100, h = 50 }
        end
    }
    local fakeGrid2 = {
        layout = function()
            return { cell = 5, gap = 1, w = 200, h = 100 }
        end
    }
    GW.setGrid(fakeGrid1)
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local size1 = w:getSize()
    eq(size1.w, 100)
    eq(size1.h, 50)

    GW.setGrid(fakeGrid2)
    local size2 = w:getSize()
    eq(size2.w, 100)
    eq(size2.h, 50)
end)

t.test("the returned object IS a Widget, not a bare table", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    -- These are inherited, never defined in gridwidget.lua. If someone goes
    -- back to returning a plain table, every one of them becomes nil and this
    -- test fails instead of the user's e-reader.
    for _, method in ipairs({ "handleEvent", "free", "onCloseWidget" }) do
        assert(type(w[method]) == "function",
            "widget is missing " .. method .. " -- is it still Widget:extend?")
    end
end)

t.test("a propagated event does not raise", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local ok, err = pcall(function() return w:handleEvent({ handler = "onTap" }) end)
    assert(ok, "handleEvent raised: " .. tostring(err))
end)

t.done()
