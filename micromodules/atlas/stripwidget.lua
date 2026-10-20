-- One fingerprint strip: a column of ink per bucket of the book, a dotted
-- line where it has not been read, and a black bar under re-read stretches.
--
-- gridwidget does not fit: it paints square cells with gaps, and a strip is
-- continuous, one pixel column per bucket.
--
-- A real Widget, extended and built with :new{} -- see CARRY-FORWARD.md for
-- the bare table that painted correctly and crashed a Kindle anyway.
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")

local M = {}

-- The same five greys as the grid, from ink.lua next to this file.
M.INK = dofile((debug.getinfo(1, "S").source:match("^@(.+/)") or "./") .. "ink.lua")
M.UNREAD = 0xD8
M.REREAD = 0x00

local StripWidget = Widget:extend{}

-- width        pixels, and the number of buckets in `levels`
-- strip_h      height of the inked strip
-- tick_h       height of the re-read bar
-- gap          space between strip and bar
-- min_tick     narrowest re-read bar, so a short re-read stays visible
-- levels[k]    nil = not read, 0..4 = ink step
-- rereads      { { from, to }, … } in bucket indexes
function StripWidget:init()
    self.gap = self.gap or 2
    self.min_tick = self.min_tick or 3
    self.dimen = Geom:new{ w = self.width, h = self:height() }
end

function StripWidget:height()
    return self.strip_h + self.gap + self.tick_h
end

function StripWidget:getSize()
    return Geom:new{ w = self.width, h = self:height() }
end

-- Runs of equal level, so a strip is a few dozen rects rather than one per
-- pixel column. Returns { { from, to, level }, … }; level is false for unread.
function M.runs(levels, width)
    local out = {}
    local k = 1
    while k <= width do
        local lv = levels[k]
        if lv == nil then lv = false end
        local from = k
        while k + 1 <= width do
            local nxt = levels[k + 1]
            if nxt == nil then nxt = false end
            if nxt ~= lv then break end
            k = k + 1
        end
        out[#out + 1] = { from = from, to = k, level = lv }
        k = k + 1
    end
    return out
end

function StripWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self:height() }
    local sh = self.strip_h
    local mid = y + math.floor(sh / 2)
    for _i, run in ipairs(M.runs(self.levels or {}, self.width)) do
        local px, w = x + run.from - 1, run.to - run.from + 1
        if run.level == false then
            -- Dotted: one pixel in three, so it reads as "the rest of the
            -- book" and never as a thin stretch of reading.
            for dx = 0, w - 1, 3 do
                bb:paintRect(px + dx, mid, 1, 1, Blitbuffer.Color8(M.UNREAD))
            end
        else
            bb:paintRect(px, y, w, sh, Blitbuffer.Color8(M.INK[run.level] or M.INK[0]))
        end
    end
    local ty = y + sh + self.gap
    for _i, iv in ipairs(self.rereads or {}) do
        local w = math.max(self.min_tick, iv.to - iv.from + 1)
        local px = math.min(x + iv.from - 1, x + self.width - w)
        bb:paintRect(px, ty, w, self.tick_h, Blitbuffer.Color8(M.REREAD))
    end
end

function M.new(opts)
    return StripWidget:new(opts)
end

M.StripWidget = StripWidget

return M
