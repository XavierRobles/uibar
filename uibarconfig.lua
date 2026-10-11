-- In-game settings window. Changes apply live and are saved after SAVE_DELAY;
-- mouse input over the window is swallowed so clicks never reach the game.
local P = require('uibarprim')
local util = require('uibarutil')

local M = {}

local W, H = 600, 440
local HELP_H = 48 -- description strip at the bottom
local TITLE_H = 30
local TAB_W = 118
local TAB_H = 26
local CONTENT_X = TAB_W + 22
local LABEL_W = 190
local TRACK_W = 220
local SAVE_DELAY = 0.6

local C = {
    text = {226, 230, 242},
    dim = {160, 168, 190},
    accent = {94, 178, 224},
    title = {255, 228, 150},
    box_border = {120, 135, 185},
    box_bg = {12, 16, 34},
    on = {110, 230, 140},
    track = {8, 12, 26},
    knob = {225, 230, 245},
    tab_active = {56, 92, 160},
    tab_hover = {50, 70, 120},
    btn = {34, 48, 92},
    btn_hover = {58, 82, 140},
}

local PALETTE = {
    {255, 255, 255}, {200, 200, 210}, {140, 145, 160}, {255, 90, 90}, {255, 60, 60}, {200, 40, 40},
    {255, 150, 60}, {255, 190, 90}, {255, 215, 0}, {255, 240, 140}, {170, 230, 90}, {110, 230, 140},
    {60, 200, 120}, {90, 220, 200}, {94, 178, 224}, {150, 200, 255}, {80, 120, 255}, {175, 135, 255},
    {200, 110, 255}, {255, 120, 220}, {255, 170, 200}, {230, 174, 102}, {180, 140, 90}, {120, 90, 60},
}

local ui = nil
local cfg_settings, hooks = nil, {}
local tabs = {}
local state = {
    open = false, tab = 1, mx = -1, my = -1,
    drag_window = nil, drag_slider = nil, palette = nil, dirty_at = nil,
}

