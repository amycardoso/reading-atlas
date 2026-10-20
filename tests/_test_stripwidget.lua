-- The strip widget: size, run-length painting, the unread dots, the re-read
-- bar, and -- as with gridwidget -- that it is a real KOReader Widget. A bare
-- table that paints correctly still crashes KOReader on the first event a
-- container sends it (CARRY-FORWARD.md).
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

package.loaded["ui/geometry"] = { new = function(_, o) return o end }
package.loaded["ffi/blitbuffer"] = { Color8 = function(v) return v end }
local WidgetStub = {}
function WidgetStub:extend(sub) return setmetatable(sub or {}, { __index = self }) end
function WidgetStub:new(o)
    o = setmetatable(o or {}, { __index = self })
    if o.init then o:init() end
    return o
end
function WidgetStub:handleEvent() return false end
function WidgetStub:free() end
function WidgetStub:onCloseWidget() end
package.loaded["ui/widget/widget"] = WidgetStub

local SW = dofile("micromodules/atlas/stripwidget.lua")

local function paint(w)
    local rects = {}
    w:paintTo({ paintRect = function(_, x, y, rw, rh, c)
        rects[#rects + 1] = { x = x, y = y, w = rw, h = rh, c = c }
    end }, 0, 0)
    return rects
end

local function strip(levels, rereads, width)
    return SW.new{ width = width or #levels, strip_h = 10, tick_h = 3, gap = 2,
        min_tick = 3, levels = levels, rereads = rereads or {} }
end

t.test("is a real Widget: event handling and lifecycle are inherited", function()
    local w = strip({ 1 }, nil, 1)
    assert(type(w.handleEvent) == "function", "handleEvent")
    assert(type(w.free) == "function", "free")
    assert(type(w.onCloseWidget) == "function", "onCloseWidget")
    eq(w:handleEvent({}), false)
end)

t.test("paints with the same greys as the grid", function()
    local GW = dofile("micromodules/atlas/gridwidget.lua")
    eq(SW.INK, dofile("micromodules/atlas/ink.lua"))
    assert(rawequal(SW.INK, GW.INK), "one shared table, not two copies")
end)

t.test("getSize is the width by strip + gap + bar", function()
    local s = strip({ 1, 2, 3 }):getSize()
    eq(s.w, 3)
    eq(s.h, 15)
end)

t.test("runs collapse equal neighbours and keep unread apart", function()
    eq(SW.runs({ 1, 1, 2, nil, nil, 0 }, 6), {
        { from = 1, to = 2, level = 1 },
        { from = 3, to = 3, level = 2 },
        { from = 4, to = 5, level = false },
        { from = 6, to = 6, level = 0 },
    })
end)

t.test("read runs paint one full-height rect each, in the step's ink", function()
    local rects = paint(strip({ 4, 4, 4, 1 }))
    eq(#rects, 2)
    eq(rects[1], { x = 0, y = 0, w = 3, h = 10, c = SW.INK[4] })
    eq(rects[2], { x = 3, y = 0, w = 1, h = 10, c = SW.INK[1] })
end)

t.test("step 0 is painted, light, never left blank", function()
    local rects = paint(strip({ 0 }))
    eq(rects[1].c, SW.INK[0])
    eq(rects[1].h, 10)
end)

t.test("unread is a dotted midline, one pixel in three", function()
    local rects = paint(strip({ nil, nil, nil, nil, nil, nil, nil }, nil, 7))
    eq(#rects, 3)
    for _i, r in ipairs(rects) do
        eq(r.h, 1)
        eq(r.w, 1)
        eq(r.y, 5)
        eq(r.c, SW.UNREAD)
    end
    eq(rects[2].x, 3)
end)

t.test("a re-read paints a black bar under the strip", function()
    local rects = paint(strip({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, { { from = 3, to = 7 } }))
    local bar = rects[#rects]
    eq(bar, { x = 2, y = 12, w = 5, h = 3, c = SW.REREAD })
end)

t.test("a one-pixel re-read is widened to stay visible", function()
    local rects = paint(strip({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, { { from = 5, to = 5 } }))
    eq(rects[#rects].w, 3)
end)

t.test("a widened bar at the right edge stays inside the strip", function()
    local rects = paint(strip({ 1, 1, 1, 1, 1 }, { { from = 5, to = 5 } }))
    local bar = rects[#rects]
    eq(bar.x + bar.w, 5)
end)

t.done()
