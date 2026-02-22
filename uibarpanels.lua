local texts = require('texts')

local M = {}

local function make_style(x, y, bg_alpha)
    return {
        pos = {x = x, y = y},
        text = {
            font = 'Consolas',
            size = 10,
            alpha = 255,
            red = 255,
            green = 255,
            blue = 255,
            stroke = {width = 2, alpha = 180, red = 0, green = 0, blue = 0},
        },
        bg = {
            alpha = bg_alpha,
            red = 18,
            green = 20,
            blue = 24,
        },
        flags = {
            right = false,
            bottom = false,
            bold = false,
            draggable = false,
        },
        padding = 6,
    }
end

function M.create(settings)
    return {
        main = texts.new('', make_style(settings.main.x, settings.main.y, settings.main.bg_alpha)),
        target = texts.new('', make_style(settings.target.x, settings.target.y, settings.target.bg_alpha)),
        enemy = texts.new('', make_style(settings.enemy.x, settings.enemy.y, settings.enemy.bg_alpha)),
    }
end

function M.set_visible(panels, visible)
    panels.main:visible(visible)
    panels.target:visible(visible)
    panels.enemy:visible(visible)
end

function M.move(panels, settings, panel_name, x, y)
    settings[panel_name].x = math.floor(x)
    settings[panel_name].y = math.floor(y)
    panels[panel_name]:pos(settings[panel_name].x, settings[panel_name].y)
end

function M.hide_all(panels)
    panels.main:visible(false)
    panels.target:visible(false)
    panels.enemy:visible(false)
end

return M
