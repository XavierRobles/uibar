_addon.name = 'uibar'
_addon.author = 'Waky'
_addon.version = '0.2.2'
_addon.commands = {'uibar', 'ub'}

require('strings')
require('tables')

local config = require('config')
local texts = require('texts')
local packets = require('packets')
local res = require('resources')
local defaults = require('uibardefaults')
local util = require('uibarutil')
local debuffs = require('uibardebuffs')
local status = require('uibarstatus')
local actiontracker = require('uibaractiontracker')
local mobdb = require('uibarmobdb')
local renderer = require('uibarrender')
local panels_mod = require('uibarpanels')
local graphics = require('uibargraphics')
local party = require('uibarparty')
local hate = require('uibarhate')
local casts = require('uibarcasts')
local gilw = require('uibargil')
local invw = require('uibarinventory')
local config_ui = require('uibarconfig')

local settings = config.load(defaults)

local state = {
    last_update = 0,
    last_expire_sweep = 0,
    mob_debuffs = {},
    mob_debuff_marks = {},
    target_buffs = {},
    mob_debuff_spell = {},
    mob_debuff_meta = {},
    mob_party_touch = {},
    last_cc_by_actor = {},
    enemy_target_cache = {},
    enemy_rows_cache = {},
    enemy_rows_next_at = 0,
    duration_overrides = settings.duration or {},
    retail_debug = false,
    last_drag_save = 0,
    mouse_x = 0,
    mouse_y = 0,
}
local actionparse = nil

local panels = panels_mod.create(settings)
local gstate = graphics.create(settings)
gilw.create()
invw.create()
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

local function lc(v)
    return string.lower(tostring(v or ''))
end

