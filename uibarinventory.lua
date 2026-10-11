-- Inventory widget: one dot per slot in 5x6 blocks; hover lists every bag.
local util = require('uibarutil')
local P = require('uibarprim')

local M = {}

local POLL_SECS = 1.0

-- Layout at scale 1.
local COLS, ROWS = 5, 6
local DOT, GAP, GROUP_GAP = 10, 1, 8
local PAD = 8
local HEADER_H = 16

M.DEFAULT_COLORS = {
    used = {r = 94, g = 178, b = 224},
    warn = {r = 255, g = 215, b = 0},
    crit = {r = 255, g = 60, b = 60},
}
local EMPTY = {10, 24, 52}
local RING = {70, 92, 135}
local GREY = {170, 175, 190}

local BAGS = {
    {'inventory', 'Inventory'}, {'safe', 'Mog Safe'}, {'safe2', 'Mog Safe 2'}, {'storage', 'Storage'},
    {'locker', 'Mog Locker'}, {'satchel', 'Satchel'}, {'sack', 'Sack'}, {'case', 'Case'},
    {'wardrobe', 'Wardrobe'}, {'wardrobe2', 'Wardrobe 2'}, {'wardrobe3', 'Wardrobe 3'}, {'wardrobe4', 'Wardrobe 4'},
    {'wardrobe5', 'Wardrobe 5'}, {'wardrobe6', 'Wardrobe 6'}, {'wardrobe7', 'Wardrobe 7'}, {'wardrobe8', 'Wardrobe 8'},
}

local data = {next_poll = 0, bags = nil}

function M.poll(now_u)
    if now_u < data.next_poll then
        return
    end
    data.next_poll = now_u + POLL_SECS
    local b = windower.ffxi.get_bag_info()
    if type(b) == 'table' then
        data.bags = b
    end
end

local function rgb(c, fallback)
    if type(c) == 'table' and c.r then
        return {tonumber(c.r) or 0, tonumber(c.g) or 0, tonumber(c.b) or 0}
    end
    return {fallback.r, fallback.g, fallback.b}
end

-- cfg = settings.inventory (optional).
function M.fill_color(count, max, cfg)
    cfg = cfg or {}
    local colors = cfg.colors or {}
    local free = max - count
    if free <= (tonumber(cfg.crit_free) or 5) then
        return rgb(colors.crit, M.DEFAULT_COLORS.crit)
    elseif free <= (tonumber(cfg.warn_free) or 10) then
        return rgb(colors.warn, M.DEFAULT_COLORS.warn)
    end
    return rgb(colors.used, M.DEFAULT_COLORS.used)
end

