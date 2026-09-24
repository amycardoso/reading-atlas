-- Reading Atlas: the library as territory. One cell per book, grouped by
-- language, author, series or genre; the grey is how far the book was read.
--
-- The axis is per-instance config (long-press > Module settings), so the card
-- can be added twice -- languages in one, authors in the other.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

-- Settings-dialog order.
local AXES = { "language", "author", "series", "genre" }
local DEFAULT_AXIS = "language"

local AXIS = {
    language = {
        title = _("Languages"), one = _("language"), noun = _("languages"), unassigned = _("Unknown"),
        none = _("No languages"), none_sub = _("None of your books declare a language."),
    },
    author = {
        title = _("Authors"), one = _("author"), noun = _("authors"), unassigned = _("No author"),
        none = _("No authors"), none_sub = _("None of your books name an author."),
    },
    series = {
        title = _("Series"), one = _("series"), noun = _("series"), unassigned = _("No series"),
        none = _("No series"), none_sub = _("None of your books belong to a series."),
    },
    genre = {
        title = _("Genres"), one = _("genre"), noun = _("genres"), unassigned = _("No genre"),
        none = _("No genres"), none_sub = _("None of your books carry a genre tag."),
    },
}

-- The shortest label worth drawing: three letters and an ellipsis. "M" is
-- about the widest letter, so this errs on the side of folding a territory
-- rather than naming it with a single character.
local MIN_LABEL = "Mmm…"

-- ctx.config is absent in the Add picker, and a hand-edited or future value
-- must not reach AXIS[] as a nil.
local function axisOf(ctx)
    local axis = ctx and ctx.config and ctx.config:get("axis", DEFAULT_AXIS)
    if not AXIS[axis] then axis = DEFAULT_AXIS end
    return axis
end

local function fetch(axis, refresh)
    return atlas("source").getKeyed("map:" .. axis, refresh, {
        query = function() return atlas("library").territories(axis) end,
        -- An empty library is data ({}), not "bookshelf did not answer" (nil).
        accept = function(result) return result ~= nil end,
    })
end

-- The plan is the expensive part, and the host renders the same card several
-- times at different scales. Keyed on everything plan() reads; the prepared
-- table is a stable identity for as long as its source cache lives.
local _plan_memo = setmetatable({}, { __mode = "k" })

local function planFor(prep, width, height, face, measure)
    local per = _plan_memo[prep]
    if not per then
        per = {}
        _plan_memo[prep] = per
    end
    local key = width .. "x" .. height .. ":" .. tostring(face)
    if not per[key] then
        per[key] = atlas("territory").plan{
            territories = prep.territories, width = width, height = height,
            measure = measure, min_label = MIN_LABEL, others_label = _("Others"),
            grid = atlas("grid"),
        }
    end
    return per[key]
end

local _prep_memo = setmetatable({}, { __mode = "k" })

local function prepared(lib, axis)
    local prep = _prep_memo[lib]
    if not prep then
        prep = atlas("territory").prepare(lib, axis, AXIS[axis].unassigned)
        _prep_memo[lib] = prep
    end
    return prep
end

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local axis = axisOf(ctx)
    local A = AXIS[axis]
    local heading_text = _("Atlas map") .. " · " .. A.title

    -- The Add picker renders every module's preview to fill the list; it
    -- must never be what starts the whole-library walk. peek() answers from
    -- whatever is already cached (nil, false or the data) and schedules
    -- nothing, so a cold preview always shows "Reading…". peek() can itself
    -- answer false, so this cannot be the usual `and/or` one-liner -- that
    -- would fall through to fetch() and schedule a query anyway.
    local lib
    if ctx.preview then
        lib = atlas("source").peek("map:" .. axis)
    else
        lib = fetch(axis, refresh)
    end
    if lib == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = _("Reading…") }
    end
    if lib == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = _("Unavailable"),
            sub = _("This bookshelf version does not share its library. Update bookshelf.") }
    end

    local prep = prepared(lib, axis)
    if prep.no_values then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = A.none, sub = A.none_sub }
    end
    if prep.books == 0 then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = _("No books"),
            sub = _("No books found in KOReader's home folder.") }
    end

    local TextWidget    = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local sc = Kit.sc(scale_pct)
    local hface, hbold = Kit.face(15, scale_pct, { bold = true })
    local sface = Kit.face(12, scale_pct)

    -- bookshelf's ngettext always answers the singular, so plurals are
    -- chosen here.
    local context = string.format("%d %s · %d %s · %d %s",
        prep.books, prep.books == 1 and _("book") or _("books"),
        prep.finished, _("finished"),
        prep.count, prep.count == 1 and A.one or A.noun)
    if prep.excluded > 0 then
        context = context .. string.format(" · %d %s", prep.excluded, _("not in a series"))
    end

    local heading = TextWidget:new{ text = heading_text, face = hface,
        bold = hbold, fgcolor = Kit.COLOR_MUTED, max_width = width }
    local sub = TextWidget:new{ text = context, face = sface,
        fgcolor = Kit.COLOR_MUTED, max_width = width }

    local chrome = heading:getSize().h + sub:getSize().h + sc(6)
    local avail = ctx.height and math.max(sc(20), ctx.height - chrome)
        or math.floor(width / 3)

    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))
    -- The plan must be solved against exactly the grid height the widget
    -- will end up with, or the two disagree about the cell size and the
    -- labels land on the wrong columns.
    local grid_h = math.max(1, avail - GW.labelHeight(sface))
    local function measure(text)
        local tw = TextWidget:new{ text = text, face = sface }
        local w = tw:getSize().w
        tw:free()
        return w
    end
    local plan = planFor(prep, width, grid_h, sface, measure)

    local grid = GW.new{
        width = width, height = avail, cols = plan.cols, rows = plan.rows,
        col_labels = plan.labels, label_mode = "truncate",
        face = sface, label_color = Kit.COLOR_MUTED,
        -- nil is a blank: the border between territories and the end of a
        -- territory's last column. Unread books are 0 and still paint.
        level = function(col, row)
            local c = plan.cells[col]
            return c and c[row]
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

-- A radio list of axes. Each pick persists on this card's entry (which
-- reloads the card) and re-opens the dialog so the checkmark moves.
local function showSettings(ctx)
    if not (ctx and ctx.config) then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local current = axisOf(ctx)
    local dialog
    local buttons = {}
    for _i, key in ipairs(AXES) do
        buttons[#buttons + 1] = { Kit.radioRow{
            label = AXIS[key].title, active = current == key,
            on_pick = function()
                ctx.config:set("axis", key)
                Kit.settingsReopen(ctx, dialog, showSettings)
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title        = _("Atlas map"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = buttons,
    }
    UIManager:show(dialog)
end

return {
    key           = "atlas_map", -- stored in users' menus; never change it
    title         = _("Atlas map"),
    summary       = _("Your library by language, author, series or genre. Works offline."),
    render        = render,
    show_settings = showSettings,
}
