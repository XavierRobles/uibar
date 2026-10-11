local images = require('images')
local texts = require('texts')
local res = require('resources')
local debuffs = require('uibardebuffs')
local party = require('uibarparty')
local status = require('uibarstatus')
local actiontracker = require('uibaractiontracker')
local hate = require('uibarhate')
local casts = require('uibarcasts')
local util = require('uibarutil')

local M = {}

-- Cached setters (uibarprim): never call obj:pos/show/... directly on these objects.
local P = require('uibarprim')
local g_pos, g_size, g_path, g_color, g_alpha = P.pos, P.size, P.path, P.color, P.alpha
local g_show, g_hide, g_text, g_extents = P.show, P.hide, P.text, P.extents

local debuff_priority = {
    [173] = 0, -- dread spikes (enemy hazard)
    [2] = 1,   -- sleep
    [19] = 1,  -- sleep ii
    [10] = 2,  -- stun
    [4] = 3,   -- paralyze
    [13] = 4,  -- slow/elegy mapped
    [6] = 5,   -- silence
    [11] = 6,  -- bind
    [12] = 7,  -- weight/gravity
    [134] = 8, -- dia
    [135] = 9, -- bio
    [3] = 10,  -- poison
}

local TARGET_NAME_COLORS = {
    PARTY = {170, 240, 255},
    ALLIANCE = {135, 185, 255},
    WHITE = {255, 255, 255},
    GREEN = {64, 255, 128},
    YELLOW = {240, 232, 160},
    RED = {255, 64, 64},
    PURPLE = {190, 100, 220},
    PINK = {255, 160, 200},
    CFH = {233, 174, 102},
}

local function health_color(pct)
    if pct >= 75 then
        return 90, 220, 120
    elseif pct >= 45 then
        return 220, 200, 95
    elseif pct >= 20 then
        return 240, 140, 70
    end
    return 230, 75, 75
end

local function pct_to_width(value, max_value, width)
    if max_value <= 0 then
        return 0
    end
    local pct = math.max(0, math.min(1, value / max_value))
    return math.floor(width * pct + 0.5)
end

local function zero_pad3(n)
    if n < 10 then
        return '00' .. tostring(n)
    elseif n < 100 then
        return '0' .. tostring(n)
    end
    return tostring(n)
end

-- Fallbacks; user colours live in settings.colors.
local DEFAULT_COLORS = {
    cast_spell = {175, 135, 255}, -- magic
    cast_tp = {255, 150, 60},     -- TP move / ability readies
    cast_sp = {255, 70, 70},      -- two-hour / SP ability used
    timer_warn = {255, 90, 90},   -- about to wear off
    timer_other = {150, 200, 255},-- another player's debuff
}
local cur_settings = nil -- set at the start of M.update

local function color_of(key)
    local c = cur_settings and cur_settings.colors and cur_settings.colors[key]
    if type(c) == 'table' and c.r then
        return tonumber(c.r) or 0, tonumber(c.g) or 0, tonumber(c.b) or 0
    end
    local d = DEFAULT_COLORS[key]
    return d[1], d[2], d[3]
end

local function timer_color(remaining, mine)
    local warn = tonumber(cur_settings and cur_settings.timer_warn_secs or 5) or 5
    if (remaining or 0) <= warn then
        return color_of('timer_warn')
    elseif mine == false then
        return color_of('timer_other')
    end
    return 245, 245, 245
end

local function cast_color(c)
    if c.interrupted then
        return 255, 255, 255
    end
    return color_of('cast_' .. (c.kind or 'spell'))
end

local function casts_enabled()
    return not (cur_settings and cur_settings.casts and cur_settings.casts.enabled == false)
end

local function make_bar(name)
    local shadow = images.new(name .. '_shadow')
    local border = images.new(name .. '_border')
    local bg = images.new(name .. '_bg')
    local fg = images.new(name .. '_fg')
    local dmg = images.new(name .. '_dmg')
    local heal = images.new(name .. '_heal')

    for _, prim in ipairs({shadow, border, bg, fg, dmg, heal}) do
        prim:draggable(false)
        prim:fit(true)
        g_hide(prim)
    end

    g_color(shadow, 0, 0, 0)
    g_alpha(shadow, 110)
    g_color(border, 8, 12, 18)
    g_alpha(border, 230)
    g_color(bg, 35, 38, 45)
    g_alpha(bg, 240)
    g_color(dmg, 255, 40, 40)
    g_alpha(dmg, 190)
    g_color(heal, 40, 255, 80)
    g_alpha(heal, 190)

    return {shadow = shadow, border = border, bg = bg, fg = fg, dmg = dmg, heal = heal}
end

local function make_text(color)
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {
            font = 'Consolas',
            size = 10,
            alpha = 255,
            red = color[1],
            green = color[2],
            blue = color[3],
            stroke = {width = 2, alpha = 190, red = 0, green = 0, blue = 0},
        },
        bg = {visible = false},
        flags = {bold = true, right = false},
    })
    g_hide(t)
    return t
end

local function make_small_text(color)
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {
            font = 'Consolas',
            size = 8,
            alpha = 255,
            red = color[1],
            green = color[2],
            blue = color[3],
            stroke = {width = 2, alpha = 190, red = 0, green = 0, blue = 0},
        },
        bg = {visible = false},
        flags = {bold = true, right = false},
    })
    g_hide(t)
    return t
end

local function short_name(name, max_len)
    local s = tostring(name or '')
    local n = max_len or 18
    if #s <= n then
        return s
    end
    return s:sub(1, math.max(1, n - 3)) .. '...'
end

