-- Reading Atlas: the book's fingerprint. One strip per recent book, one
-- column per stretch of it, darker where you spent longer per page; a bar
-- under what you went back to re-read; a note naming where you lingered.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local HEADING = _("Atlas fingerprint")

-- Re-read the database at most hourly. Without it, a KOReader left up for
-- weeks of suspend and resume would keep the first answer: last_open frozen,
-- so a book read every day would drift to "paused", with weeks-old progress.
local MAX_AGE = 3600

-- The query reads the database AND analyzes every book, so the heavy part runs
-- in the deferred callback, never on the paint path (source.lua, rule 1).
local function fetch(refresh)
    return atlas("source").getKeyed("fingerprint", refresh, {
        query = function()
            local F = atlas("fingerprint")
            -- The previous answer's sigs let the database skip the page rows
            -- of every book nobody read since, and prepare() reuse their
            -- analysis; with nothing new at all, the old answer comes back
            -- as is, and source.lua does not repaint the card.
            local old = atlas("source").peek("fingerprint")
            if type(old) ~= "table" then old = nil end
            local known = {}
            for _i, b in ipairs(old and old.books or {}) do known[b.id] = b.sig end
            local data = atlas("db").fingerprintRows(F.MAX_BOOKS, known)
            if data == nil then return nil end
            local prep = F.prepare(data, old)
            -- The status reads the clock: a book can turn "paused" with no
            -- new data at all. Then the same books come back in a new table,
            -- so source.lua repaints the card.
            local now = os.time()
            local statuses = {}
            for i, b in ipairs(prep.books) do
                statuses[i] = F.status(b.progress, b.last_open, now)
            end
            local key = table.concat(statuses, ",")
            if rawequal(prep, old) and old.statuses ~= key then
                prep = { books = old.books }
            end
            prep.statuses = key
            return prep
        end,
        -- No books is data (read a little more), not "no database" (nil).
        accept = function(result) return result ~= nil end,
        max_age = MAX_AGE,
    })
end

-- layout() once per prepared result, strip width and book count: the host
-- renders the same card at several scales while fitting it. Nothing here reads
-- the clock; the status does, so it is asked for at render time.
local _layout_memo = setmetatable({}, { __mode = "k" })

local function laidOut(prep, n, count)
    local memo = _layout_memo[prep]
    if not memo then memo = {}; _layout_memo[prep] = memo end
    local key = n .. ":" .. count
    if not memo[key] then
        memo[key] = atlas("fingerprint").layout(prep, n, atlas("scale"), count)
    end
    return memo[key]
end

-- Month names through gettext, not os.date("%b"): KOReader leaves LC_TIME in
-- the C locale, so os.date would answer in English whatever the UI language.
local MONTHS = { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }

-- "Mar" within the current year, "Mar 2025" before it: a book paused for
-- more than a year must not read as paused this spring.
local function since(t, now)
    local d = os.date("*t", t)
    if d.year == os.date("*t", now).year then return MONTHS[d.month] end
    return string.format("%s %d", MONTHS[d.month], d.year)
end

-- "45 min", "3 h 05 min": whole units through gettext, so the card needs no
-- decimal separator, which KOReader's C locale would print as "." anywhere.
local function hours(secs)
    local mins = math.floor(secs / 60 + 0.5)
    if mins < 60 then return string.format(_("%d min"), mins) end
    return string.format(_("%d h %02d min"), math.floor(mins / 60), mins % 60)
end

local function statusOf(b, now)
    return atlas("fingerprint").status(b.progress, b.last_open, now)
end

-- Right-hand side of the title line.
local function meta(b, now)
    if statusOf(b, now) == "finished" then
        return hours(b.secs) .. " · " .. string.format(_("%d p."), b.pages)
    end
    -- progress is best/pages in binary floating point: 29/100 * 100 is
    -- 28.999…, so a hair is added before flooring or the card says 28%.
    return hours(b.secs) .. " · " .. string.format(_("%d%%"), math.floor(b.progress * 100 + 1e-6))
end

-- "p. 12" or "p. 12–15": never "p. 12–12".
local function pageRange(from, to)
    if from == to then return string.format(_("p. %d"), from) end
    return string.format(_("p. %d–%d"), from, to)
end

-- The line under the strip.
local function note(strip, now)
    local b = strip.book
    local parts = {}
    local s = strip.slowest
    -- "lingered … (0 min)" claims nothing: a book only skimmed has no stretch
    -- worth naming.
    if s and math.floor(s.secs / 60 + 0.5) >= 1 then
        parts[#parts + 1] = string.format(_("lingered on %s (%d min)"),
            pageRange(s.from, s.to), math.floor(s.secs / 60 + 0.5))
    end
    local rr = strip.reread_pages
    if rr then
        parts[#parts + 1] = string.format(_("re-read %s"), pageRange(rr.from, rr.to))
    end
    local status = statusOf(b, now)
    if status == "reading" then
        parts[#parts + 1] = _("reading")
    elseif status == "paused" then
        parts[#parts + 1] = string.format(_("paused since %s"), since(b.last_open, now))
    end
    return table.concat(parts, " · ")
end

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh

    -- The Add picker previews every module cold; it must never be what starts
    -- the query. peek() answers from the cache and schedules nothing.
    local prep
    if ctx.preview then
        prep = atlas("source").peek("fingerprint")
    else
        prep = fetch(refresh)
    end
    if prep == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = HEADING, value = _("Reading…") }
    end
    if prep == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = HEADING, value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local now = os.time()
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
    -- Not even one book with the legend: the legend goes first. Below that the
    -- card is one book and the heading, and the host shrinks the scale until
    -- it fits (it owns size; see CARRY-FORWARD.md).
    local show_legend = true
    if fit < 1 then
        show_legend = false
        legend:free()
    end
    fit = math.max(1, math.min(fit, #prep.books))

    local strips = laidOut(prep, width, fit)
    local SW = atlas("stripwidget")

    local vg = VerticalGroup:new{ align = "left", heading, VerticalSpan:new{ width = sc(6) } }
    for i = 1, fit do
        local s = strips[i]
        local b = s.book
        local right = TextWidget:new{ text = meta(b, now), face = sface, fgcolor = Kit.COLOR_MUTED }
        local title = TextWidget:new{ text = b.title, face = tface, bold = tbold,
            fgcolor = Kit.COLOR_PRIMARY,
            max_width = math.max(sc(20), width - right:getSize().w - sc(8)) }
        local line_h = math.max(title:getSize().h, right:getSize().h)
        local dimen = Geom:new{ w = width, h = line_h }
        vg[#vg + 1] = OverlapGroup:new{ dimen = dimen, title,
            RightContainer:new{ dimen = Geom:new{ w = width, h = line_h }, right } }
        vg[#vg + 1] = VerticalSpan:new{ width = sc(2) }
        vg[#vg + 1] = SW.new{ width = width, strip_h = strip_h, tick_h = tick_h,
            gap = gap, min_tick = min_tick, levels = s.levels, rereads = s.rereads,
            ink = atlas("ink") }
        vg[#vg + 1] = TextWidget:new{ text = note(s, now), face = sface,
            fgcolor = Kit.COLOR_MUTED, max_width = width }
        vg[#vg + 1] = VerticalSpan:new{ width = sc(7) }
    end
    if show_legend then vg[#vg + 1] = legend end
    return vg
end

return {
    key     = "atlas_fingerprint", -- stored in users' menus; never change it
    title   = _("Atlas fingerprint"),
    summary = _("How you read each recent book, page by page. Works offline."),
    render  = render,
}
