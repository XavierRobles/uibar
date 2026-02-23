_addon.name = 'uibar'
_addon.author = 'Xavie'
_addon.version = '0.2.1'
_addon.commands = {'uibar', 'ub'}

require('strings')
require('tables')

local config = require('config')
local texts = require('texts')
local packets = require('packets')
local defaults = require('uibardefaults')
local util = require('uibarutil')
local debuffs = require('uibardebuffs')
local status = require('uibarstatus')
local actiontracker = require('uibaractiontracker')
local actionparse = require('uibarpacketparse')
local mobdb = require('uibarmobdb')
local renderer = require('uibarrender')
local panels_mod = require('uibarpanels')
local graphics = require('uibargraphics')

local settings = config.load(defaults)

local state = {
    last_update = 0,
    mob_debuffs = {},
    mob_debuff_marks = {},
    target_buffs = {},
    mob_debuff_spell = {},
    mob_party_touch = {},
    enemy_target_cache = {},
    enemy_rows_cache = {},
    enemy_rows_next_at = 0,
    retail_debug = true,
    last_drag_save = 0,
    mouse_x = 0,
    mouse_y = 0,
}

local panels = panels_mod.create(settings)
local gstate = graphics.create(settings)
local drag_anchor = texts.new('                      ', {
    pos = {x = settings.target.x, y = settings.target.y - 20},
    text = {
        font = 'Consolas',
        size = 9,
        alpha = 0,
        red = 240,
        green = 225,
        blue = 140,
        stroke = {width = 0, alpha = 0, red = 0, green = 0, blue = 0},
    },
    bg = {
        alpha = 0,
        red = 0,
        green = 0,
        blue = 0,
        visible = false,
    },
    flags = {
        right = false,
        bottom = false,
        bold = true,
        draggable = false,
    },
    padding = 2,
})

local function save()
    config.save(settings)
end

local cc_spell_debug = {
    [253] = true, [273] = true, [363] = true, -- Sleep/Sleepga/Sleepga II
    [259] = true, [274] = true, [364] = true, -- Sleep II/Sleepga II/Sleepga III
    [376] = true, [377] = true,               -- Foe Lullaby I/II
    [463] = true, [464] = true,               -- Horde Lullaby I/II
}

local cc_buff_debug = {
    [2] = true, [19] = true, [193] = true,
}

local function packet_spell_id(pkt)
    return tonumber((pkt and (pkt.Param or pkt.param or pkt.Param_1 or pkt.param_1)) or 0) or 0
end

local function packet_type(pkt)
    return tonumber((pkt and (pkt.Type or pkt.type or pkt.category)) or 0) or 0
end

