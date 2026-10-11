-- Gil widget: total and gil won/lost this session.
-- The session baseline waits for a stable reading (right after login the client reports 0 or a
-- partial value) and the transient 0 while zoning is ignored.
local util = require('uibarutil')
local P = require('uibarprim')

local M = {}

local POLL_SECS = 1.0
local STABLE_SECS = 3.0
local ZERO_CONFIRM_SECS = 10

local GOLD = {255, 228, 150}
local GREEN = {110, 230, 140}
local RED = {255, 105, 105}
local GREY = {170, 175, 190}

local data = {next_poll = 0, gil = nil, player = 0, base_gil = nil, base_at = nil, stable_gil = nil, stable_since = nil}

function M.comma(n)
    local s = tostring(math.floor(math.abs(n) + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then
        out = out:sub(2)
    end
    return out
end

local function signed(n, fmt)
    return (n < 0 and '-' or '+') .. fmt(n)
end

function M.reset_session()
    data.base_gil, data.base_at = nil, nil
    data.stable_gil, data.stable_since = nil, nil
end

local function try_baseline(gil, now_u)
    if data.base_gil ~= nil then
        return
    end
    if data.stable_gil ~= gil then
        data.stable_gil, data.stable_since = gil, now_u
        return
    end
    local need = (gil == 0) and ZERO_CONFIRM_SECS or STABLE_SECS
    if now_u - data.stable_since >= need then
        data.base_gil, data.base_at = gil, now_u
    end
end

function M.poll(now_u)
    if now_u < data.next_poll then
        return
    end
    data.next_poll = now_u + POLL_SECS
    local pid = util.player_id()
    if pid <= 0 then
        return
    end
    if pid ~= data.player then
        data.player = pid
        data.gil = nil
        M.reset_session()
    end
    local gil = tonumber(windower.ffxi.get_items('gil') or 0) or 0
    if not (gil == 0 and data.base_gil ~= nil and (data.gil or 0) > 0) then
        data.gil = gil
        try_baseline(gil, now_u)
    end
end

-- {gil, net, elapsed, base} (net nil until the baseline is ready)
function M.snapshot(now_u)
    local s = {gil = data.gil}
    if data.gil and data.base_gil then
        s.base = data.base_gil
        s.net = data.gil - data.base_gil
        s.elapsed = now_u - data.base_at
    end
    return s
end

local function duration(secs)
    secs = math.floor(secs or 0)
    return string.format('%d:%02d:%02d', math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60)
end

local function cs(rgb, str)
    return string.format('\\cs(%d,%d,%d)%s\\cr', rgb[1], rgb[2], rgb[3], str)
end

function M.session_line(s)
    if not s.net then
        return cs(GREY, 'session starting...')
    end
    return cs(GREY, 'session ') .. cs(s.net < 0 and RED or GREEN, signed(s.net, M.comma))
end

function M.tooltip_text(s)
    if not s.net then
        return cs(GREY, 'Waiting for a stable gil reading...')
    end
    local lines = {
        cs(GREY, 'Session   ') .. cs({235, 235, 235}, duration(s.elapsed)),
        cs(GREY, 'Start     ') .. cs(GOLD, M.comma(s.base) .. ' g'),
        cs(GREY, 'Now       ') .. cs(GOLD, M.comma(s.gil) .. ' g'),
        cs(GREY, s.net < 0 and 'Lost      ' or 'Won       ') .. cs(s.net < 0 and RED or GREEN, signed(s.net, M.comma) .. ' g'),
    }
    return table.concat(lines, '\n')
end

local PAD = 8
local ICON = 24
local ui = nil

function M.create()
    ui = {
        panel = P.panel(),
        icon = P.image(P.ui_root .. 'gil.png'),
        amount = P.label(13, GOLD),
        session = P.label(9, GREY),
        tip_panel = P.panel(),
        tip = P.label(9, {235, 235, 235}),
    }
end

function M.set_draggable(on)
    if ui then
        local h = P.panel_handle(ui.panel)
        h:draggable(on and true or false)
    end
end

function M.hide()
    if not ui then
        return
    end
    P.panel_hide(ui.panel)
    P.hide(ui.icon)
    P.hide(ui.amount)
    P.hide(ui.session)
    P.panel_hide(ui.tip_panel)
    P.hide(ui.tip)
    ui.visible = false
end

-- New top-left if the user dragged the widget, else nil.
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

function M.update(settings, mouse_x, mouse_y)
    local cfg = settings.gil
    if not ui or not cfg or not cfg.enabled then
        M.hide()
        return
    end
    local now_u = util.unix_now()
    M.poll(now_u)
    local s = M.snapshot(now_u)
    if not s.gil then
        M.hide()
        return
    end

    local k = math.max(0.5, math.min(2.5, tonumber(cfg.scale or 1) or 1))
    local function px(v) return math.floor(v * k + 0.5) end
    local pad, icon, gap = px(PAD), px(ICON), px(8)
    local corner = math.max(6, px(12))

    local x, y = cfg.x, cfg.y
    local amount = M.comma(s.gil)
    P.fsize(ui.amount, math.max(7, px(13)))
    P.fsize(ui.session, math.max(6, px(9)))
    P.text(ui.amount, amount)
    P.text(ui.session, M.session_line(s))
    local aw, ah = P.extents(ui.amount)
    local sw = P.extents(ui.session)
    aw, ah, sw = aw or (#amount * px(9)), ah or px(18), sw or px(120)
    local w = pad + icon + gap + math.max(aw, sw) + pad + px(2)
    local h = pad + px(34) + pad - px(4)

    P.panel_layout(ui.panel, x, y, w, h, 235, corner)
    P.pos(ui.icon, x + pad, y + math.floor((h - icon) / 2))
    P.size(ui.icon, icon, icon)
    P.show(ui.icon)
    P.pos(ui.amount, x + pad + icon + gap, y + pad - px(3))
    P.show(ui.amount)
    P.pos(ui.session, x + pad + icon + gap, y + pad - px(3) + ah - px(1))
    P.show(ui.session)
    ui.visible = true

    if P.inside(mouse_x, mouse_y, x, y, w, h) then
        P.fsize(ui.tip, math.max(6, px(9)))
        P.text(ui.tip, M.tooltip_text(s))
        local tw, th = P.extents(ui.tip)
        tw, th = tw or px(200), th or px(70)
        local ty = y + h + px(4)
        P.panel_layout(ui.tip_panel, x, ty, tw + pad * 2 + px(6), th + pad * 2 - px(2), 240, corner)
        P.pos(ui.tip, x + pad, ty + pad - px(1))
        P.show(ui.tip)
    else
        P.panel_hide(ui.tip_panel)
        P.hide(ui.tip)
    end
end

function M.destroy()
    if not ui then
        return
    end
    P.panel_destroy(ui.panel)
    P.panel_destroy(ui.tip_panel)
    for _, k in ipairs({'icon', 'amount', 'session', 'tip'}) do
        pcall(function() ui[k]:destroy() end)
    end
    ui = nil
end

return M
