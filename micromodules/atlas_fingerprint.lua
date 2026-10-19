-- Reading Atlas: the book's fingerprint. One strip per recent book, one
-- column per stretch of it, darker where you spent longer per page; a bar
-- under what you went back to re-read; a note naming where you lingered.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local HEADING = _("Atlas fingerprint")

local function fetch(refresh)
    return atlas("source").getKeyed("fingerprint", refresh, {
        query = function() return atlas("db").fingerprintRows(atlas("fingerprint").MAX_BOOKS) end,
        -- No books is data (read a little more), not "no database" (nil).
        accept = function(result) return result ~= nil end,
    })
end

-- prepare() once per query result; layout() once per strip width. The host
-- renders the same card at several scales while fitting it, and the layout
-- walks every row of every book.
local _prep_memo = setmetatable({}, { __mode = "k" })
local _layout_memo = setmetatable({}, { __mode = "k" })

local function prepared(data, now)
    local hit = _prep_memo[data]
    if hit then return hit end
    hit = atlas("fingerprint").prepare(data, now)
    _prep_memo[data] = hit
    return hit
end

local function laidOut(prep, n)
    local by_n = _layout_memo[prep]
    if not by_n then by_n = {}; _layout_memo[prep] = by_n end
    if not by_n[n] then by_n[n] = atlas("fingerprint").layout(prep, n, atlas("scale")) end
    return by_n[n]
end

local function hours(secs)
    if secs >= 3600 then return string.format("%.1f h", secs / 3600) end
    return string.format("%d min", math.floor(secs / 60 + 0.5))
end

-- Right-hand side of the title line.
local function meta(b)
    if b.status == "finished" then
        return string.format("%s · %d p.", hours(b.secs), b.pages)
    end
    return string.format("%s · %d%%", hours(b.secs), math.floor(b.progress * 100))
end

-- The line under the strip.
local function note(strip)
    local b = strip.book
    local parts = {}
    local s = strip.slowest
    if s then
        parts[#parts + 1] = string.format(_("lingered on p. %d–%d (%d min)"),
            s.from, s.to, math.floor(s.secs / 60 + 0.5))
    end
    local rr = strip.reread_pages
    if rr then
        parts[#parts + 1] = string.format(_("re-read p. %d–%d"), rr.from, rr.to)
    end
    if b.status == "reading" then
        parts[#parts + 1] = _("reading")
    elseif b.status == "paused" then
        parts[#parts + 1] = string.format(_("paused since %s"), os.date("%b", b.last_open))
    end
    return table.concat(parts, " · ")
end

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh

    -- The Add picker previews every module cold; it must never be what starts
    -- the query. peek() answers from the cache and schedules nothing.
    local data
    if ctx.preview then
        data = atlas("source").peek("fingerprint")
    else
        data = fetch(refresh)
    end
    if data == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = HEADING, value = _("Reading…") }
    end
    if data == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = HEADING, value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local prep = prepared(data, os.time())
    if #prep.books == 0 then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = HEADING, value = _("Not enough reading yet"),
            sub = _("Read a little more and your books will show up here.") }
    end

    local TextWidget     = require("ui/widget/textwidget")
    local VerticalGroup  = require("ui/widget/verticalgroup")
    local VerticalSpan   = require("ui/widget/verticalspan")
    local OverlapGroup   = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local Geom           = require("ui/geometry")
    local sc = Kit.sc(scale_pct)
    local hface, hbold = Kit.face(15, scale_pct, { bold = true })
    local tface, tbold = Kit.face(13, scale_pct, { bold = true })
    local sface = Kit.face(11, scale_pct)

    local heading = TextWidget:new{ text = HEADING, face = hface, bold = hbold,
        fgcolor = Kit.COLOR_MUTED, max_width = width }
    local legend = TextWidget:new{ text = _("darker = longer per page · bar below = re-read"),
        face = sface, fgcolor = Kit.COLOR_MUTED, max_width = width }

    local strip_h, tick_h, gap = sc(20), math.max(2, sc(4)), math.max(1, sc(2))
    local min_tick = math.max(3, sc(3))
    -- Every book takes the same height, so how many fit is one division.
    local probe = TextWidget:new{ text = "Mg", face = tface, bold = tbold }
    local sprobe = TextWidget:new{ text = "Mg", face = sface }
    local block_h = probe:getSize().h + sc(2) + strip_h + gap + tick_h
        + sprobe:getSize().h + sc(7)
    probe:free(); sprobe:free()
    local chrome = heading:getSize().h + sc(6) + legend:getSize().h
    local fit = ctx.height and math.floor((ctx.height - chrome) / block_h) or 4
    fit = math.max(1, math.min(fit, #prep.books))

    local strips = laidOut(prep, width)
    local SW = atlas("stripwidget")

    local vg = VerticalGroup:new{ align = "left", heading, VerticalSpan:new{ width = sc(6) } }
    for i = 1, fit do
        local s = strips[i]
        local b = s.book
        local right = TextWidget:new{ text = meta(b), face = sface, fgcolor = Kit.COLOR_MUTED }
        local title = TextWidget:new{ text = b.title, face = tface, bold = tbold,
            fgcolor = Kit.COLOR_PRIMARY,
            max_width = math.max(sc(20), width - right:getSize().w - sc(8)) }
        local line_h = math.max(title:getSize().h, right:getSize().h)
        local dimen = Geom:new{ w = width, h = line_h }
        vg[#vg + 1] = OverlapGroup:new{ dimen = dimen, title,
            RightContainer:new{ dimen = Geom:new{ w = width, h = line_h }, right } }
        vg[#vg + 1] = VerticalSpan:new{ width = sc(2) }
        vg[#vg + 1] = SW.new{ width = width, strip_h = strip_h, tick_h = tick_h,
            gap = gap, min_tick = min_tick, levels = s.levels, rereads = s.rereads }
        vg[#vg + 1] = TextWidget:new{ text = note(s), face = sface,
            fgcolor = Kit.COLOR_MUTED, max_width = width }
        vg[#vg + 1] = VerticalSpan:new{ width = sc(7) }
    end
    vg[#vg + 1] = legend
    return vg
end

return {
    key     = "atlas_fingerprint", -- stored in users' menus; never change it
    title   = _("Atlas fingerprint"),
    summary = _("How you read each recent book, page by page. Works offline."),
    render  = render,
}