local function summarize_targets(pkt)
    local ts = pkt and (pkt.targets or pkt.Targets)
    if type(ts) ~= 'table' then
        return 0, '-'
    end
    local count = 0
    local out = {}
    for _, t in pairs(ts) do
        local tid = tonumber((t and (t.id or t.Id)) or 0) or 0
        if tid > 0 then
            count = count + 1
            if #out < 6 then
                local acts = t.actions or t.Actions
                local ac = 0
                local msg = 0
                local prm = 0
                if type(acts) == 'table' then
                    for _, a in pairs(acts) do
                        ac = ac + 1
                        if msg == 0 then
                            msg = tonumber((a and (a.Message or a.message)) or 0) or 0
                            prm = tonumber((a and (a.Param or a.param)) or 0) or 0
                        end
                    end
                end
                local m = windower.ffxi.get_mob_by_id(tid)
                local nm = tostring((m and m.name) or '?')
                out[#out + 1] = string.format('%s[%d]a%d m%d p%d', nm, tid, ac, msg, prm)
            end
        end
    end
    return count, (#out > 0 and table.concat(out, ' | ') or '-')
end

local function update_drag_ui()
    local unlocked = (not settings.drag_locked) and settings.enabled and settings.graphics.enabled
    drag_anchor:draggable(false)
    drag_anchor:visible(false)

    if gstate and gstate.target_hp and gstate.target_hp.bg then
        gstate.target_hp.bg:draggable(unlocked)
    end
    if gstate and gstate.enemy_drag then
        gstate.enemy_drag:draggable(unlocked)
    end
end

local function render()
    panels.target:visible(false)
    panels.enemy:visible(settings.enabled and (not settings.graphics.enabled))
    panels.main:visible(false)
    if not settings.enabled then
        graphics.hide(gstate)
        update_drag_ui()
        return
    end

    if not settings.graphics.enabled then
        panels.enemy:text(renderer.format_enemy_list(settings, state))
    end
    update_drag_ui()
end

local function reset_positions()
    panels_mod.move(panels, settings, 'target', defaults.target.x, defaults.target.y)
    panels_mod.move(panels, settings, 'enemy', defaults.enemy.x, defaults.enemy.y)
end

windower.register_event('load', function()
    if (tonumber(settings.target.x) or 0) < 0 or (tonumber(settings.target.y) or 0) < 0 then
        settings.target.x = defaults.target.x
        settings.target.y = defaults.target.y
        save()
    end
    if (tonumber(settings.enemy.x) or 0) < 0 or (tonumber(settings.enemy.y) or 0) < 0 or (tonumber(settings.enemy.y) or 0) > 1200 then
        settings.enemy.x = defaults.enemy.x
        settings.enemy.y = defaults.enemy.y
        save()
    end
    mobdb.on_zone_change()
    status.clear()
    actiontracker.clear()
    update_drag_ui()
    render()
end)

windower.register_event('zone change', function()
    state.mob_debuffs = {}
    state.mob_debuff_marks = {}
    state.target_buffs = {}
    state.mob_debuff_spell = {}
    state.mob_party_touch = {}
    state.enemy_target_cache = {}
    state.enemy_rows_cache = {}
    state.enemy_rows_next_at = 0
    mobdb.on_zone_change()
    status.clear()
    actiontracker.clear()
end)

windower.register_event('action', function(act)
    actiontracker.handle_action(act)
end)

windower.register_event('incoming chunk', function(id, data)
    if not data then
        return
    end
    if id == 0x028 then
        local p = windower and windower.packets and windower.packets.parse_action and windower.packets.parse_action(data) or nil
        local a = packets.parse('incoming', data)
        local b = actionparse.parse_action_packet(data)
        if state.retail_debug then
            local sp = packet_spell_id(p)
            local sa = packet_spell_id(a)
            local sb = packet_spell_id(b)
            if cc_spell_debug[sp] or cc_spell_debug[sa] or cc_spell_debug[sb] then
                local cp, dp = summarize_targets(p)
                local ca, da = summarize_targets(a)
                local cb, db = summarize_targets(b)
                windower.add_to_chat(123, string.format('[uibar][rdbg028] P(sp=%d ty=%d t=%d) %s || A(sp=%d ty=%d t=%d) %s || B(sp=%d ty=%d t=%d) %s',
                    sp, packet_type(p), cp, dp,
                    sa, packet_type(a), ca, da,
                    sb, packet_type(b), cb, db))
            end
        end
        if p then
            debuffs.apply_action(state, p, settings, windower)
        else
            if a then
                debuffs.apply_action(state, a, settings, windower)
            end
            if b then
                debuffs.apply_action(state, b, settings, windower)
            end
        end
    end
    actiontracker.handle_chunk(id, data, packets)
    status.handlechunk(id, data, packets)
    if id ~= 0x029 then
        return
    end
    local p = packets.parse('incoming', data)
    local raw_msg = p and (p.Message or p['Message ID'] or p.message_id) or data:unpack('H', 0x19)
    local basic = {
        actor_id = p and (p.Actor or p['Actor ID'] or p.actor_id or p.User or p['Source ID']) or data:unpack('I', 0x05),
        target_id = p and (p.Target or p['Target ID'] or p.target_id) or data:unpack('I', 0x09),
        param_1 = p and (p.Param_1 or p['Param 1'] or p.param_1) or data:unpack('I', 0x0D),
        param = p and (p.Param or p.param) or data:unpack('I', 0x0D),
        value = p and (p.Value or p.value) or data:unpack('I', 0x11),
        message_id = (tonumber(raw_msg or 0) or 0) % 32768,
    }
    if state.retail_debug then
        local b = tonumber(basic.param or basic.param_1 or basic.value or 0) or 0
        if cc_buff_debug[b] then
            local tm = windower.ffxi.get_mob_by_id(tonumber(basic.target_id or 0) or 0)
            local am = windower.ffxi.get_mob_by_id(tonumber(basic.actor_id or 0) or 0)
            windower.add_to_chat(123, string.format('[uibar][rdbg029] msg=%d buff=%d actor=%d(%s) target=%d(%s)',
                tonumber(basic.message_id or 0) or 0,
                b,
                tonumber(basic.actor_id or 0) or 0, tostring((am and am.name) or '?'),
                tonumber(basic.target_id or 0) or 0, tostring((tm and tm.name) or '?')))
        end
    end
    debuffs.apply_basic_message(state, basic, windower)
end)

windower.register_event('prerender', function()
    local t = util.frame_now()
    if settings.enabled and settings.graphics.enabled and (not settings.drag_locked) then
        local target_bar_visible = false
        if gstate and gstate.target_hp and gstate.target_hp.bg and gstate.target_hp.bg.visible then
            target_bar_visible = gstate.target_hp.bg:visible()
        end
        if target_bar_visible then
            local bx, by = gstate.target_hp.bg:pos()
            if bx and by then
                local tx = math.floor(bx)
                local ty = math.floor(by - 18)
                if tx ~= settings.target.x or ty ~= settings.target.y then
                    settings.target.x = tx
                    settings.target.y = ty
                    if t - state.last_drag_save > 0.5 then
                        save()
                        state.last_drag_save = t
                    end
                end
            end
        end

        if gstate and gstate.enemy_drag and gstate.enemy_drag:visible() then
            local ex, ey = gstate.enemy_drag:pos()
            if ex and ey then
                local nx = math.floor(ex)
                local ny = math.floor(ey + 10)
                if nx ~= settings.enemy.x or ny ~= settings.enemy.y then
                    settings.enemy.x = nx
                    settings.enemy.y = ny
                    if t - state.last_drag_save > 0.5 then
                        save()
                        state.last_drag_save = t
                    end
                end
            end
        end
    end

    -- Keep graphical animations smooth by updating them every frame.
    if settings.enabled and settings.graphics.enabled then
        graphics.update(gstate, settings, state, mobdb, state.mouse_x, state.mouse_y)
    else
        graphics.hide(gstate)
    end

    -- Throttle heavy logic/text updates.
    if t - state.last_update >= settings.update_interval then
        state.last_update = t
        debuffs.clear_expired(state)
        render()
    end

end)

windower.register_event('mouse', function(type, x, y)
    if x and y then
        state.mouse_x = x
        state.mouse_y = y
    end
    return false
end)

windower.register_event('addon command', function(cmd, a, b, c)
    cmd = (cmd or 'help'):lower()

    if cmd == 'on' then
        settings.enabled = true
        save()
        render()
        windower.add_to_chat(207, '[uibar] Activado.')
        return
    end

    if cmd == 'off' then
        settings.enabled = false
        save()
        render()
        windower.add_to_chat(207, '[uibar] Desactivado.')
        return
    end

    if cmd == 'toggle' then
        settings.enabled = not settings.enabled
        save()
        render()
        windower.add_to_chat(207, '[uibar] ' .. (settings.enabled and 'Activado.' or 'Desactivado.'))
        return
    end

    if cmd == 'reset' then
        reset_positions()
        save()
        render()
        windower.add_to_chat(207, '[uibar] Posiciones reseteadas.')
        return
    end

    if cmd == 'pos' then
        local panel = (a or ''):lower()
        local x = tonumber(b)
        local y = tonumber(c)
        if (panel ~= 'target' and panel ~= 'enemy') or not x or not y then
            windower.add_to_chat(123, '[uibar] Uso: //uibar pos target|enemy <x> <y>')
            return
        end

        panels_mod.move(panels, settings, panel, x, y)
        save()
        render()
        windower.add_to_chat(207, string.format('[uibar] %s movido a %d, %d.', panel, settings[panel].x, settings[panel].y))
        return
    end

    if cmd == 'max' then
        local n = tonumber(a)
        if not n or n < 1 or n > 20 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar max <1-20>')
            return
        end
        settings.max_enemies = math.floor(n)
        save()
        render()
        windower.add_to_chat(207, '[uibar] max_enemies = ' .. tostring(settings.max_enemies))
        return
    end

    if cmd == 'range' then
        local n = tonumber(a)
        if not n or n < 0 or n > 120 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar range <0-120> (0 = sin limite)')
            return
        end
        settings.enemy_scan_range = n
        save()
        render()
        if n == 0 then
            windower.add_to_chat(207, '[uibar] enemy_scan_range = sin limite (solo mobs con aggro)')
        else
            windower.add_to_chat(207, '[uibar] enemy_scan_range = ' .. tostring(settings.enemy_scan_range))
        end
        return
    end

    if cmd == 'gfx' then
        local mode = (a or 'toggle'):lower()
        if mode == 'on' then
            settings.graphics.enabled = true
        elseif mode == 'off' then
            settings.graphics.enabled = false
        else
            settings.graphics.enabled = not settings.graphics.enabled
        end
        save()
        render()
        windower.add_to_chat(207, '[uibar] graphics = ' .. tostring(settings.graphics.enabled))
        return
    end

    if cmd == 'tsize' then
        local w = tonumber(a)
        local h = tonumber(b)
        if not w or w < 180 or w > 900 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar tsize <180-900> [alto 6-28]')
            return
        end
        settings.graphics.bar.width = math.floor(w)
        if h then
            if h < 6 or h > 28 then
                windower.add_to_chat(123, '[uibar] Alto fuera de rango (6-28).')
                return
            end
            settings.graphics.bar.height = math.floor(h)
        end
        save()
        render()
        windower.add_to_chat(207, string.format('[uibar] target bar size = %dx%d', settings.graphics.bar.width, settings.graphics.bar.height))
        return
    end

    if cmd == 'isize' then
        local n = tonumber(a)
        if not n or n < 12 or n > 48 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar isize <12-48>')
            return
        end
        settings.graphics.icons.size = math.floor(n)
        save()
        render()
        windower.add_to_chat(207, '[uibar] icon size = ' .. tostring(settings.graphics.icons.size))
        return
    end

    if cmd == 'irow' then
        local n = tonumber(a)
        if not n or n < 4 or n > 24 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar irow <4-24>')
            return
        end
        settings.graphics.icons.per_row = math.floor(n)
        save()
        render()
        windower.add_to_chat(207, '[uibar] icons per row = ' .. tostring(settings.graphics.icons.per_row))
        return
    end

    if cmd == 'drag' then
        local mode = (a or 'toggle'):lower()
        if mode == 'on' then
            settings.drag_locked = false
        elseif mode == 'off' then
            settings.drag_locked = true
        else
            settings.drag_locked = not settings.drag_locked
        end
        save()
        update_drag_ui()
        return
    end

    if cmd == 'lock' then
        local mode = (a or 'toggle'):lower()
        if mode == 'on' then
            settings.drag_locked = true
        elseif mode == 'off' then
            settings.drag_locked = false
        else
            settings.drag_locked = not settings.drag_locked
        end
        save()
        update_drag_ui()
        windower.add_to_chat(207, '[uibar] lock = ' .. tostring(settings.drag_locked))
        return
    end

    windower.add_to_chat(123, '[uibar] Comandos: //uibar on|off|toggle|reset|pos target|enemy <x> <y>|max <1-20>|range <0-120>|gfx on|off|tsize <w> [h]|isize <n>|irow <n>|drag on|off|toggle|lock on|off|toggle')
end)

windower.register_event('unload', function()
    panels_mod.hide_all(panels)
    graphics.hide(gstate)
    graphics.destroy(gstate)
    drag_anchor:visible(false)
    drag_anchor:destroy()
end)
