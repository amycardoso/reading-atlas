-- Reading Atlas: a year of reading as a grid of days.
--
-- Drop this file, atlas_clock.lua and the atlas/ directory into
-- <koreader settings>/bookshelf/micromodules/ .
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local rows = atlas("source").get(refresh)

    if rows == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Atlas year"), value = _("Reading…") }
    end
    if rows == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Atlas year"), value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local year = tonumber(os.date("%Y"))
    local by_day = atlas("aggregate").byDay(rows)
    local cal = atlas("calendar").columns(year)
    local Scale = atlas("scale")

    -- Thresholds come from the days this card will actually draw. Computing
    -- them over all history makes a light year read as a flat wash next to a
    -- heavy one.
    local values, total, days = {}, 0, 0
    for col = 1, cal.weeks do
        for row = 1, 7 do
            local key = cal.dayKey(col, row)
            local v = key and by_day[key]
            if v then
                values[#values + 1] = v
                total = total + v
                days = days + 1
            end
        end
    end
    local thresholds = Scale.thresholds(values)

    -- One label at the first column of each month. os.date gives them in the
    -- device's own language.
    local months, last_month = {}, nil
    for col = 1, cal.weeks do
        for row = 1, 7 do
            local key = cal.dayKey(col, row)
            if key then
                local m = tonumber(key:sub(6, 7))
                if m ~= last_month then
                    last_month = m
                    months[#months + 1] = { col = col,
                        text = os.date("%b", os.time{ year = year, month = m, day = 1, hour = 12 }) }
                end
                break
            end
        end
    end

    local TextWidget    = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local sc = Kit.sc(scale_pct)
    local hface, hbold = Kit.face(15, scale_pct, { bold = true })
    local sface = Kit.face(12, scale_pct)

    local heading = TextWidget:new{ text = _("Atlas year"), face = hface,
        bold = hbold, fgcolor = Kit.COLOR_MUTED, max_width = width }
    local amount = (total >= 3600)
        and string.format("%.1f h", total / 3600)
        or string.format("%d min", math.floor(total / 60))
    local sub = TextWidget:new{
        text = string.format("%d · %d days · %s", year, days, amount),
        face = sface, fgcolor = Kit.COLOR_MUTED, max_width = width }

    -- Give the grid whatever height the two text lines leave behind.
    local chrome = heading:getSize().h + sub:getSize().h + sc(6)
    local avail = ctx.height and math.max(sc(20), ctx.height - chrome)
        or math.floor(width / 7)

    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))
    local grid = GW.new{
        width = width, height = avail, cols = cal.weeks, rows = 7,
        col_labels = months, face = sface, label_color = Kit.COLOR_MUTED,
        level = function(col, row)
            local key = cal.dayKey(col, row)
            if not key then return 0 end
            return Scale.level(by_day[key], thresholds)
        end,
    }

    return VerticalGroup:new{
        align = "left",
        heading,
        VerticalSpan:new{ width = sc(3) },
        grid,
        VerticalSpan:new{ width = sc(3) },
        sub,
    }
end

return {
    key     = "atlas_heatmap",
    title   = _("Atlas year"),
    summary = _("Your reading year as a grid of days. Works offline."),
    render  = render,
}