local function changed()
    state.dirty_at = util.unix_now()
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- Windower texts do not wrap.
local function wrap(text, width)
    local lines, line = {}, ''
    for word in tostring(text):gmatch('%S+') do
        if #line > 0 and #line + 1 + #word > width then
            lines[#lines + 1] = line
            line = word
        else
            line = (#line > 0) and (line .. ' ' .. word) or word
        end
    end
    if #line > 0 then
        lines[#lines + 1] = line
    end
    return table.concat(lines, '\n')
end

local function pos()
    local c = cfg_settings.config_ui
    return c.x, c.y
end

-- Control kinds: make (create prims), draw (layout), click / drag / wheel.

local function make_label(size, rgb)
    return P.label(size or 10, rgb or C.text, 'Consolas', false)
end

local kinds = {}

kinds.toggle = {
    height = 26,
    make = function(c)
        c.p = {
            border = P.rect(C.box_border[1], C.box_border[2], C.box_border[3], 230),
            bg = P.rect(C.box_bg[1], C.box_bg[2], C.box_bg[3], 255),
            check = P.image(P.ui_root .. 'check.png'),
            label = make_label(10),
        }
        P.color(c.p.check, C.on[1], C.on[2], C.on[3])
    end,
    draw = function(c, x, y, hover)
        local on = c.get() and true or false
        P.pos(c.p.border, x, y + 3); P.size(c.p.border, 16, 16); P.show(c.p.border)
        P.pos(c.p.bg, x + 1, y + 4); P.size(c.p.bg, 14, 14); P.show(c.p.bg)
        P.pos(c.p.check, x + 1, y + 4); P.size(c.p.check, 14, 14)
        if on then P.show(c.p.check) else P.hide(c.p.check) end
        P.text(c.p.label, c.label)
        local col = hover and C.title or C.text
        P.color(c.p.label, col[1], col[2], col[3])
        P.pos(c.p.label, x + 24, y + 2); P.show(c.p.label)
        c.hit = {x, y, W - CONTENT_X - 20, 24}
    end,
    click = function(c)
        c.set(not c.get())
        changed()
    end,
}

local function slider_value_at(c, mx)
    local t = clamp((mx - c.track_x) / TRACK_W, 0, 1)
    local v = c.min + t * (c.max - c.min)
    v = math.floor(v / c.step + 0.5) * c.step
    v = tonumber(string.format('%.4f', v)) -- no 0.95000001 in settings.xml
    return clamp(v, c.min, c.max)
end

kinds.slider = {
    height = 34,
    make = function(c)
        c.p = {
            label = make_label(10),
            track = P.rect(C.track[1], C.track[2], C.track[3], 255),
            fill = P.rect(C.accent[1], C.accent[2], C.accent[3], 255),
            knob = P.rect(C.knob[1], C.knob[2], C.knob[3], 255),
            value = make_label(10, C.title),
        }
    end,
    draw = function(c, x, y, hover)
        local v = clamp(tonumber(c.get()) or c.min, c.min, c.max)
        P.text(c.p.label, c.label)
        local col = (hover or state.drag_slider == c) and C.title or C.text
        P.color(c.p.label, col[1], col[2], col[3])
        P.pos(c.p.label, x, y); P.show(c.p.label)
        local tx, ty = x, y + 20
        c.track_x = tx
        P.pos(c.p.track, tx, ty); P.size(c.p.track, TRACK_W, 6); P.show(c.p.track)
        local t = (v - c.min) / math.max(1e-9, c.max - c.min)
        local fw = math.floor(TRACK_W * t + 0.5)
        P.pos(c.p.fill, tx, ty); P.size(c.p.fill, math.max(1, fw), 6)
        if fw > 0 then P.show(c.p.fill) else P.hide(c.p.fill) end
        P.pos(c.p.knob, tx + fw - 4, ty - 4); P.size(c.p.knob, 8, 14); P.show(c.p.knob)
        P.text(c.p.value, c.fmt and c.fmt(v) or tostring(v))
        P.pos(c.p.value, tx + TRACK_W + 14, ty - 6); P.show(c.p.value)
        c.hit = {tx - 6, ty - 8, TRACK_W + 12, 22}
    end,
    click = function(c, mx)
        state.drag_slider = c
        c.set(slider_value_at(c, mx))
        changed()
    end,
    drag = function(c, mx)
        local v = slider_value_at(c, mx)
        if v ~= c.get() then
            c.set(v)
            changed()
        end
    end,
    wheel = function(c, delta)
        local v = clamp((tonumber(c.get()) or c.min) + (delta > 0 and c.step or -c.step), c.min, c.max)
        v = tonumber(string.format('%.4f', v))
        c.set(v)
        changed()
    end,
}

kinds.choice = {
    height = 28,
    make = function(c)
        c.p = {label = make_label(10), segs = {}}
        for i = 1, #c.options do
            c.p.segs[i] = {bg = P.rect(C.btn[1], C.btn[2], C.btn[3], 255), text = make_label(9)}
        end
    end,
    draw = function(c, x, y, hover)
        P.text(c.p.label, c.label)
        P.pos(c.p.label, x, y + 3); P.show(c.p.label)
        local sx = x + LABEL_W
        local cur = c.get()
        c.seg_hits = {}
        for i, opt in ipairs(c.options) do
            local s = c.p.segs[i]
            P.text(s.text, opt[2])
            local tw = P.extents(s.text) or (#opt[2] * 9)
            local sw = math.max(64, tw + 22)
            local active = (cur == opt[1])
            local over = P.inside(state.mx, state.my, sx, y + 2, sw, 20)
            local bgc = active and C.tab_active or (over and C.btn_hover or C.btn)
            P.color(s.bg, bgc[1], bgc[2], bgc[3])
            P.pos(s.bg, sx, y + 2); P.size(s.bg, sw, 20); P.show(s.bg)
            local tc = active and C.title or C.text
            P.color(s.text, tc[1], tc[2], tc[3])
            P.pos(s.text, sx + math.floor((sw - tw) / 2), y + 4); P.show(s.text)
            c.seg_hits[i] = {sx, y + 2, sw, 20}
            sx = sx + sw + 4
        end
        c.hit = {x + LABEL_W, y, sx - x - LABEL_W, 24}
    end,
    click = function(c, mx, my)
        for i, h in ipairs(c.seg_hits or {}) do
            if P.inside(mx, my, h[1], h[2], h[3], h[4]) then
                c.set(c.options[i][1])
                changed()
                return
            end
        end
    end,
}

kinds.color = {
    height = 26,
    make = function(c)
        c.p = {
            label = make_label(10),
            border = P.rect(C.box_border[1], C.box_border[2], C.box_border[3], 230),
            swatch = P.rect(255, 255, 255, 255),
        }
    end,
    draw = function(c, x, y, hover)
        P.text(c.p.label, c.label)
        local col = hover and C.title or C.text
        P.color(c.p.label, col[1], col[2], col[3])
        P.pos(c.p.label, x, y + 2); P.show(c.p.label)
        local v = c.get() or {r = 255, g = 255, b = 255}
        local sx = x + LABEL_W
        P.pos(c.p.border, sx, y + 2); P.size(c.p.border, 42, 18); P.show(c.p.border)
        P.color(c.p.swatch, tonumber(v.r) or 0, tonumber(v.g) or 0, tonumber(v.b) or 0)
        P.pos(c.p.swatch, sx + 1, y + 3); P.size(c.p.swatch, 40, 16); P.show(c.p.swatch)
        c.hit = {sx, y + 2, 42, 18}
        c.swatch_xy = {sx, y + 22}
    end,
    click = function(c)
        state.palette = (state.palette and state.palette.ctrl == c) and nil or {ctrl = c, x = c.swatch_xy[1], y = c.swatch_xy[2]}
    end,
}

kinds.button = {
    height = 32,
    make = function(c)
        c.p = {bg = P.rect(C.btn[1], C.btn[2], C.btn[3], 255), text = make_label(10)}
    end,
    draw = function(c, x, y, hover)
        local bw = math.max(150, #c.label * 8 + 24)
        local bgc = hover and C.btn_hover or C.btn
        P.color(c.p.bg, bgc[1], bgc[2], bgc[3])
        P.pos(c.p.bg, x, y + 3); P.size(c.p.bg, bw, 22); P.show(c.p.bg)
        P.text(c.p.text, c.label)
        local tw = P.extents(c.p.text) or (#c.label * 7)
        P.pos(c.p.text, x + math.floor((bw - tw) / 2), y + 5); P.show(c.p.text)
        c.hit = {x, y + 3, bw, 22}
    end,
    click = function(c)
        if c.action then
            c.action()
        end
    end,
}

local function hide_control(c)
    if not c.p then
        return
    end
    for k, v in pairs(c.p) do
        if k == 'segs' then
            for _, sg in ipairs(v) do
                P.hide(sg.bg)
                P.hide(sg.text)
            end
        else
            P.hide(v)
        end
    end
end

local function T(tbl, key)
    return function() return tbl()[key] end, function(v) tbl()[key] = v end
end

local function pct(v) return string.format('%d%%', math.floor(v * 100 + 0.5)) end

local function build_tabs(s)
    local function g() return s end
    local function graphics_bar() return s.graphics.bar end
    local function graphics_icons() return s.graphics.icons end
    local function enemy() return s.enemy end
    local function gil() return s.gil end
    local function inv() return s.inventory end
    local function casts() return s.casts end
    local function colors() return s.colors end
    local function inv_colors() return s.inventory.colors end
    local function ui_cfg() return s.config_ui end
    local function call(name) return function() if hooks[name] then hooks[name]() end end end

    local function toggle(label, desc, tbl, key, after)
        local get, set = T(tbl, key)
        return {kind = 'toggle', label = label, desc = desc, get = get, set = function(v) set(v); if after then after(v) end end}
    end
    local function slider(label, desc, tbl, key, mn, mx, step, fmt, after)
        local get, set = T(tbl, key)
        return {kind = 'slider', label = label, desc = desc, get = get, min = mn, max = mx, step = step, fmt = fmt,
            set = function(v) set(v); if after then after(v) end end}
    end
    local function color(label, desc, tbl, key)
        local get, set = T(tbl, key)
        return {kind = 'color', label = label, desc = desc, get = get, set = set}
    end
    local function button(label, desc, action)
        return {kind = 'button', label = label, desc = desc, action = action}
    end
    local function px(v) return v .. ' px' end
    local function secs(v) return v .. ' s' end

    return {
        {name = 'General', controls = {
            toggle('Addon activado', 'Activa o desactiva todo uibar. Este menú sigue disponible aunque lo desactives.',
                g, 'enabled', call('refresh')),
            toggle('Bloquear posiciones', 'Desmárcalo para poder arrastrar con el ratón la barra del target, la lista de enemigos y los widgets de gil e inventario.',
                g, 'drag_locked', call('drag_changed')),
            toggle('Modo gráfico', 'Barras e iconos gráficos. Si lo desmarcas, se usan los paneles de texto clásicos.',
                function() return s.graphics end, 'enabled'),
            toggle('Mostrar botón de ajustes', 'Muestra el engranaje de la esquina superior izquierda. Sin él, abre este menú con //uibar config.',
                ui_cfg, 'button'),
            button('Restablecer posiciones', 'Devuelve la barra del target, la lista de enemigos, el gil y el inventario a su posición inicial.',
                function() call('reset_positions')(); changed() end),
        }},
        {name = 'Target', controls = {
            slider('Ancho barra de HP', 'Ancho de la barra de vida del target, en píxeles.', graphics_bar, 'width', 200, 800, 10, px),
            slider('Alto barra de HP', 'Grosor de la barra de vida del target, en píxeles.', graphics_bar, 'height', 6, 24, 1, px),
            slider('Tamaño de iconos', 'Tamaño de los iconos de debuffs que salen bajo la barra del target.', graphics_icons, 'size', 14, 36, 1, px),
            slider('Iconos por fila', 'Cuántos iconos de debuff caben en una fila antes de pasar a la siguiente.', graphics_icons, 'per_row', 4, 20, 1),
            slider('Máximo de iconos', 'Número máximo de debuffs que se muestran en el target.', graphics_icons, 'max_target_debuffs', 4, 32, 1),
        }},
        {name = 'Lista enemigos', controls = {
            slider('Máximo de enemigos', 'Cuántos mobs como máximo muestra la lista de hate.', g, 'max_enemies', 1, 20, 1, nil, call('refresh_enemies')),
            slider('Distancia de detección', 'Distancia máxima entre TÚ y un mob para que ENTRE en la lista de hate. Si ya está en la lista, se mantiene aunque se aleje hasta 15 yalms más. 0 = sin límite.',
                g, 'enemy_scan_range', 0, 60, 1, function(v) return v == 0 and 'sin límite' or (v .. ' yalms') end, call('refresh_enemies')),
            slider('Debuffs por enemigo', 'Cuántos iconos de debuff se ven en cada fila de la lista.', enemy, 'max_debuffs_per_enemy', 1, 10, 1),
            {kind = 'choice', label = 'Orden', options = {{'aggro', 'Aggro'}, {'distance', 'Distancia'}, {'hp', 'Vida'}},
                desc = 'Aggro: en el orden en que te cogieron hate (las filas no saltan). Distancia: el más cercano arriba. Vida: el que menos HP tiene arriba.',
                get = function() return s.enemy_sort or 'aggro' end,
                set = function(v) s.enemy_sort = v; call('refresh_enemies')() end},
        }},
        {name = 'Casteo y timers', controls = {
            toggle('Mostrar barra de casteo', 'Muestra lo que castea o prepara el mob: bajo la barra de HP del target y junto a cada mob de la lista.', casts, 'enabled'),
            color('Color: hechizo', 'Color de la barra cuando el mob castea un hechizo.', colors, 'cast_spell'),
            color('Color: TP move', 'Color cuando el mob prepara un TP move o una habilidad.', colors, 'cast_tp'),
            color('Color: 2H / SP', 'Color del aviso cuando el mob usa un 2H o una habilidad SP.', colors, 'cast_sp'),
            slider('Aviso de timer', 'Cuando a un debuff le quedan estos segundos o menos, su timer cambia al color de aviso.', g, 'timer_warn_secs', 0, 15, 1, secs),
            color('Color: timer en aviso', 'Color del timer cuando el debuff está a punto de acabar.', colors, 'timer_warn'),
            color('Color: debuffs de otros', 'Color del timer de los debuffs que puso otro jugador. Los tuyos van en blanco.', colors, 'timer_other'),
            button('Olvidar duraciones aprendidas', 'Borra las duraciones reales que uibar ha aprendido (útil tras cambiar de equipo). Se vuelven a aprender solas.', call('reset_learned')),
        }},
        {name = 'Gil', controls = {
            toggle('Mostrar gil', 'Muestra el widget de gil: total y ganado/perdido en la sesión.', gil, 'enabled'),
            slider('Escala', 'Tamaño del widget de gil.', gil, 'scale', 0.5, 2.5, 0.05, pct),
            button('Reiniciar sesión', 'Pone a cero lo ganado/perdido y empieza una sesión nueva desde el gil actual.', call('reset_gil')),
        }},
        {name = 'Inventario', controls = {
            toggle('Mostrar inventario', 'Muestra el widget de huecos del inventario.', inv, 'enabled'),
            slider('Escala', 'Tamaño del widget de inventario.', inv, 'scale', 0.5, 2.5, 0.05, pct),
            slider('Aviso: huecos libres', 'Con estos huecos libres o menos, los puntos cambian al color de aviso.', inv, 'warn_free', 0, 40, 1),
            slider('Crítico: huecos libres', 'Con estos huecos libres o menos, los puntos cambian al color crítico.', inv, 'crit_free', 0, 40, 1),
            {kind = 'choice', label = 'Detalle de bolsas', options = {{'above', 'Arriba'}, {'below', 'Abajo'}},
                desc = 'Donde aparece la lista de todas tus bolsas al pasar el ratón por el widget.',
                get = function() return s.inventory.details or 'above' end, set = function(v) s.inventory.details = v end},
            color('Color: ocupado', 'Color de los huecos ocupados cuando hay espacio de sobra.', inv_colors, 'used'),
            color('Color: aviso', 'Color de los huecos ocupados al llegar al umbral de aviso.', inv_colors, 'warn'),
            color('Color: crítico', 'Color de los huecos ocupados al llegar al umbral crítico.', inv_colors, 'crit'),
        }},
    }
end

function M.create(settings, h)
    cfg_settings, hooks = settings, h or {}
    tabs = build_tabs(settings)
    ui = {
        panel = P.panel(),
        title = P.label(11, C.title, 'Consolas', true),
        close = P.image(P.ui_root .. 'close.png'),
        sep = P.rect(120, 135, 185, 120),
        help_sep = P.rect(120, 135, 185, 90),
        help = P.label(9, C.dim, 'Consolas', false),
        tab_bg = {},
        tab_text = {},
        pal = {},
        gear_panel = P.panel(),
        gear = P.image(P.ui_root .. 'gear.png'),
    }
    for i = 1, #tabs do
        ui.tab_bg[i] = P.rect(0, 0, 0, 0)
        ui.tab_text[i] = P.label(10, C.text, 'Consolas', false)
    end
    -- Windower draws in creation order: create the palette last so it stays on top.
    for _, t in ipairs(tabs) do
        for _, c in ipairs(t.controls) do
            kinds[c.kind].make(c)
        end
    end
    ui.pal_panel = P.panel()
    for i = 1, #PALETTE do
        ui.pal[i] = P.rect(PALETTE[i][1], PALETTE[i][2], PALETTE[i][3], 255)
    end
end

function M.is_open()
    return state.open
end

local function hide_window()
    if not ui then
        return
    end
    P.panel_hide(ui.panel)
    P.hide(ui.title)
    P.hide(ui.close)
    P.hide(ui.sep)
    P.hide(ui.help_sep)
    P.hide(ui.help)
    for i = 1, #tabs do
        P.hide(ui.tab_bg[i])
        P.hide(ui.tab_text[i])
        for _, c in ipairs(tabs[i].controls) do
            hide_control(c)
        end
    end
    P.panel_hide(ui.pal_panel)
    for i = 1, #ui.pal do
        P.hide(ui.pal[i])
    end
end

function M.open()
    state.open = true
end

function M.close()
    state.open = false
    state.palette, state.drag_slider, state.drag_window = nil, nil, nil
    hide_window()
end

function M.toggle()
    if state.open then M.close() else M.open() end
end

local function control_rows(x0, y0)
    local rows = {}
    local y = y0
    for _, c in ipairs(tabs[state.tab].controls) do
        rows[#rows + 1] = {c = c, x = x0, y = y}
        y = y + kinds[c.kind].height
    end
    return rows
end

local function draw_palette()
    local p = state.palette
    if not p then
        P.panel_hide(ui.pal_panel)
        for i = 1, #ui.pal do P.hide(ui.pal[i]) end
        return
    end
    local cols, sz, gap = 6, 18, 4
    local rows = math.ceil(#PALETTE / cols)
    local pw, ph = 12 + cols * (sz + gap) - gap + 12, 12 + rows * (sz + gap) - gap + 12
    P.panel_layout(ui.pal_panel, p.x, p.y, pw, ph, 250, 10)
    p.hits = {}
    for i = 1, #PALETTE do
        local cx = p.x + 12 + ((i - 1) % cols) * (sz + gap)
        local cy = p.y + 12 + math.floor((i - 1) / cols) * (sz + gap)
        P.pos(ui.pal[i], cx, cy); P.size(ui.pal[i], sz, sz); P.show(ui.pal[i])
        p.hits[i] = {cx, cy, sz, sz}
    end
    p.w, p.h = pw, ph
end

local function draw_gear()
    local c = cfg_settings.config_ui
    if not c.button then
        P.panel_hide(ui.gear_panel)
        P.hide(ui.gear)
        return
    end
    local over = P.inside(state.mx, state.my, c.button_x, c.button_y, 26, 26)
    P.panel_layout(ui.gear_panel, c.button_x, c.button_y, 26, 26, over and 255 or 215, 6)
    local col = (state.open or over) and C.title or C.dim
    P.color(ui.gear, col[1], col[2], col[3])
    P.pos(ui.gear, c.button_x + 4, c.button_y + 4); P.size(ui.gear, 18, 18); P.show(ui.gear)
end

function M.update(mouse_x, mouse_y)
    if not ui then
        return
    end
    state.mx, state.my = mouse_x or state.mx, mouse_y or state.my
    draw_gear()

    if state.dirty_at and util.unix_now() - state.dirty_at >= SAVE_DELAY and not state.drag_slider then
        state.dirty_at = nil
        if hooks.save then hooks.save() end
    end
    if not state.open then
        return
    end

    local x, y = pos()
    P.panel_layout(ui.panel, x, y, W, H, 248, 12)
    P.text(ui.title, 'uibar  -  Ajustes')
    P.pos(ui.title, x + 14, y + 7); P.show(ui.title)
    local over_close = P.inside(state.mx, state.my, x + W - 28, y + 7, 18, 18)
    local cc = over_close and {255, 110, 110} or C.dim
    P.color(ui.close, cc[1], cc[2], cc[3])
    P.pos(ui.close, x + W - 28, y + 7); P.size(ui.close, 18, 18); P.show(ui.close)
    P.pos(ui.sep, x + 10, y + TITLE_H); P.size(ui.sep, W - 20, 1); P.show(ui.sep)

    for i, t in ipairs(tabs) do
        local tx, ty = x + 10, y + TITLE_H + 8 + (i - 1) * (TAB_H + 2)
        local active = (i == state.tab)
        local over = P.inside(state.mx, state.my, tx, ty, TAB_W, TAB_H)
        local bg = ui.tab_bg[i]
        if active or over then
            local col = active and C.tab_active or C.tab_hover
            P.color(bg, col[1], col[2], col[3])
            P.alpha(bg, active and 220 or 140)
            P.pos(bg, tx, ty); P.size(bg, TAB_W, TAB_H); P.show(bg)
        else
            P.hide(bg)
        end
        P.text(ui.tab_text[i], t.name)
        local col = active and C.title or C.text
        P.color(ui.tab_text[i], col[1], col[2], col[3])
        P.pos(ui.tab_text[i], tx + 10, ty + 5); P.show(ui.tab_text[i])
        t.hit = {tx, ty, TAB_W, TAB_H}
    end

    for i, t in ipairs(tabs) do
        if i ~= state.tab then
            for _, c in ipairs(t.controls) do hide_control(c) end
        end
    end
    local desc = nil
    for _, r in ipairs(control_rows(x + CONTENT_X, y + TITLE_H + 10)) do
        local k = kinds[r.c.kind]
        local hv = r.c.hit and P.inside(state.mx, state.my, r.c.hit[1], r.c.hit[2], r.c.hit[3], r.c.hit[4]) and not state.palette
        -- Hovering anywhere on the row shows its description.
        local row_hover = P.inside(state.mx, state.my, r.x, r.y, W - CONTENT_X - 12, k.height)
        if (hv or row_hover) and r.c.desc then
            desc = r.c.desc
        end
        k.draw(r.c, r.x, r.y, hv)
    end

    local hy = y + H - HELP_H
    P.pos(ui.help_sep, x + 10, hy); P.size(ui.help_sep, W - 20, 1); P.show(ui.help_sep)
    P.text(ui.help, wrap(desc or 'Pasa el ratón por una opción para ver qué hace.', math.floor((W - 30) / 7)))
    local hc = desc and C.text or C.dim
    P.color(ui.help, hc[1], hc[2], hc[3])
    P.pos(ui.help, x + 14, hy + 6); P.show(ui.help)
    draw_palette()
end

-- Returns true to swallow the event.
function M.mouse(mtype, mx, my, delta)
    if not ui then
        return false
    end
    state.mx, state.my = mx, my
    local c = cfg_settings.config_ui
    local x, y = pos()
    local over_window = state.open and P.inside(mx, my, x, y, W, H)
    local over_gear = c.button and P.inside(mx, my, c.button_x, c.button_y, 26, 26)
    local p = state.palette
    local over_palette = p and p.w and P.inside(mx, my, p.x, p.y, p.w, p.h)

    if mtype == 0 then -- move
        if state.drag_window then
            c.x = math.floor(mx - state.drag_window[1])
            c.y = math.floor(my - state.drag_window[2])
            changed()
            return true
        end
        if state.drag_slider then
            kinds.slider.drag(state.drag_slider, mx)
            return true
        end
        return over_window or over_gear or over_palette or false
    end

    if mtype == 2 then -- left up
        local was = state.drag_window or state.drag_slider
        state.drag_window, state.drag_slider = nil, nil
        if was then changed() end
        return was and true or over_window or over_gear or over_palette or false
    end

    if mtype == 1 then -- left down
        if over_gear then
            M.toggle()
            return true
        end
        if not state.open then
            return false
        end
        if p then
            if over_palette then
                for i, h in ipairs(p.hits or {}) do
                    if P.inside(mx, my, h[1], h[2], h[3], h[4]) then
                        local col = PALETTE[i]
                        p.ctrl.set({r = col[1], g = col[2], b = col[3]})
                        changed()
                        break
                    end
                end
                state.palette = nil
                return true
            end
            state.palette = nil
            if not over_window then
                return false
            end
        end
        if not over_window then
            return false
        end
        if P.inside(mx, my, x + W - 30, y + 5, 22, 22) then
            M.close()
            return true
        end
        if my < y + TITLE_H then
            state.drag_window = {mx - x, my - y}
            return true
        end
        for i, t in ipairs(tabs) do
            if t.hit and P.inside(mx, my, t.hit[1], t.hit[2], t.hit[3], t.hit[4]) then
                state.tab = i
                return true
            end
        end
        for _, ctl in ipairs(tabs[state.tab].controls) do
            local h = ctl.hit
            if h and P.inside(mx, my, h[1], h[2], h[3], h[4]) then
                kinds[ctl.kind].click(ctl, mx, my)
                return true
            end
        end
        return true
    end

    if mtype == 10 and over_window then -- wheel over a slider adjusts it
        for _, ctl in ipairs(tabs[state.tab].controls) do
            local h = ctl.hit
            if ctl.kind == 'slider' and h and P.inside(mx, my, h[1] - 10, h[2] - 20, h[3] + 80, h[4] + 20) then
                kinds.slider.wheel(ctl, delta or 0)
                break
            end
        end
        return true
    end

    return over_window or over_gear or over_palette or false
end

function M.destroy()
    if not ui then
        return
    end
    P.panel_destroy(ui.panel)
    P.panel_destroy(ui.pal_panel)
    P.panel_destroy(ui.gear_panel)
    for _, k in ipairs({'title', 'close', 'sep', 'gear', 'help_sep', 'help'}) do
        pcall(function() ui[k]:destroy() end)
    end
    for i = 1, #tabs do
        pcall(function() ui.tab_bg[i]:destroy() end)
        pcall(function() ui.tab_text[i]:destroy() end)
        for _, c in ipairs(tabs[i].controls) do
            if c.p then
                for k, v in pairs(c.p) do
                    if k == 'segs' then
                        for _, sgm in ipairs(v) do
                            pcall(function() sgm.bg:destroy() end)
                            pcall(function() sgm.text:destroy() end)
                        end
                    else
                        pcall(function() v:destroy() end)
                    end
                end
            end
        end
    end
    for i = 1, #ui.pal do
        pcall(function() ui.pal[i]:destroy() end)
    end
    ui = nil
end

-- For tests.
M._state = state
M._tabs = function() return tabs end

return M