local function get_target_of_target(target)
    local ok, out = pcall(function()
        if not target then
            return nil
        end

        local ffxi = windower and windower.ffxi or nil
        local get_by_index = ffxi and ffxi.get_mob_by_index or nil
        local get_by_id = ffxi and ffxi.get_mob_by_id or nil
        local get_array = ffxi and ffxi.get_mob_array or nil
        if type(get_by_index) ~= 'function' then
            return nil
        end

        local function to_i(v)
            return tonumber(v or 0) or 0
        end

        local function resolve_party_by_index(idx)
            local p = ffxi and ffxi.get_party and ffxi.get_party() or nil
            if type(p) ~= 'table' then
                return nil
            end
            for _, m in pairs(p) do
                if type(m) == 'table' then
                    local midx = to_i((m.mob and m.mob.index) or m.index)
                    if midx > 0 and midx == idx then
                        return {
                            id = to_i((m.mob and m.mob.id) or m.id),
                            index = midx,
                            name = m.name,
                            is_npc = false,
                        }
                    end
                end
            end
            return nil
        end

        local function resolve_by_index(idx)
            if idx <= 0 then
                return nil
            end
            local m = get_by_index(idx)
            if m and m.name and m.name ~= '' then
                return m
            end
            return resolve_party_by_index(idx)
        end

        local function mob_from_target_fields(t)
            local tix = to_i(t and (
                t.target_index or t.targ_index or t['Target Index'] or
                t.TargetedIndex or t.targeted_index or t['Targeted Index']
            ))
            if tix > 0 then
                local m = resolve_by_index(tix)
                if m and m.name and m.name ~= '' then
                    return m
                end
            end

            local tid = to_i(t and (
                t.target_id or t.targ_id or t['Target ID'] or
                t.TargetedId or t.targeted_id or t['Targeted ID'] or
                t.target
            ))
            if tid > 0 and type(get_by_id) == 'function' then
                local m = get_by_id(tid)
                if m and m.name and m.name ~= '' then
                    return m
                end
            end

            -- Some mob tables expose `target` as index, not id.
            local traw = to_i(t and t.target)
            if traw > 0 then
                local mi = resolve_by_index(traw)
                if mi and mi.name and mi.name ~= '' then
                    return mi
                end
                if type(get_by_id) == 'function' then
                    local md = get_by_id(traw)
                    if md and md.name and md.name ~= '' then
                        return md
                    end
                end
            end
            return nil
        end

        local function mob_from_array_fallback(t)
            if type(get_array) ~= 'function' then
                return nil
            end
            local arr = get_array()
            if type(arr) ~= 'table' then
                return nil
            end

            local sid = to_i(t and t.id)
            local sidx = to_i(t and t.index)
            local src = nil

            if sidx > 0 and type(arr[sidx]) == 'table' then
                src = arr[sidx]
            end
            if not src and sid > 0 then
                for _, m in pairs(arr) do
                    if type(m) == 'table' and to_i(m.id) == sid then
                        src = m
                        break
                    end
                end
            end
            if not src then
                return nil
            end

            local tix = to_i(src.target_index or src.targ_index or src['Target Index'])
            if tix > 0 then
                local direct = resolve_by_index(tix)
                if direct and direct.name and direct.name ~= '' then
                    return direct
                end
                if type(arr[tix]) == 'table' and arr[tix].name and arr[tix].name ~= '' then
                    return arr[tix]
                end
                for _, m in pairs(arr) do
                    if type(m) == 'table' and to_i(m.index) == tix and m.name and m.name ~= '' then
                        return m
                    end
                end
            end

            local tid = to_i(src.target_id or src.targ_id or src['Target ID'] or src.target)
            if tid > 0 then
                for _, m in pairs(arr) do
                    if type(m) == 'table' and to_i(m.id) == tid and m.name and m.name ~= '' then
                        return m
                    end
                end
            end

            return nil
        end

        local direct = mob_from_target_fields(target)
        if direct then
            return direct
        end

        -- Action tracking is the most reliable ToT source for mobs.
        local actor_id = to_i(target.id)
        if target.is_npc and actor_id > 0 and actiontracker and actiontracker.get_last_target_index then
            local atix = to_i(actiontracker.get_last_target_index(actor_id))
            if atix > 0 then
                local am = resolve_by_index(atix)
                if am and am.name and am.name ~= '' then
                    return am
                end
            end
        end

        local idx = to_i(target.index)
        if idx > 0 then
            local full = get_by_index(idx)
            local m = mob_from_target_fields(full)
            if m then
                return m
            end
        end

        local sid = to_i(target.id)
        local sidx = to_i(target.index)
        if sid > 0 and type(get_by_id) == 'function' then
            local full = get_by_id(sid)
            local m = mob_from_target_fields(full)
            if m then
                return m
            end
        end

        if type(get_array) == 'function' then
            local arr = get_array()
            if type(arr) == 'table' then
                local sid2 = to_i(target.id)
                local sidx2 = to_i(target.index)
                if sid2 > 0 then
                    for _, msrc in pairs(arr) do
                        if type(msrc) == 'table' and (to_i(msrc.id) == sid2 or (sidx2 > 0 and to_i(msrc.index) == sidx2)) then
                            local tix2 = to_i(msrc.target_index or msrc.targ_index or msrc['Target Index'])
                            if tix2 > 0 then
                                local m2 = resolve_by_index(tix2)
                                if m2 and m2.name and m2.name ~= '' then
                                    return m2
                                end
                            end

                            local tid2 = to_i(msrc.target_id or msrc.targ_id or msrc['Target ID'] or msrc.target)
                            if tid2 > 0 then
                                local m2 = resolve_by_index(tid2)
                                if m2 and m2.name and m2.name ~= '' then
                                    return m2
                                end
                                if type(get_by_id) == 'function' then
                                    local m3 = get_by_id(tid2)
                                    if m3 and m3.name and m3.name ~= '' then
                                        return m3
                                    end
                                end
                            end
                            break
                        end
                    end
                end
            end
        end

        local arr_fallback = mob_from_array_fallback(target)
        if arr_fallback then
            return arr_fallback
        end

        return nil
    end)
    if not ok then
        return nil
    end
    return out
end

local function make_timer_text()
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {
            font = 'Consolas',
            size = 7,
            alpha = 255,
            red = 245,
            green = 245,
            blue = 245,
            stroke = {width = 2, alpha = 190, red = 0, green = 0, blue = 0},
        },
        bg = {visible = false},
        flags = {bold = true, right = false},
    })
    g_hide(t)
    return t
end

local function debuff_tier_label(buff_id, mark)
    if type(mark) == 'string' and mark ~= '' then
        return mark
    end
    if tonumber(buff_id or 0) == 19 then
        return '2' -- Sleep II
    end
    return nil
end

local function make_tooltip_text()
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {
            font = 'Consolas',
            size = 9,
            alpha = 255,
            red = 240,
            green = 240,
            blue = 240,
            stroke = {width = 2, alpha = 200, red = 0, green = 0, blue = 0},
        },
        bg = {
            alpha = 190,
            red = 10,
            green = 10,
            blue = 14,
            visible = true,
        },
        flags = {bold = false, right = false},
        padding = 4,
    })
    g_hide(t)
    return t
end

local function set_bar(bar, x, y, w, h, value, max_value, r, g, b)
    local border_pad = 1
    g_hide(bar.shadow)

    g_pos(bar.border, x - border_pad, y - border_pad)
    g_size(bar.border, w + border_pad * 2, h + border_pad * 2)
    g_show(bar.border)

    g_pos(bar.bg, x, y)
    g_size(bar.bg, w, h)
    g_show(bar.bg)

    local fw = pct_to_width(value, max_value, w)
    g_pos(bar.fg, x, y)
    g_size(bar.fg, fw, h)
    g_color(bar.fg, r, g, b)
    g_show(bar.fg)