-- Enabled bags with capacity, in display order: {key, name, count, max}
function M.bag_list(bags)
    local out = {}
    if type(bags) ~= 'table' then
        return out
    end
    for _, b in ipairs(BAGS) do
        local info = bags[b[1]]
        local max = type(info) == 'table' and tonumber(info.max or 0) or 0
        if max > 0 and info.enabled ~= false then
            out[#out + 1] = {key = b[1], name = b[2], count = tonumber(info.count or 0) or 0, max = max}
        end
    end
    return out
end

local function metrics(k)
    k = k or 1
    local function px(v) return math.max(1, math.floor(v * k + 0.5)) end
    local dot, gap = px(DOT), math.max(1, px(GAP))
    return {dot = dot, gap = gap, pitch = dot + gap, group_gap = px(GROUP_GAP), pad = px(PAD), header = px(HEADER_H), px = px}
end

-- Top-left offset of slot i inside the grid.
function M.dot_offset(i, k)
    local m = metrics(k)
    local per_group = COLS * ROWS
    local group = math.floor((i - 1) / per_group)
    local idx = (i - 1) % per_group
    local row = math.floor(idx / COLS)
    local col = idx % COLS
    local gx = group * (COLS * m.pitch - m.gap + m.group_gap)
    return gx + col * m.pitch, row * m.pitch
end

function M.grid_size(max, k)
    local m = metrics(k)
    local groups = math.max(1, math.ceil(max / (COLS * ROWS)))
    local rows = math.min(ROWS, math.max(1, math.ceil(max / COLS)))
    local w = groups * (COLS * m.pitch - m.gap) + (groups - 1) * m.group_gap
    return w, rows * m.pitch - m.gap
end

local ui = nil

local function ensure_dots(n)
    for i = #ui.dots + 1, n do
        ui.dots[i] = P.image(P.ui_root .. 'dot.png')
        ui.rings[i] = P.image(P.ui_root .. 'ring.png')
    end
end

local function ensure_rows(n)
    for i = #ui.rows + 1, n do
        ui.rows[i] = {
            name = P.label(9, {225, 228, 240}),
            count = P.label(9, {225, 228, 240}),
            bar_bg = P.rect(8, 12, 26, 230),
            bar_fg = P.image(nil),
        }
    end
end

function M.create()
    ui = {
        panel = P.panel(),
        count = P.label(10, {94, 178, 224}),
        dots = {},
        rings = {},
        tip_panel = P.panel(),
        rows = {},
    }
end

function M.set_draggable(on)
    if ui then
        P.panel_handle(ui.panel):draggable(on and true or false)
    end
end

local function hide_tip()
    P.panel_hide(ui.tip_panel)
    for _, r in ipairs(ui.rows) do
        P.hide(r.name)
        P.hide(r.count)
        P.hide(r.bar_bg)
        P.hide(r.bar_fg)
    end
end

function M.hide()
    if not ui then
        return
    end
    P.panel_hide(ui.panel)
    P.hide(ui.count)
    for i = 1, #ui.dots do
        P.hide(ui.dots[i])
        P.hide(ui.rings[i])
    end
    hide_tip()
    ui.visible = false
end

function M.dragged_pos()
    if not ui or not ui.visible then
        return nil
    end
    local h, c = P.panel_handle(ui.panel)
    local lx, ly = P.last_pos(h)
    local rx, ry = h:pos()
    if lx and rx and (math.floor(rx) ~= lx or math.floor(ry) ~= ly) then
        P.forget_pos(h)
        return math.floor(rx) - c, math.floor(ry) - c
    end
    return nil
end

local function draw_tooltip(cfg, x, y, w, h, m, corner)
    local list = M.bag_list(data.bags)
    ensure_rows(#list)
    local px = m.px
    local name_w, bar_w, row_h, bar_h = px(84), px(90), px(15), math.max(2, px(6))
    local fs = math.max(6, px(9))
    local tw = m.pad + name_w + bar_w + px(8) + px(52) + m.pad
    local th = m.pad + #list * row_h + m.pad - px(3)
    local ty = (cfg.details == 'below') and (y + h + px(4)) or (y - th - px(4))
    P.panel_layout(ui.tip_panel, x, ty, tw, th, 240, corner)
    for i, b in ipairs(list) do
        local r = ui.rows[i]
        local ry = ty + m.pad + (i - 1) * row_h
        local col = M.fill_color(b.count, b.max, cfg)
        P.fsize(r.name, fs)
        P.text(r.name, b.name)
        P.pos(r.name, x + m.pad, ry - px(2))
        P.show(r.name)
        local bx = x + m.pad + name_w
        local by = ry + math.floor((row_h - bar_h) / 2) - px(1)
        P.pos(r.bar_bg, bx, by)
        P.size(r.bar_bg, bar_w, bar_h)
        P.show(r.bar_bg)
        local fw = math.floor(bar_w * math.min(1, b.count / math.max(1, b.max)) + 0.5)
        P.color(r.bar_fg, col[1], col[2], col[3])
        P.pos(r.bar_fg, bx, by)
        P.size(r.bar_fg, math.max(1, fw), bar_h)
        if fw > 0 then P.show(r.bar_fg) else P.hide(r.bar_fg) end
        P.fsize(r.count, fs)
        P.text(r.count, string.format('%3d/%-3d', b.count, b.max))
        P.color(r.count, col[1], col[2], col[3])
        P.pos(r.count, bx + bar_w + px(8), ry - px(2))
        P.show(r.count)
    end
    for i = #list + 1, #ui.rows do
        local r = ui.rows[i]
        P.hide(r.name)
        P.hide(r.count)
        P.hide(r.bar_bg)
        P.hide(r.bar_fg)
    end
end

function M.update(settings, mouse_x, mouse_y)
    local cfg = settings.inventory
    if not ui or not cfg or not cfg.enabled then
        M.hide()
        return
    end
    M.poll(util.unix_now())
    local inv = data.bags and data.bags.inventory
    local max = inv and tonumber(inv.max or 0) or 0
    if max <= 0 then
        M.hide()
        return
    end
    local count = math.min(max, tonumber(inv.count or 0) or 0)
    local col = M.fill_color(count, max, cfg)

    local k = math.max(0.5, math.min(2.5, tonumber(cfg.scale or 1) or 1))
    local m = metrics(k)
    local px = m.px
    local corner = math.max(6, px(12))
    local x, y = cfg.x, cfg.y

    -- The frame follows the grid; it only widens for a longer count text.
    P.fsize(ui.count, math.max(6, px(10)))
    local ctext = string.format('%d/%d', count, max)
    P.text(ui.count, ctext)
    local cw = P.extents(ui.count) or (#ctext * px(8))

    local gw, gh = M.grid_size(max, k)
    local w = math.max(m.pad + gw + m.pad, m.pad + cw + m.pad)
    local h = m.pad + m.header + gh + m.pad
    P.panel_layout(ui.panel, x, y, w, h, 235, corner)

    P.color(ui.count, col[1], col[2], col[3])
    P.pos(ui.count, x + w - m.pad - cw, y + m.pad - px(5))
    P.show(ui.count)

    ensure_dots(max)
    local ox = x + math.floor((w - gw) / 2)
    local oy = y + m.pad + m.header
    for i = 1, max do
        local dx, dy = M.dot_offset(i, k)
        local dot, ring = ui.dots[i], ui.rings[i]
        P.pos(dot, ox + dx, oy + dy)
        P.size(dot, m.dot, m.dot)
        if i <= count then
            P.color(dot, col[1], col[2], col[3])
            P.hide(ring)
        else
            P.color(dot, EMPTY[1], EMPTY[2], EMPTY[3])
            P.pos(ring, ox + dx, oy + dy)
            P.size(ring, m.dot, m.dot)
            P.color(ring, RING[1], RING[2], RING[3])
            P.alpha(ring, 200)
            P.show(ring)
        end
        P.show(dot)
    end
    for i = max + 1, #ui.dots do
        P.hide(ui.dots[i])
        P.hide(ui.rings[i])
    end
    ui.visible = true

    if P.inside(mouse_x, mouse_y, x, y, w, h) then
        draw_tooltip(cfg, x, y, w, h, m, corner)
    else
        hide_tip()
    end
end

function M.destroy()
    if not ui then
        return
    end
    P.panel_destroy(ui.panel)
    P.panel_destroy(ui.tip_panel)
    for _, key in ipairs({'count'}) do
        pcall(function() ui[key]:destroy() end)
    end
    for i = 1, #ui.dots do
        pcall(function() ui.dots[i]:destroy() end)
        pcall(function() ui.rings[i]:destroy() end)
    end
    for _, r in ipairs(ui.rows) do
        for _, key in ipairs({'name', 'count', 'bar_bg', 'bar_fg'}) do
            pcall(function() r[key]:destroy() end)
        end
    end
    ui = nil
end

return M