local function find_spell_ids_by_name(query)
    local q = lc(query)
    if q == '' then
        return {}
    end
    local exact = {}
    local partial = {}
    for id, sp in pairs(res.spells or {}) do
        local en = tostring(sp and sp.en or '')
        local enl = tostring(sp and sp.enl or '')
        local en_l = lc(en)
        local enl_l = lc(enl)
        local is_exact = (en_l == q) or (enl_l == q)
        local is_partial = (en_l:find(q, 1, true) ~= nil) or (enl_l:find(q, 1, true) ~= nil)
        if is_exact then
            exact[#exact + 1] = {id = id, name = (en ~= '' and en or enl)}
        elseif is_partial then
            partial[#partial + 1] = {id = id, name = (en ~= '' and en or enl)}
        end
    end
    local out = (#exact > 0) and exact or partial
    table.sort(out, function(a, b)
        return a.id < b.id
    end)
    return out
end

local function find_buff_ids_by_name(query)
    local q = lc(query)
    if q == '' then
        return {}
    end
    local exact = {}
    local partial = {}
    for id, bf in pairs(res.buffs or {}) do
        local en = tostring(bf and bf.en or '')
        local enl = tostring(bf and bf.enl or '')
        local en_l = lc(en)
        local enl_l = lc(enl)
        local is_exact = (en_l == q) or (enl_l == q)
        local is_partial = (en_l:find(q, 1, true) ~= nil) or (enl_l:find(q, 1, true) ~= nil)
        if is_exact then
            exact[#exact + 1] = {id = id, name = (en ~= '' and en or enl)}
        elseif is_partial then
            partial[#partial + 1] = {id = id, name = (en ~= '' and en or enl)}
        end
    end
    local out = (#exact > 0) and exact or partial
    table.sort(out, function(a, b)
        return a.id < b.id
    end)
    return out
end

local function ensure_duration_tables()
    settings.duration = settings.duration or {}
    settings.duration.spell = settings.duration.spell or {}
    settings.duration.buff = settings.duration.buff or {}
end

local function duration_entry_key(id)
    return 'id_' .. tostring(math.floor(tonumber(id or 0) or 0))
end

local function parse_duration_entry_seconds(value)
    local d = tonumber(value or 0) or 0
    if d > 0 then
        return math.floor(d)
    end
    if type(value) ~= 'string' then
        return nil
    end
    local n = tonumber((value:match('^%s*(%d+)') or '')) or 0
    if n > 0 then
        return math.floor(n)
    end
    return nil
end

local function duration_entry_name(kind, id)
    local n = tonumber(id or 0) or 0
    if n <= 0 then
        return nil
    end
    if kind == 'spell' then
        local sp = res.spells and res.spells[n] or nil
        return tostring((sp and (sp.en or sp.enl)) or n)
    end
    local bf = res.buffs and res.buffs[n] or nil
    return tostring((bf and (bf.en or bf.enl)) or n)
end

local function duration_entry_value(kind, id, secs)
    local s = math.floor(tonumber(secs or 0) or 0)
    local name = duration_entry_name(kind, id) or tostring(id)
    return string.format('%d | %s', s, name)
end

local function set_duration_override(kind, id, secs)
    ensure_duration_tables()
    local n = math.floor(tonumber(id or 0) or 0)
    local s = math.floor(tonumber(secs or 0) or 0)
    if n <= 0 or s <= 0 then
        return
    end
    settings.duration[kind][duration_entry_key(n)] = duration_entry_value(kind, n, s)
    settings.duration[kind][n] = nil
    settings.duration[kind][tostring(n)] = nil
end

local function clear_duration_override(kind, id)
    ensure_duration_tables()
    local n = math.floor(tonumber(id or 0) or 0)
    if n <= 0 then
        return
    end
    settings.duration[kind][n] = nil
    settings.duration[kind][tostring(n)] = nil
    settings.duration[kind][duration_entry_key(n)] = nil
end

local function sync_duration_entries()
    ensure_duration_tables()
    local changed = false

    local function normalize_kind(kind)
        local src = settings.duration[kind]
        if type(src) ~= 'table' then
            settings.duration[kind] = {}
            return true
        end
        local out = {}
        local local_changed = false
        for key, val in pairs(src) do
            local id = tonumber(key or 0) or 0
            if id <= 0 then
                id = tonumber((tostring(key):match('^id_(%d+)$') or '')) or 0
            end
            if id > 0 then
                local secs = parse_duration_entry_seconds(val)
                if secs and secs > 0 then
                    local entry_key = duration_entry_key(id)
                    local entry_val = duration_entry_value(kind, id, secs)
                    if out[entry_key] ~= entry_val then
                        out[entry_key] = entry_val
                    end
                    if tostring(key) ~= entry_key or tostring(val) ~= tostring(entry_val) then
                        local_changed = true
                    end
                else
                    local_changed = true
                end
            else
                local_changed = true
            end
        end
        settings.duration[kind] = out
        return local_changed
    end

    if normalize_kind('spell') then
        changed = true
    end
    if normalize_kind('buff') then
        changed = true
    end

    if settings.duration.labels ~= nil then
        settings.duration.labels = nil
        changed = true
    end

    return changed
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
    local widgets_unlocked = (not settings.drag_locked) and settings.enabled
    gilw.set_draggable(widgets_unlocked)
    invw.set_draggable(widgets_unlocked)
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
    settings.gil.x, settings.gil.y = defaults.gil.x, defaults.gil.y
    settings.inventory.x, settings.inventory.y = defaults.inventory.x, defaults.inventory.y
end

-- A failing handler would error on every packet/frame: report at most every 10s.
local last_error_at = -1000
local function report_error(tag, err)
    local t = os.clock()
    if t - last_error_at > 10 then
        last_error_at = t
        windower.add_to_chat(123, '[uibar] error (' .. tag .. '): ' .. tostring(err))
    end
end

local function safe(tag, fn)
    return function(...)
        local ok, a, b = pcall(fn, ...)
        if ok then
            return a, b
        end
        report_error(tag, a)
    end
end

-- Isolated so one failing module never starves the others.
local function guarded(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        report_error(tag, err)
    end
end

local learned_path = (windower.addon_path or '') .. 'data/learned_durations.lua'
local learned_written = nil

local function load_learned()
    local chunk = loadfile(learned_path)
    if not chunk then
        return
    end
    local ok, tbl = pcall(chunk)
    if ok then
        debuffs.import_learned_durations(tbl)
    end
end

local function save_learned()
    local tbl = debuffs.export_learned_durations()
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local lines = {'-- uibar learned debuff durations: [caster_id * 4096 + spell_id] = seconds. Safe to delete.', 'return {'}
    for _, k in ipairs(keys) do
        lines[#lines + 1] = string.format('    [%d] = %.1f,', k, tbl[k])
    end
    lines[#lines + 1] = '}'
    local body = table.concat(lines, '\n') .. '\n'
    if body == learned_written then
        return
    end
    local f = io.open(learned_path, 'w')
    if not f then
        return
    end
    f:write(body)
    f:close()
    learned_written = body
end

config_ui.create(settings, {
    save = function() save() end,
    drag_changed = function() update_drag_ui() end,
    refresh = function() update_drag_ui(); render() end,
    reset_positions = function() reset_positions(); save(); render() end,
    reset_learned = function() debuffs.reset_learned_durations(); save_learned() end,
    reset_gil = function() gilw.reset_session() end,
    refresh_enemies = function() state.enemy_rows_next_at = 0 end,
})

windower.register_event('load', function()
    load_learned()
    if sync_duration_entries() then
        save()
    end
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
    if party.invalidate_cache then
        party.invalidate_cache()
    end
    update_drag_ui()
    render()
end)

windower.register_event('login', function()
    util.invalidate_player()
end)

windower.register_event('logout', function()
    util.invalidate_player()
    save_learned()
end)

windower.register_event('zone change', safe('zone', function()
    state.mob_debuffs = {}
    state.mob_debuff_marks = {}
    state.target_buffs = {}
    state.mob_debuff_spell = {}
    state.mob_debuff_meta = {}
    state.mob_party_touch = {}
    state.last_cc_by_actor = {}
    state.enemy_target_cache = {}
    state.enemy_rows_cache = {}
    state.enemy_rows_next_at = 0
    state.last_expire_sweep = 0
    mobdb.on_zone_change()
    status.clear()
    actiontracker.clear()
    hate.clear()
    casts.clear()
    save_learned()
    if party.invalidate_cache then
        party.invalidate_cache()
    end
end))

windower.register_event('incoming chunk', safe('packet', function(id, data)
    if not data then
        return
    end
    local parsed_028 = nil
    if id == 0x028 then
        local p = windower and windower.packets and windower.packets.parse_action and windower.packets.parse_action(data) or nil
        if not p then
            p = packets.parse('incoming', data)
        end
        parsed_028 = p
        if state.retail_debug then
            local a = packets.parse('incoming', data)
            if not actionparse then
                actionparse = require('uibarpacketparse')
            end
            local b = actionparse and actionparse.parse_action_packet and actionparse.parse_action_packet(data) or nil
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
            guarded('debuffs', debuffs.apply_action, state, p, settings, windower)
            guarded('hate', hate.handle_action, p)
            local cat = tonumber(p.category or p.Category or 0) or 0
            local alt_ids = nil
            if cat == 7 or cat == 8 then
                -- Retail 0x028 layouts can disagree between parsers: offer every candidate id.
                alt_ids = {}
                pcall(function()
                    local a = packets.parse('incoming', data)
                    if a then
                        alt_ids[#alt_ids + 1] = tonumber(a['Target 1 Action 1 Param'] or 0) or 0
                    end
                end)
                pcall(function()
                    if not actionparse then
                        actionparse = require('uibarpacketparse')
                    end
                    local b = actionparse.parse_action_packet(data)
                    local bt = b and b.Targets and b.Targets[1]
                    local ba = bt and bt.Actions and bt.Actions[1]
                    if ba then
                        alt_ids[#alt_ids + 1] = tonumber(ba.Param or 0) or 0
                    end
                end)
            end
            guarded('casts', casts.handle_action, p, alt_ids)
        end
    end
    actiontracker.handle_chunk(id, data, packets, parsed_028)
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
    guarded('debuffs', debuffs.apply_basic_message, state, basic, windower)
    guarded('hate', hate.handle_message, basic)
    guarded('casts', casts.handle_message, basic)
end))

windower.register_event('prerender', safe('frame', function()
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

    if settings.enabled and settings.graphics.enabled then
        graphics.update(gstate, settings, state, mobdb, state.mouse_x, state.mouse_y)
    else
        graphics.hide(gstate)
    end

    if settings.enabled then
        if not settings.drag_locked then
            for _, w in ipairs({{gilw, settings.gil}, {invw, settings.inventory}}) do
                local nx, ny = w[1].dragged_pos()
                if nx and w[2] then
                    w[2].x, w[2].y = nx, ny
                    state.widget_save_pending = true
                end
            end
        end
        if state.widget_save_pending and t - state.last_drag_save > 0.5 then
            save()
            state.last_drag_save = t
            state.widget_save_pending = false
        end
        gilw.update(settings, state.mouse_x, state.mouse_y)
        invw.update(settings, state.mouse_x, state.mouse_y)
    else
        gilw.hide()
        invw.hide()
    end

    -- Throttle heavy logic/text updates.
    if t - state.last_update >= settings.update_interval then
        state.last_update = t
        if t - (state.last_expire_sweep or 0) >= 0.75 then
            debuffs.clear_expired(state)
            state.last_expire_sweep = t
        end
        if not settings.graphics.enabled then
            render()
        end
    end

    -- Settings window: available even with the addon disabled.
    config_ui.update(state.mouse_x, state.mouse_y)
end))

windower.register_event('mouse', function(type, x, y, delta, blocked)
    if x and y then
        state.mouse_x = x
        state.mouse_y = y
    end
    local ok, consumed = pcall(config_ui.mouse, type, x, y, delta)
    if not ok then
        report_error('config', consumed)
        return false
    end
    return consumed and true or false
end)

windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    local a = args[1]
    local b = args[2]
    local c = args[3]
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
        if (panel == 'gil' or panel == 'inv') and x and y then
            local cfg = panel == 'gil' and settings.gil or settings.inventory
            cfg.x, cfg.y = math.floor(x), math.floor(y)
            save()
            windower.add_to_chat(207, string.format('[uibar] %s movido a %d, %d.', panel, cfg.x, cfg.y))
            return
        end
        if (panel ~= 'target' and panel ~= 'enemy') or not x or not y then
            windower.add_to_chat(123, '[uibar] Uso: //uibar pos target|enemy|gil|inv <x> <y>')
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

    if cmd == 'debug' then
        state.retail_debug = not state.retail_debug
        windower.add_to_chat(207, '[uibar] debug = ' .. tostring(state.retail_debug))
        return
    end

    if cmd == 'config' or cmd == 'cfg' or cmd == 'menu' then
        config_ui.toggle()
        return
    end

    if cmd == 'gil' or cmd == 'inv' then
        local cfg = cmd == 'gil' and settings.gil or settings.inventory
        local v = (a or ''):lower()
        if v == 'on' or v == 'off' then
            cfg.enabled = (v == 'on')
        else
            cfg.enabled = not cfg.enabled
        end
        save()
        windower.add_to_chat(207, '[uibar] ' .. cmd .. ' = ' .. tostring(cfg.enabled))
        return
    end

    if cmd == 'gilreset' then
        gilw.reset_session()
        windower.add_to_chat(207, '[uibar] sesion de gil reiniciada')
        return
    end

    if cmd == 'hatedebug' then
        hate.debug = not hate.debug
        windower.add_to_chat(207, '[uibar] hatedebug = ' .. tostring(hate.debug))
        return
    end

    if cmd == 'castdebug' then
        casts.debug = not casts.debug
        windower.add_to_chat(207, '[uibar] castdebug = ' .. tostring(casts.debug))
        return
    end

    if cmd == 'learnreset' then
        debuffs.reset_learned_durations()
        save_learned()
        windower.add_to_chat(207, '[uibar] duraciones aprendidas borradas')
        return
    end

    if cmd == 'sort' then
        local mode = string.lower(tostring(a or ''))
        if mode ~= 'aggro' and mode ~= 'distance' and mode ~= 'hp' then
            windower.add_to_chat(123, '[uibar] Uso: //uibar sort aggro|distance|hp')
            return
        end
        settings.enemy_sort = mode
        state.enemy_rows_next_at = 0
        save()
        render()
        windower.add_to_chat(207, '[uibar] enemy_sort = ' .. mode)
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

    if cmd == 'durspell' then
        local sid = tonumber(a)
        local secs = tonumber(b)
        if not sid or sid <= 0 or not secs or secs <= 0 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar durspell <spell_id> <segundos>')
            return
        end
        sid = math.floor(sid)
        secs = math.floor(secs)
        set_duration_override('spell', sid, secs)
        state.duration_overrides = settings.duration
        save()
        local sp = res.spells[sid]
        windower.add_to_chat(207, string.format('[uibar] duration.spell[%d] = %d (%s)', sid, secs, tostring(sp and sp.en or '?')))
        return
    end

    if cmd == 'durbuff' then
        local bid = tonumber(a)
        local secs = tonumber(b)
        if not bid or bid <= 0 or not secs or secs <= 0 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar durbuff <buff_id> <segundos>')
            return
        end
        bid = math.floor(bid)
        secs = math.floor(secs)
        set_duration_override('buff', bid, secs)
        state.duration_overrides = settings.duration
        save()
        local bf = res.buffs[bid]
        windower.add_to_chat(207, string.format('[uibar] duration.buff[%d] = %d (%s)', bid, secs, tostring(bf and bf.en or '?')))
        return
    end

    if cmd == 'durclear' then
        local kind = (a or ''):lower()
        local id = tonumber(b)
        if (kind ~= 'spell' and kind ~= 'buff') or not id or id <= 0 then
            windower.add_to_chat(123, '[uibar] Uso: //uibar durclear spell|buff <id>')
            return
        end
        id = math.floor(id)
        clear_duration_override(kind, id)
        state.duration_overrides = settings.duration
        save()
        windower.add_to_chat(207, string.format('[uibar] duration.%s[%d] borrado.', kind, id))
        return
    end

    if cmd == 'durreset' then
        settings.duration = {
            spell = {},
            buff = {},
        }
        state.duration_overrides = settings.duration
        save()
        windower.add_to_chat(207, '[uibar] duration overrides reseteados.')
        return
    end

    if cmd == 'spellid' then
        local query = table.concat(args, ' ')
        if query == '' then
            windower.add_to_chat(123, '[uibar] Uso: //uibar spellid <nombre>')
            return
        end
        local matches = find_spell_ids_by_name(query)
        if #matches == 0 then
            windower.add_to_chat(123, '[uibar] No se encontro spell para: ' .. tostring(query))
            return
        end
        local max_show = math.min(8, #matches)
        for i = 1, max_show do
            local m = matches[i]
            windower.add_to_chat(207, string.format('[uibar] spellid %d = %s', m.id, tostring(m.name or '?')))
        end
        if #matches > max_show then
            windower.add_to_chat(207, string.format('[uibar] ... %d resultados mas', #matches - max_show))
        end
        return
    end

    if cmd == 'buffid' then
        local query = table.concat(args, ' ')
        if query == '' then
            windower.add_to_chat(123, '[uibar] Uso: //uibar buffid <nombre>')
            return
        end
        local matches = find_buff_ids_by_name(query)
        if #matches == 0 then
            windower.add_to_chat(123, '[uibar] No se encontro buff para: ' .. tostring(query))
            return
        end
        local max_show = math.min(8, #matches)
        for i = 1, max_show do
            local m = matches[i]
            windower.add_to_chat(207, string.format('[uibar] buffid %d = %s', m.id, tostring(m.name or '?')))
        end
        if #matches > max_show then
            windower.add_to_chat(207, string.format('[uibar] ... %d resultados mas', #matches - max_show))
        end
        return
    end

    windower.add_to_chat(123, '[uibar] Comandos: //uibar config (menu)|on|off|toggle|reset|pos target|enemy <x> <y>|max <1-20>|range <0-120>|sort aggro|distance|hp|gfx on|off|tsize <w> [h]|isize <n>|irow <n>|drag on|off|toggle|lock on|off|toggle|durspell <spell_id> <s>|durbuff <buff_id> <s>|durclear spell|buff <id>|durreset|spellid <nombre>|buffid <nombre>|gil on|off|inv on|off|gilreset|pos gil|inv <x> <y>|learnreset|debug|castdebug|hatedebug')
end)

windower.register_event('unload', function()
    save_learned()
    panels_mod.hide_all(panels)
    graphics.hide(gstate)
    graphics.destroy(gstate)
    gilw.destroy()
    invw.destroy()
    config_ui.destroy()
    drag_anchor:visible(false)
    drag_anchor:destroy()
end)