end

local function is_call_for_help(target)
    if not target then
        return false
    end
    if target.call_for_help == true or target.is_call_for_help == true or target.callforhelp == true then
        return true
    end
    return false
end

local function entity_spawn_type(entity)
    return tonumber(entity and entity.spawn_type or 0) or 0
end

local function is_mob_entity(entity)
    if not entity then
        return false
    end
    if entity.is_mob == true then
        return true
    end
    return entity_spawn_type(entity) == 16
end

local NON_HOSTILE_NPC_SPAWNS = {
    [2] = true,   -- npc
    [13] = true,  -- object/event
    [14] = true,  -- trust
    [15] = true,  -- event object
    [34] = true,  -- npc/object variant
}

local function is_non_hostile_npc_entity(entity)
    if not entity then
        return false
    end
    if is_mob_entity(entity) then
        return false
    end
    local st = entity_spawn_type(entity)
    if NON_HOSTILE_NPC_SPAWNS[st] then
        return true
    end
    return entity.is_npc == true and entity.is_mob ~= true
end

local function target_name_color(target, party_ids, ally_ids)
    local function rgb(arr)
        return arr[1], arr[2], arr[3]
    end

    local tid = tonumber(target and target.id or 0) or 0
    if tid > 0 then
        if party_ids and party_ids[tid] then
            return rgb(TARGET_NAME_COLORS.PARTY)
        end
        if ally_ids and ally_ids[tid] then
            return rgb(TARGET_NAME_COLORS.ALLIANCE)
        end
    end

    if target and not target.is_npc then
        return rgb(TARGET_NAME_COLORS.WHITE)
    end

    -- Non-hostile NPC / objects (includes trusts).
    if is_non_hostile_npc_entity(target) then
        return rgb(TARGET_NAME_COLORS.GREEN)
    end

    -- Mob claim colors.
    local cfh = is_call_for_help(target)
    if cfh then
        return rgb(TARGET_NAME_COLORS.CFH)
    end

    local claim_id = tonumber(target and target.claim_id or 0) or 0
    if claim_id == 0 then
        return rgb(TARGET_NAME_COLORS.YELLOW)
    end
    if party_ids and party_ids[claim_id] then
        return rgb(TARGET_NAME_COLORS.RED)
    end
    if ally_ids and ally_ids[claim_id] then
        return rgb(TARGET_NAME_COLORS.PURPLE)
    end
    return rgb(TARGET_NAME_COLORS.PINK)
end

local function draw_trails(bar, x, y, h, dt, state)
    local fade_secs = 0.22

    if state.damage_flash_timer and state.damage_flash_timer > 0 and state.damage_flash_from and state.damage_flash_to and state.damage_flash_to > state.damage_flash_from then
        state.damage_flash_timer = math.max(0, state.damage_flash_timer - dt)
        local alpha = 200
        if state.damage_flash_timer < fade_secs then
            alpha = math.floor(200 * (state.damage_flash_timer / fade_secs))
        end
        if alpha > 0 then
            local dw = state.damage_flash_to - state.damage_flash_from
            g_pos(bar.dmg, x + state.damage_flash_from, y)
            g_size(bar.dmg, dw, h)
            g_alpha(bar.dmg, alpha)
            g_show(bar.dmg)
        else
            g_hide(bar.dmg)
        end
    else
        state.damage_flash_timer = 0
        g_hide(bar.dmg)
    end

    if state.heal_flash_timer and state.heal_flash_timer > 0 and state.heal_flash_from and state.heal_flash_to and state.heal_flash_to > state.heal_flash_from then
        state.heal_flash_timer = math.max(0, state.heal_flash_timer - dt)
        local alpha = 210
        if state.heal_flash_timer < fade_secs then
            alpha = math.floor(210 * (state.heal_flash_timer / fade_secs))
        end
        if alpha > 0 then
            local hw = state.heal_flash_to - state.heal_flash_from
            g_pos(bar.heal, x + state.heal_flash_from, y)
            g_size(bar.heal, hw, h)
            g_alpha(bar.heal, alpha)
            g_show(bar.heal)
        else
            g_hide(bar.heal)
        end
    else
        state.heal_flash_timer = 0
        g_hide(bar.heal)
    end
end

local function hide_bar(bar)
    g_hide(bar.shadow)
    g_hide(bar.border)
    g_hide(bar.bg)
    g_hide(bar.fg)
    g_hide(bar.dmg)
    g_hide(bar.heal)
end

local function icon_path(state, buff_id)
    if buff_id > 999 then
        return nil
    end
    if state.icon_path_cache[buff_id] ~= nil then
        return state.icon_path_cache[buff_id]
    end

    local path = state.icon_root .. zero_pad3(buff_id) .. '.png'
    local f = io.open(path, 'rb')
    if f then
        f:close()
        state.icon_path_cache[buff_id] = path
        return path
    end

    state.icon_path_cache[buff_id] = false
    return nil
end

local function ensure_pool(pool, count)
    for i = #pool + 1, count do
        local icon = images.new()
        icon:draggable(false)
        icon:fit(false)
        g_hide(icon)
        pool[i] = icon
    end
end

local function ensure_text_pool(pool, count)
    for i = #pool + 1, count do
        pool[i] = make_timer_text()
    end
end

local function sort_target_debuff_entries(entries)
    table.sort(entries, function(a, b)
        local pa = debuff_priority[a.id] or 99
        local pb = debuff_priority[b.id] or 99
        if pa ~= pb then
            return pa < pb
        end
        local na = a.name or debuffs.buff_name(a.id)
        local nb = b.name or debuffs.buff_name(b.id)
        if na ~= nb then
            return na < nb
        end
        return a.id < b.id
    end)
end

local function format_remaining(remaining)
    local r = math.max(0, math.floor(remaining + 0.5))
    return tostring(r)
end

