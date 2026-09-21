-- Reading Atlas: when do I actually read? Hours across, weekdays down.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local rows = atlas("source").get(refresh)

    if rows == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading clock"), value = _("Reading…") }
    end
    if rows == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading clock"), value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local grid_data = atlas("aggregate").byHourWeekday(rows)
    local Scale = atlas("scale")

    local values, peak_h, peak_v = {}, 0, -1
    for hour = 0, 23 do
        local hour_total = 0
        for wday = 1, 7 do
            values[#values + 1] = grid_data[wday][hour]
            hour_total = hour_total + grid_data[wday][hour]
        end
        if hour_total > peak_v then peak_v, peak_h = hour_total, hour end
    end
    local thresholds = Scale.thresholds(values)

    -- Every sixth hour, so the strip reads as a day without crowding.
    local hours = {}
    for hour = 0, 23, 6 do
        hours[#hours + 1] = { col = hour + 1, text = string.format("%02dh", hour) }
    end

    local TextWidget    = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local sc = Kit.sc(scale_pct)
    local hface, hbold = Kit.face(15, scale_pct, { bold = true })
    local sface = Kit.face(12, scale_pct)

    local heading = TextWidget:new{ text = _("Reading clock"), face = hface,
        bold = hbold, fgcolor = Kit.COLOR_MUTED, max_width = width }
    local sub = TextWidget:new{
        text = (peak_v > 0)
            and string.format("%s %02dh", _("you read most around"), peak_h)
            or _("rows are weekdays, columns are hours"),
        face = sface, fgcolor = Kit.COLOR_MUTED, max_width = width }

    local chrome = heading:getSize().h + sub:getSize().h + sc(6)
    local avail = ctx.height and math.max(sc(20), ctx.height - chrome)
        or math.floor(width / 3)

    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))
    local grid = GW.new{
        width = width, height = avail, cols = 24, rows = 7,
        col_labels = hours, face = sface, label_color = Kit.COLOR_MUTED,
        -- col 1 is hour 0; row 1 is Sunday, matching os.date wday.
        level = function(col, row)
            return Scale.level(grid_data[row][col - 1], thresholds)
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
    key     = "atlas_clock",
    title   = _("Reading clock"),
    summary = _("From KOReader statistics. Works offline."),
    render  = render,
}
