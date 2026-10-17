-- A cols x rows grid of filled cells, painted straight into the blitbuffer.
--
-- Follows bookshelf's analogue_clock: a plain table with getSize() and
-- paintTo(bb, x, y). There is no polygon fill in KOReader, and none is
-- needed -- every cell is a rectangle.
--
-- The caller supplies level(col, row) -> 0..4 rather than a data table, so
-- this one widget paints the day heatmap, the hour x weekday clock and the
-- territory map. level() returning nil means "no cell here" and paints
-- nothing: the map needs blank columns between territories that must not read
-- as an unread book.
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
-- MUST extend KOReader's Widget. A bare table with getSize/paintTo looks like
-- it works -- it paints -- but it carries none of the widget protocol, so the
-- first event a container propagates into it (a tap, a refresh, a close) calls
-- a nil handleEvent and the error escapes the UI loop, taking KOReader down to
-- the launcher. Found the hard way on a Kindle; no off-device test can see it,
-- because the suites stub these modules and only ever call getSize().
local Widget = require("ui/widget/widget")

local Grid = nil  -- injected below by the spec files' loader, or dofile'd

local M = {}

-- Luminance per step, light to dark. Five steps is the ceiling for what is
-- reliably distinguishable on e-ink at this cell size; step 0 is a light grey
-- rather than white so a day without reading still reads as a cell.
M.INK = { [0] = 0xE0, [1] = 0xB0, [2] = 0x80, [3] = 0x50, [4] = 0x20 }

-- `grid_mod` lets callers hand in the already-loaded Grid helper. Falls back
-- to a sibling dofile so this file also works standalone in tests.
function M.setGrid(grid_mod) Grid = grid_mod end

local function resolveGrid(opts)
    -- Per-instance resolution: opts.grid takes precedence, then module-level
    -- default (set by setGrid), then sibling dofile fallback.
    if opts.grid then return opts.grid end
    if Grid then return Grid end
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return dofile(dir .. "grid.lua")
end

local GridWidget = Widget:extend{}

-- Height of a label strip set in `face`. A module function as well as a
-- method, so a caller can take the strip out of its height budget BEFORE
-- building the widget -- the territory map has to solve its layout against
-- exactly the grid height the widget will end up with.
function M.labelHeight(face)
    local TextWidget = require("ui/widget/textwidget")
    local probe = TextWidget:new{ text = "M", face = face }
    local h = probe:getSize().h
    probe:free()
    return h + math.max(1, math.floor(h / 4))
end

-- Height the column-label strip occupies, 0 when there are no labels.
-- Deliberately independent of the grid geometry: the strip is measured BEFORE
-- the grid is solved, because it comes out of the same height budget and the
-- grid only gets what is left.
function GridWidget:labelHeight()
    if not (self.col_labels and self.face) then return 0 end
    if not self._label_h then self._label_h = M.labelHeight(self.face) end
    return self._label_h
end

function GridWidget:init()
    -- The label strip is part of what the caller budgeted for, so take it off
    -- the top before solving the grid. Getting this wrong pushes whatever the
    -- caller stacked below the grid off the bottom of the card.
    local label_h = self:labelHeight()
    local grid_h = self.height and math.max(1, self.height - label_h) or nil
    self.geom = self.gridMod.layout{
        width = self.width, height = grid_h,
        cols = self.cols, rows = self.rows,
        gap_ratio = self.gap_ratio,
    }
    self.dimen = Geom:new{ w = self.geom.w, h = self.geom.h + label_h }
end

function GridWidget:getSize()
    return Geom:new{ w = self.geom.w, h = self.geom.h + self:labelHeight() }
end

-- Column labels drawn at the x offset of the column they mark.
--
-- When they do not all fit, drop to a REGULAR subset -- every second label,
-- every third, and so on -- rather than skipping whichever individual ones
-- happen to collide. Irregular gaps read as a bug; "every other month" reads
-- as a choice.
function GridWidget:paintLabels(bb, x, y)
    local TextWidget = require("ui/widget/textwidget")
    local step = self.geom.cell + self.geom.gap
    local n = #self.col_labels

    local widths = {}
    for i = 1, n do
        local tw = TextWidget:new{ text = self.col_labels[i].text, face = self.face }
        widths[i] = tw:getSize().w
        tw:free()
    end
    local pad = math.max(2, math.floor(self:labelHeight() / 3))

    local function fits(stride)
        local prev_end = nil
        for i = 1, n, stride do
            local lx = (self.col_labels[i].col - 1) * step
            if lx + widths[i] > self.geom.w then return false end
            if prev_end and lx < prev_end then return false end
            prev_end = lx + widths[i] + pad
        end
        return true
    end

    local stride = 1
    while stride <= n and not fits(stride) do stride = stride + 1 end
    if stride > n then return end

    for i = 1, n, stride do
        local lb = self.col_labels[i]
        local tw = TextWidget:new{ text = lb.text, face = self.face,
            fgcolor = self.label_color }
        tw:paintTo(bb, x + (lb.col - 1) * step, y)
        tw:free()
    end
end

-- Truncate mode: every label is drawn, each cut with an ellipsis to the
-- `width` the caller gave it. For the territory map, where a skipped label
-- would leave a region with no name -- a missing month can be inferred from
-- its neighbours, a missing language cannot.
function GridWidget:paintTruncatedLabels(bb, x, y)
    local TextWidget = require("ui/widget/textwidget")
    local step = self.geom.cell + self.geom.gap
    for i = 1, #self.col_labels do
        local lb = self.col_labels[i]
        local tw = TextWidget:new{ text = lb.text, face = self.face,
            fgcolor = self.label_color, max_width = lb.width }
        tw:paintTo(bb, x + (lb.col - 1) * step, y)
        tw:free()
    end
end

function GridWidget:paintTo(bb, x, y)
    local g = self.geom
    local lh = self:labelHeight()
    self.dimen = Geom:new{ x = x, y = y, w = g.w, h = g.h + lh }
    if lh > 0 then
        if self.label_mode == "truncate" then
            self:paintTruncatedLabels(bb, x, y)
        else
            self:paintLabels(bb, x, y)
        end
    end
    y = y + lh
    local step = g.cell + g.gap
    for col = 1, self.cols do
        for row = 1, self.rows do
            local lv = self.level(col, row)
            if lv ~= nil then
                bb:paintRect(x + (col - 1) * step, y + (row - 1) * step,
                    g.cell, g.cell, Blitbuffer.Color8(M.INK[lv] or M.INK[0]))
            end
        end
    end
end

function M.new(opts)
    return GridWidget:new{
        cols     = opts.cols,
        rows     = opts.rows,
        level    = opts.level,
        width    = opts.width,
        height   = opts.height,
        gap_ratio = opts.gap_ratio,
        gridMod  = resolveGrid(opts),
        col_labels  = opts.col_labels,
        face        = opts.face,
        label_color = opts.label_color,
        label_mode  = opts.label_mode,
    }
end

return M