local function show_icon_grid(state, icon_pool, timer_pool, mark_pool, entries, x, y, size, spacing, limit, per_row, show_timers)
    limit = limit or #entries
    show_timers = (show_timers ~= false)
    per_row = math.max(1, per_row or limit)
    local timer_h = show_timers and 7 or 0
    local row_h = size + timer_h + spacing

    local shown = 0
    ensure_pool(icon_pool, math.min(limit, #entries))
    ensure_text_pool(timer_pool, math.min(limit, #entries))
    ensure_text_pool(mark_pool, math.min(limit, #entries))
    for i = 1, math.min(limit, #entries) do
        local entry = entries[i]
        local id = entry.id
        local path = icon_path(state, id)
        if path then
            shown = shown + 1
            local icon = icon_pool[shown]
            local timer = timer_pool[shown]
            local col = (shown - 1) % per_row
            local row = math.floor((shown - 1) / per_row)
            local px = x + col * (size + spacing)
            local py = y + row * row_h
            g_path(icon, path)
            g_pos(icon, px, py)
            g_size(icon, size, size)
            g_show(icon)
            state.visible_icon_entries[shown] = {icon = icon, entry = entry}

            if show_timers then
                local ttxt = format_remaining(entry.remaining or 0)
                g_text(timer, ttxt)
                g_color(timer, timer_color(entry.remaining, entry.mine))
                local tw = g_extents(timer) or (#ttxt * 5)
                g_pos(timer, px + math.floor((size - tw) * 0.5), py + size)
                g_show(timer)
            else
                g_hide(timer)
            end

            local mark = mark_pool[shown]
            local lbl = debuff_tier_label(id, entry.mark)
            if mark and lbl then
                g_text(mark, lbl)
                g_color(mark, 250, 220, 90)
                g_pos(mark, px + size - 6, py + size - 8)
                g_show(mark)
            elseif mark then
                g_hide(mark)
            end
        end
    end

    for i = shown + 1, #icon_pool do
        g_hide(icon_pool[i])
    end
    for i = shown + 1, #timer_pool do
        g_hide(timer_pool[i])
    end
    for i = shown + 1, #mark_pool do
        g_hide(mark_pool[i])
    end
    for i = shown + 1, #state.visible_icon_entries do
        state.visible_icon_entries[i] = nil
    end
end

local function hide_pool(pool)
    for i = 1, #pool do
        g_hide(pool[i])
    end
end

local function hide_text_pool(pool)
    for i = 1, #pool do
        g_hide(pool[i])
    end
end

local function ensure_enemy_row(state, idx)
    if not state.enemy_rows[idx] then
        state.enemy_rows[idx] = {
            hp = make_bar('uibar_enemy_hp_' .. tostring(idx)),
            name = make_small_text({235, 235, 235}),
            info = make_small_text({215, 215, 215}),
            tot = make_small_text({190, 220, 255}),
            cast = make_small_text({255, 150, 60}),
            icons = {},
            itimes = {},
            imarks = {},
        }
    end
    return state.enemy_rows[idx]
end

local function hide_enemy_rows(state)
    for i = 1, #state.enemy_rows do
        local row = state.enemy_rows[i]
        hide_bar(row.hp)
        g_hide(row.name)
        g_hide(row.info)
        g_hide(row.tot)
        g_hide(row.cast)
        hide_pool(row.icons)
        hide_text_pool(row.itimes)
        hide_text_pool(row.imarks)
    end
    g_hide(state.enemy_title)
    if state.enemy_drag then
        g_hide(state.enemy_drag)
    end
end

function M.create(settings)
    local addon_path = windower.addon_path or ''
    local targetjobicon = images.new('uibar_targetjobicon')
    local enemydrag = images.new('uibar_enemy_drag')
    targetjobicon:draggable(false)
    targetjobicon:fit(false)
    g_hide(targetjobicon)
    enemydrag:draggable(false)
    enemydrag:fit(true)
    g_alpha(enemydrag, 0)
    g_hide(enemydrag)
    return {
        icon_root = addon_path .. 'images/icons/',
        icon_path_cache = {},
        target_hp = make_bar('uibar_target_hp'),
        target_name = make_text({90, 220, 255}),
        target_tot = make_text({230, 230, 230}),
        target_dist = make_text({235, 235, 235}),
        target_pct = make_text({245, 245, 245}),
        tooltip = make_tooltip_text(),
        target_cast = make_bar('uibar_target_cast'),
        target_cast_text = make_small_text({255, 150, 60}),
        target_job_icon = targetjobicon,
        job_icon_cache = {},
        target_debuffs = {},
        target_debuff_times = {},
        target_debuff_marks = {},
        target_detect_icons = {},
        detect_icon_cache = {},
        visible_icon_entries = {},
        visible_detect_entries = {},
        visible_job_entry = nil,
        enemy_drag = enemydrag,
        enemy_title = make_small_text({235, 235, 235}),
        enemy_rows = {},
        anim = {
            last_clock = os.clock(),
            prev_target_w = nil,
            damage_flash_from = nil,
            damage_flash_to = nil,
            damage_flash_timer = 0,
            heal_flash_from = nil,
            heal_flash_to = nil,
            heal_flash_timer = 0,
        },
    }
end

function M.hide(state)
    if state._is_hidden then
        return
    end
    hide_bar(state.target_hp)
    g_hide(state.target_name)
    g_hide(state.target_tot)
    g_hide(state.target_dist)
    g_hide(state.target_pct)
    g_hide(state.tooltip)
    hide_bar(state.target_cast)
    g_hide(state.target_cast_text)
    g_hide(state.target_job_icon)
    hide_pool(state.target_debuffs)
    hide_text_pool(state.target_debuff_times)
    hide_text_pool(state.target_debuff_marks)
    hide_pool(state.target_detect_icons)
    hide_enemy_rows(state)
    state._is_hidden = true
end

function M.destroy(state)
    local list = {
        state.target_hp.shadow, state.target_hp.border, state.target_hp.bg,
        state.target_hp.fg,
        state.target_hp.dmg, state.target_hp.heal,
    }
    for i = 1, #list do
        pcall(function() list[i]:destroy() end)
    end
    pcall(function() state.target_name:destroy() end)
    pcall(function() state.target_tot:destroy() end)
    pcall(function() state.target_dist:destroy() end)
    pcall(function() state.target_pct:destroy() end)
    pcall(function() state.tooltip:destroy() end)
    pcall(function() state.target_cast_text:destroy() end)
    for _, k in ipairs({'shadow', 'border', 'bg', 'fg', 'dmg', 'heal'}) do
        pcall(function() state.target_cast[k]:destroy() end)
    end
    pcall(function() state.target_job_icon:destroy() end)
    for _, pool in ipairs({state.target_debuffs}) do
        for i = 1, #pool do
            pcall(function() pool[i]:destroy() end)
        end
    end
    for i = 1, #state.target_detect_icons do
        pcall(function() state.target_detect_icons[i]:destroy() end)
    end
    for i = 1, #state.target_debuff_times do
        pcall(function() state.target_debuff_times[i]:destroy() end)
    end
    for i = 1, #state.target_debuff_marks do
        pcall(function() state.target_debuff_marks[i]:destroy() end)
    end
    pcall(function() state.enemy_title:destroy() end)
    pcall(function() state.enemy_drag:destroy() end)
    for i = 1, #state.enemy_rows do
        local row = state.enemy_rows[i]
        if row then
            local bl = {row.hp.shadow, row.hp.border, row.hp.bg, row.hp.fg, row.hp.dmg, row.hp.heal}
            for j = 1, #bl do
                pcall(function() bl[j]:destroy() end)
            end
            pcall(function() row.name:destroy() end)
            pcall(function() row.info:destroy() end)
            pcall(function() row.tot:destroy() end)
            pcall(function() row.cast:destroy() end)
            for k = 1, #row.icons do
                pcall(function() row.icons[k]:destroy() end)
            end
            for k = 1, #row.itimes do
                pcall(function() row.itimes[k]:destroy() end)
            end
            for k = 1, #row.imarks do
                pcall(function() row.imarks[k]:destroy() end)
            end
        end
    end
end

local function detect_icon_path(state, file_no_ext)
    if state.detect_icon_cache[file_no_ext] ~= nil then
        return state.detect_icon_cache[file_no_ext]
    end
    local path = (windower.addon_path or '') .. 'data/mobdb/icons/' .. file_no_ext .. '.png'
    local f = io.open(path, 'rb')
    if f then
        f:close()
        state.detect_icon_cache[file_no_ext] = path
        return path
    end
    state.detect_icon_cache[file_no_ext] = false
    return nil
end

local function job_icon_path(state, job_abbr)
    if not job_abbr or job_abbr == '' then
        return nil
    end
    if state.job_icon_cache[job_abbr] ~= nil then
        return state.job_icon_cache[job_abbr]
    end

    local base = windower.addon_path or ''
    local candidates = {
        base .. 'images/jobs/' .. job_abbr .. '.png',
        base .. 'images/jobs/' .. string.lower(job_abbr) .. '.png',
        base .. 'data/mobdb/icons/jobs/' .. job_abbr .. '.png',
        base .. 'data/mobdb/icons/' .. job_abbr .. '.png',
    }
    for i = 1, #candidates do
        local p = candidates[i]
        local f = io.open(p, 'rb')
        if f then
            f:close()
            state.job_icon_cache[job_abbr] = p
            return p
        end
    end
    state.job_icon_cache[job_abbr] = false
    return nil
end

local function buff_description(buff_id)
    local b = res and res.buffs and res.buffs[buff_id]
    if not b then
        return 'No description.'
    end
    return b.enl or b.description or b.help or 'No description.'
end

local function append_unique_entries(dst, seen, src)
    if type(src) ~= 'table' then
        return
    end
    for i = 1, #src do
        local e = src[i]
        local bid = tonumber(e and e.id or 0) or 0
        if bid > 0 and not seen[bid] then
            seen[bid] = true
            dst[#dst + 1] = {
                id = bid,
                name = e.name or debuffs.buff_name(bid),
            }
        end
    end
end

local function add_ids_from_table(dst, src)
    if type(src) ~= 'table' then
        return
    end
    for k, v in pairs(src) do
        -- Array style: {33, 40, ...}
        local bid_v = tonumber(v) or 0
        if bid_v > 0 and bid_v <= 999 then
            dst[bid_v] = true
        end
        -- Set/dict style: {[33]=true, [40]=true, ...}
        local bid_k = tonumber(k) or 0
        if bid_k > 0 and bid_k <= 999 and (v == true or v == 1 or v == '1' or type(v) == 'number') then
            dst[bid_k] = true
        end
    end
end

local function player_buff_entries_for_target(target, logic_state, max_items)
    local ids = {}
    local client_set = status and status.collecttargetbuffids and status.collecttargetbuffids(target) or {}
    add_ids_from_table(ids, client_set)

    local out = {}
    local seen = {}
    for bid, _ in pairs(ids) do
        out[#out + 1] = {
            id = bid,
            name = debuffs.buff_name(bid),
            is_debuff = debuffs.is_negative_player_status and debuffs.is_negative_player_status(bid) or false,
        }
        seen[bid] = true
    end

    -- Event cache only as fallback when the client set is empty.
    if next(ids) == nil then
        local tid = tonumber(target and target.id or 0) or 0
        local known = debuffs.get_known_target_buffs and debuffs.get_known_target_buffs(logic_state, tid, max_items or 64) or {}
        append_unique_entries(out, seen, known)
    end

    table.sort(out, function(a, b)
        if a.is_debuff ~= b.is_debuff then
            return a.is_debuff
        end
        if a.is_debuff then
            local pa = debuff_priority[a.id] or 99
            local pb = debuff_priority[b.id] or 99
            if pa ~= pb then
                return pa < pb
            end
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.id < b.id
    end)

    if max_items and #out > max_items then
        local trimmed = {}
        for i = 1, max_items do
            trimmed[i] = out[i]
        end
        return trimmed
    end
    return out
end

local function update_tooltip(state, mouse_x, mouse_y)
    local jobhit = state.visible_job_entry
    if jobhit and jobhit.icon and jobhit.icon:hover(mouse_x, mouse_y) then
        local tip = jobhit.tooltip or ''
        local text = (tip ~= '') and string.format('%s\n%s', jobhit.title or '', tip) or (jobhit.title or '')
        g_text(state.tooltip, text)
        g_pos(state.tooltip, (mouse_x or 0) + 14, (mouse_y or 0) + 14)
        g_show(state.tooltip)
        return
    end

    local hit_detect = nil
    for i = 1, #state.visible_detect_entries do
        local it = state.visible_detect_entries[i]
        if it and it.icon and it.icon:hover(mouse_x, mouse_y) then
            hit_detect = it
            break
        end
    end

    if hit_detect then
        local text = string.format('%s\n%s', hit_detect.title or 'Detection', hit_detect.tooltip or '')
        g_text(state.tooltip, text)
        g_pos(state.tooltip, (mouse_x or 0) + 14, (mouse_y or 0) + 14)
        g_show(state.tooltip)
        return
    end

    local hit = nil
    for i = 1, #state.visible_icon_entries do
        local it = state.visible_icon_entries[i]
        if it and it.icon and it.icon:hover(mouse_x, mouse_y) then
            hit = it.entry
            break
        end
    end

    if not hit then
        g_hide(state.tooltip)
        return
    end

    local name = hit.name or debuffs.buff_name(hit.id)
    local desc = buff_description(hit.id)
    local text = string.format('%s (#%d)\n%s', name, hit.id, desc)
    if hit.remaining ~= nil then
        local rem = math.max(0, math.floor((hit.remaining or 0) + 0.5))
        text = string.format('%s\nRem: %ds', text, rem)
    end
    g_text(state.tooltip, text)
    g_pos(state.tooltip, (mouse_x or 0) + 14, (mouse_y or 0) + 14)
    g_show(state.tooltip)
end

local function get_cached_sorted_debuff_entries(logic_state, mob_id, now)
    logic_state.debuff_entries_cache = logic_state.debuff_entries_cache or {}
    local cache = logic_state.debuff_entries_cache
    local mid = tonumber(mob_id or 0) or 0
    if mid <= 0 then
        return {}
    end

    local c = cache[mid]
    if c and now <= (tonumber(c.expires or 0) or 0) and type(c.entries) == 'table' then
        return c.entries
    end

    local entries = debuffs.get_active_entries(logic_state, mid) or {}
    sort_target_debuff_entries(entries)
    cache[mid] = {
        expires = now + 0.12,
        entries = entries,
    }

    local sweep_at = tonumber(logic_state.debuff_entries_sweep_at or 0) or 0
    if now >= sweep_at then
        for k, v in pairs(cache) do
            if type(v) ~= 'table' or now > ((tonumber(v.expires or 0) or 0) + 5.0) then
                cache[k] = nil
            end
        end
        logic_state.debuff_entries_sweep_at = now + 5.0
    end

    return entries
end

local function get_cached_player_entries(target, logic_state, now, max_items)
    logic_state.player_buff_cache = logic_state.player_buff_cache or {}
    local cache = logic_state.player_buff_cache
    local tid = tonumber(target and target.id or 0) or 0
    if tid <= 0 then
        return {}
    end

    local c = cache[tid]
    if c and now <= (tonumber(c.expires or 0) or 0) and type(c.entries) == 'table' then
        return c.entries
    end

    local entries = player_buff_entries_for_target(target, logic_state, max_items) or {}
    cache[tid] = {
        expires = now + 0.20,
        entries = entries,
    }

    local sweep_at = tonumber(logic_state.player_buff_sweep_at or 0) or 0
    if now >= sweep_at then
        for k, v in pairs(cache) do
            if type(v) ~= 'table' or now > ((tonumber(v.expires or 0) or 0) + 8.0) then
                cache[k] = nil
            end
        end
        logic_state.player_buff_sweep_at = now + 8.0
    end

    return entries
end

function M.update(state, settings, logic_state, mobdb, mouse_x, mouse_y)
    cur_settings = settings
    if not settings.graphics.enabled then
        M.hide(state)
        return
    end
    state._is_hidden = false

    local bar_cfg = settings.graphics.bar
    local icon_cfg = settings.graphics.icons
    local now = os.clock()
    state.claim_cache = state.claim_cache or {
        next_at = 0,
        party_ids = {},
        ally_ids = {},
        all_ids = {},
    }
    if now >= (tonumber(state.claim_cache.next_at or 0) or 0) then
        local pids, aids, all = party.get_claim_sets()
        state.claim_cache.party_ids = pids or {}
        state.claim_cache.ally_ids = aids or {}
        state.claim_cache.all_ids = all or {}
        state.claim_cache.next_at = now + 0.20
    end
    local party_ids = state.claim_cache.party_ids
    local ally_ids = state.claim_cache.ally_ids
    local all_ids = state.claim_cache.all_ids
    local dt = now - (state.anim.last_clock or now)
    state.anim.last_clock = now
    if dt < 0 then
        dt = 0
    elseif dt > 0.3 then
        dt = 0.3
    end

    local target = windower.ffxi.get_mob_by_target('t')
    if target and target.valid_target then
        local tbar_x = settings.target.x
        local tbar_y = settings.target.y + 18
        local hpp = tonumber(target.hpp)
        if not hpp then
            local me = windower.ffxi.get_player()
            if me and tonumber(me.id) and tonumber(target.id) and tonumber(me.id) == tonumber(target.id) then
                local hp = me.vitals and me.vitals.hp or 0
                local hpmax = me.vitals and me.vitals.max_hp or 1
                hpp = math.floor((hp / math.max(1, hpmax)) * 100 + 0.5)
            else
                hpp = 100
            end
        end
        hpp = math.max(0, math.min(100, hpp))
        local curr_w = pct_to_width(hpp, 100, bar_cfg.width)
        local prev_w = state.anim.prev_target_w
        if prev_w == nil then
            prev_w = curr_w
        end

        if curr_w < prev_w then
            state.anim.damage_flash_from = curr_w
            state.anim.damage_flash_to = prev_w
            state.anim.damage_flash_timer = 1.0
            state.anim.heal_flash_timer = 0
        elseif curr_w > prev_w then
            state.anim.heal_flash_from = prev_w
            state.anim.heal_flash_to = curr_w
            state.anim.heal_flash_timer = 1.0
            state.anim.damage_flash_timer = 0
        end
        state.anim.prev_target_w = curr_w

        local distance = math.sqrt(math.max(0, target.distance or 0))
        local hr, hg, hb = health_color(hpp)
        set_bar(state.target_hp, tbar_x, tbar_y, bar_cfg.width, bar_cfg.height + 2, hpp, 100, hr, hg, hb)
        draw_trails(state.target_hp, tbar_x, tbar_y, bar_cfg.height + 2, dt, state.anim)

        local idx_text = '---'
        local sid = tonumber(target.id)
        if sid then
            -- Lower 12 bits of the server id in hex (mobdb style).
            idx_text = string.format('%03X', sid % 0x1000)
        end
        local is_npc = target.is_npc and true or false
        local info = (is_npc and mobdb and mobdb.get_mob_info) and mobdb.get_mob_info(target) or nil
        local nr, ng, nb = target_name_color(target, party_ids, ally_ids)
        local lvl = (is_npc and mobdb and mobdb.level_string) and mobdb.level_string(info) or nil
        local job = (is_npc and mobdb and mobdb.job_string) and mobdb.job_string(info) or nil
        local name
        if is_npc and info then
            name = string.format('%s (%s) Lv%s', target.name or 'Target', idx_text, tostring(lvl or '?'))
        elseif is_npc then
            name = tostring(target.name or 'Target')
        else
            name = tostring(target.name or 'Target')
        end
        local dist_text = string.format('%.1f', distance)
        local pct_text = string.format('%d%%', hpp)
        g_color(state.target_name, nr, ng, nb)
        g_text(state.target_name, name)
        g_pos(state.target_name, tbar_x, tbar_y - 20)
        g_show(state.target_name)
        local name_w = g_extents(state.target_name) or (#name * 6)
        local di_size = math.max(16, math.floor((icon_cfg.size or 18) * 0.90 + 0.5))
        local job_size = di_size + 2
        local dx = tbar_x + name_w + 8
        local dy = tbar_y - 24

        if is_npc then
            local jp = job_icon_path(state, job)
            if jp then
                g_path(state.target_job_icon, jp)
                g_pos(state.target_job_icon, dx, dy)
                g_size(state.target_job_icon, job_size, job_size)
                g_show(state.target_job_icon)
                state.visible_job_entry = {
                    icon = state.target_job_icon,
                    title = job or '',
                    tooltip = '',
                }
                dx = dx + job_size + 3
            else
                g_hide(state.target_job_icon)
                state.visible_job_entry = nil
                if job and job ~= '' then
                    name = name .. ' ' .. tostring(job)
                    g_text(state.target_name, name)
                    name_w = g_extents(state.target_name) or (#name * 6)
                    dx = tbar_x + name_w + 8
                end
            end
        else
            g_hide(state.target_job_icon)
            state.visible_job_entry = nil
        end

        local det_entries = (is_npc and mobdb and mobdb.detection_entries and mobdb.detection_entries(info)) or {}
        ensure_pool(state.target_detect_icons, #det_entries)
        for i = 1, #det_entries do
            local e = det_entries[i]
            local icon = state.target_detect_icons[i]
            local p = detect_icon_path(state, e.file)
            if p then
                g_path(icon, p)
                g_pos(icon, dx, dy)
                g_size(icon, di_size, di_size)
                g_show(icon)
                state.visible_detect_entries[i] = {
                    icon = icon,
                    title = e.title,
                    tooltip = e.tooltip,
                }
                dx = dx + di_size + 2
            else
                g_hide(icon)
                state.visible_detect_entries[i] = nil
            end
        end
        for i = #det_entries + 1, #state.target_detect_icons do
            g_hide(state.target_detect_icons[i])
            state.visible_detect_entries[i] = nil
        end

        g_text(state.target_dist, dist_text)
        local dist_w = g_extents(state.target_dist)
        dist_w = dist_w or (#dist_text * 6)
        g_pos(state.target_dist, tbar_x + bar_cfg.width - dist_w, tbar_y - 22)
        g_show(state.target_dist)

        state.tot_cache = state.tot_cache or {target_id = 0, value = nil, expires = 0}
        local target_id_num = tonumber(target.id or 0) or 0
        local my_id = util.player_id()
        local tot = nil
        if my_id > 0 and target_id_num == my_id then
            -- Self-target always points to self.
            tot = target
            state.tot_cache.target_id = target_id_num
            state.tot_cache.value = tot
            state.tot_cache.expires = now + 0.10
        elseif state.tot_cache.target_id == target_id_num and now <= (tonumber(state.tot_cache.expires or 0) or 0) then
            tot = state.tot_cache.value
        else
            tot = get_target_of_target(target)
            state.tot_cache.target_id = target_id_num
            state.tot_cache.value = tot
            state.tot_cache.expires = now + 0.10
        end
        if tot and tot.name and tot.name ~= '' then
            local tr, tg, tb = target_name_color(tot, party_ids, ally_ids)
            g_color(state.target_tot, tr, tg, tb)
            g_text(state.target_tot, '-> ' .. short_name(tot.name, 20))
            local _, tot_h = g_extents(state.target_tot)
            tot_h = tot_h or 10
            local tot_y = tbar_y + math.floor(((bar_cfg.height + 2) - tot_h) * 0.5) - 1
            g_pos(state.target_tot, tbar_x + bar_cfg.width + 10, tot_y)
            g_show(state.target_tot)
        else
            g_hide(state.target_tot)
        end

        g_text(state.target_pct, pct_text)
        local pct_w = g_extents(state.target_pct)
        local pct_h = select(2, g_extents(state.target_pct))
        pct_w = pct_w or (#pct_text * 6)
        pct_h = pct_h or 10
        g_pos(state.target_pct, tbar_x + math.floor((bar_cfg.width - pct_w) * 0.5), tbar_y + math.floor(((bar_cfg.height + 2) - pct_h) * 0.5) - 1)
        g_show(state.target_pct)

        local entries
        local show_timers = true
        if is_npc then
            entries = get_cached_sorted_debuff_entries(logic_state, target.id, now)
            show_timers = true
        else
            entries = get_cached_player_entries(target, logic_state, now, icon_cfg.max_target_debuffs)
            show_timers = false
        end
        show_icon_grid(
            state,
            state.target_debuffs,
            state.target_debuff_times,
            state.target_debuff_marks,
            entries,
            tbar_x,
            tbar_y + bar_cfg.height + 8,
            icon_cfg.size,
            icon_cfg.spacing,
            icon_cfg.max_target_debuffs,
            icon_cfg.per_row,
            show_timers
        )
        update_tooltip(state, mouse_x, mouse_y)

        local tc = is_npc and casts_enabled() and casts.get(target.id) or nil
        if tc then
            local label = tc.name
            local ct = (not tc.interrupted) and tonumber(tc.target_id or 0) or 0
            if ct > 0 and ct ~= tonumber(target.id) then
                local cm = windower.ffxi.get_mob_by_id(ct)
                if cm and cm.name and cm.name ~= '' then
                    label = label .. ' -> ' .. short_name(cm.name, 16)
                end
            end
            local cr, cg, cb = cast_color(tc)
            -- Right-aligned under the HP bar: debuff icons grow from the left.
            local cw = math.floor(math.min(180, bar_cfg.width * 0.35))
            local right = tbar_x + bar_cfg.width
            local cast_y = tbar_y + bar_cfg.height + 2 + 3
            set_bar(state.target_cast, right - cw, cast_y, cw, 4, math.floor(tc.progress * 100 + 0.5), 100, cr, cg, cb)
            g_text(state.target_cast_text, label)
            g_color(state.target_cast_text, cr, cg, cb)
            local tw = g_extents(state.target_cast_text) or (#label * 6)
            g_pos(state.target_cast_text, right - tw, cast_y + 6)
            g_show(state.target_cast_text)
            g_alpha(state.target_cast.fg, math.floor(255 * (tc.alpha or 1)))
        else
            hide_bar(state.target_cast)
            g_hide(state.target_cast_text)
        end
    else
        hide_bar(state.target_cast)
        g_hide(state.target_cast_text)
        hide_bar(state.target_hp)
        g_hide(state.target_name)
        g_hide(state.target_tot)
        g_hide(state.target_dist)
        g_hide(state.target_pct)
        g_hide(state.tooltip)
        g_hide(state.target_job_icon)
        state.visible_job_entry = nil
        hide_pool(state.target_debuffs)
        hide_text_pool(state.target_debuff_times)
        hide_pool(state.target_detect_icons)
        for i = 1, #state.visible_detect_entries do
            state.visible_detect_entries[i] = nil
        end
        state.anim.prev_target_w = nil
        state.anim.damage_flash_timer = 0
        state.anim.heal_flash_timer = 0
        state.tot_cache = nil
    end

    -- The mob scan is expensive: refresh it every 0.3s.
    local enemy_refresh = 0.30
    logic_state.enemy_rows_cache = logic_state.enemy_rows_cache or {}
    if now >= (logic_state.enemy_rows_next_at or 0) then
        logic_state.enemy_rows_cache = hate.collect(settings, logic_state)
        logic_state.enemy_rows_next_at = now + enemy_refresh
    end
    local erows = logic_state.enemy_rows_cache
    local ex = settings.enemy.x
    local ey = settings.enemy.y
    local ew = math.max(115, math.floor((bar_cfg.width or 500) * 0.30))
    local eh = math.max(5, math.floor((bar_cfg.height or 10) * 0.60))
    local icon_size = math.max(12, math.floor((icon_cfg.size or 22) * 0.62))
    local row_gap = eh + icon_size + 31
    local icon_gap = 1
    local selected_enemy_id = tonumber(target and target.id or 0) or 0

    g_hide(state.enemy_title)
    if state.enemy_drag then
        local drag_h = math.max(22, 8 + (#erows * row_gap))
        g_pos(state.enemy_drag, ex, ey - 10)
        g_size(state.enemy_drag, ew + 240, drag_h)
        g_show(state.enemy_drag)
    end

    for i = 1, #erows do
        local e = erows[i]
        local row = ensure_enemy_row(state, i)
        local y = ey + (i - 1) * row_gap
        local mob_id = tonumber(e.mob and e.mob.id or 0) or 0
        local is_selected = (selected_enemy_id > 0 and mob_id == selected_enemy_id)

        local mr, mg, mb = health_color(e.hpp)
        set_bar(row.hp, ex, y + 9, ew, eh, e.hpp, 100, mr, mg, mb)
        if is_selected then
            g_color(row.hp.border, 255, 222, 120)
            g_alpha(row.hp.border, 255)
            g_color(row.hp.bg, 52, 56, 70)
            g_alpha(row.hp.bg, 250)
        else
            g_color(row.hp.border, 8, 12, 18)
            g_alpha(row.hp.border, 230)
            g_color(row.hp.bg, 35, 38, 45)
            g_alpha(row.hp.bg, 240)
        end

        local nr, ng, nb = target_name_color(e.mob, e.party_ids, e.ally_ids)
        local row_name = short_name(e.mob.name or 'Mob', 30)
        if is_selected then
            row_name = '> ' .. row_name
            g_color(row.name, math.min(255, nr + 35), math.min(255, ng + 35), math.min(255, nb + 35))
        else
            g_color(row.name, nr, ng, nb)
        end
        g_text(row.name, row_name)
        g_pos(row.name, ex, y - 8)
        g_show(row.name)

        g_text(row.info, string.format('%d%%  %.1f', e.hpp, e.distance))
        if is_selected then
            g_color(row.info, 255, 232, 150)
        else
            g_color(row.info, 215, 215, 215)
        end
        local iw = g_extents(row.info) or 64
        g_pos(row.info, ex + ew - iw, y - 8)
        g_show(row.info)

        if e.target and e.target.name and e.target.name ~= '' then
            local tr, tg, tb = target_name_color(e.target, e.party_ids, e.ally_ids)
            g_text(row.tot, '-> ' .. short_name(e.target.name, 14))
            g_color(row.tot, tr, tg, tb)
            local _, row_tot_h = g_extents(row.tot)
            row_tot_h = row_tot_h or 8
            local row_tot_y = (y + 9) + math.floor((eh - row_tot_h) * 0.5) - 1
            g_pos(row.tot, ex + ew + 8, row_tot_y)
            g_show(row.tot)
        else
            g_hide(row.tot)
        end

        local rc = casts_enabled() and casts.get(mob_id) or nil
        if rc then
            g_text(row.cast, short_name(rc.name, 18))
            g_color(row.cast, cast_color(rc))
            g_pos(row.cast, ex + ew + 8, y - 8)
            g_show(row.cast)
        else
            g_hide(row.cast)
        end

        local dents = get_cached_sorted_debuff_entries(logic_state, e.mob.id, now)
        local max_icons = math.min(#dents, settings.enemy.max_debuffs_per_enemy or 4)
        ensure_pool(row.icons, max_icons)
        ensure_text_pool(row.itimes, max_icons)
        ensure_text_pool(row.imarks, max_icons)
        local shown = 0
        for j = 1, max_icons do
            local de = dents[j]
            local did = de.id
            local p = icon_path(state, did)
            if p then
                shown = shown + 1
                local ic = row.icons[shown]
                g_path(ic, p)
                g_size(ic, icon_size, icon_size)
                local ix = ex + (shown - 1) * (icon_size + icon_gap)
                local iy = y + eh + 12
                g_pos(ic, ix, iy)
                g_show(ic)

                local rt = tonumber(de.remaining or 0) or 0
                local tt = row.itimes[shown]
                if rt > 0 then
                    local txt = (rt >= 99) and '1+' or tostring(math.floor(rt + 0.5))
                    g_text(tt, txt)
                    g_color(tt, timer_color(rt, de.mine))
                    local tw = g_extents(tt) or (#txt * 5)
                    g_pos(tt, ix + math.floor((icon_size - tw) * 0.5), iy + icon_size)
                    g_show(tt)
                else
                    g_hide(tt)
                end

                local mk = row.imarks[shown]
                local ml = debuff_tier_label(did, de.mark)
                if mk and ml then
                    g_text(mk, ml)
                    g_color(mk, 250, 220, 90)
                    g_pos(mk, ix + icon_size - 6, iy + icon_size - 8)
                    g_show(mk)
                elseif mk then
                    g_hide(mk)
                end
            end
        end
        for j = shown + 1, #row.icons do
            g_hide(row.icons[j])
        end
        for j = shown + 1, #row.itimes do
            g_hide(row.itimes[j])
        end
        for j = shown + 1, #row.imarks do
            g_hide(row.imarks[j])
        end
    end

    for i = #erows + 1, #state.enemy_rows do
        local row = state.enemy_rows[i]
        hide_bar(row.hp)
        g_hide(row.name)
        g_hide(row.info)
        g_hide(row.tot)
        g_hide(row.cast)
        hide_pool(row.icons)
        hide_text_pool(row.itimes)
        hide_text_pool(row.imarks)
    end
end

return M
