local images = require('images')
local texts = require('texts')
local res = require('resources')
local debuffs = require('uibardebuffs')
local party = require('uibarparty')
local status = require('uibarstatus')
local actiontracker = require('uibaractiontracker')

local M = {}

local debuff_priority = {
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
        prim:hide()
    end

    shadow:color(0, 0, 0)
    shadow:alpha(110)
    border:color(8, 12, 18)
    border:alpha(230)
    bg:color(35, 38, 45)
    bg:alpha(240)
    dmg:color(255, 40, 40)
    dmg:alpha(190)
    heal:color(40, 255, 80)
    heal:alpha(190)

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
    t:hide()
    return t
end

local function make_small_text(color)
    local t = texts.new('', {
        pos = {x = 0, y = 0},
        text = {
            font = 'Consolas',
            size = 9,
            alpha = 255,
            red = color[1],
            green = color[2],
            blue = color[3],
            stroke = {width = 2, alpha = 190, red = 0, green = 0, blue = 0},
        },
        bg = {visible = false},
        flags = {bold = true, right = false},
    })
    t:hide()
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

        -- XIUI-like behavior: action-based tracking is usually most reliable for mobs.
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
    t:hide()
    return t
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
    t:hide()
    return t
end

local function set_bar(bar, x, y, w, h, value, max_value, r, g, b)
    local border_pad = 1
    bar.shadow:hide()

    bar.border:pos(x - border_pad, y - border_pad)
    bar.border:size(w + border_pad * 2, h + border_pad * 2)
    bar.border:show()

    bar.bg:pos(x, y)
    bar.bg:size(w, h)
    bar.bg:show()

    local fw = pct_to_width(value, max_value, w)
    bar.fg:pos(x, y)
    bar.fg:size(fw, h)
    bar.fg:color(r, g, b)
    bar.fg:show()
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

local function target_name_color(target, party_ids, ally_ids, mob_info)
    local C = {
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

    local function rgb(arr)
        return arr[1], arr[2], arr[3]
    end

    if target and not target.is_npc then
        local tid = tonumber(target.id or 0) or 0
        if party_ids and party_ids[tid] then
            return rgb(C.PARTY)
        end
        if ally_ids and ally_ids[tid] then
            return rgb(C.ALLIANCE)
        end
        return rgb(C.WHITE)
    end

    -- Non-hostile NPC / objects (not tracked in mobdb tables).
    if (target and target.is_npc) and (mob_info == nil) then
        return rgb(C.GREEN)
    end

    -- Mob claim colors.
    local cfh = is_call_for_help(target)
    if cfh then
        return rgb(C.CFH)
    end

    local claim_id = tonumber(target and target.claim_id or 0) or 0
    if claim_id == 0 then
        return rgb(C.YELLOW)
    end
    if party_ids and party_ids[claim_id] then
        return rgb(C.RED)
    end
    if ally_ids and ally_ids[claim_id] then
        return rgb(C.PURPLE)
    end
    return rgb(C.PINK)
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
            bar.dmg:pos(x + state.damage_flash_from, y)
            bar.dmg:size(dw, h)
            bar.dmg:alpha(alpha)
            bar.dmg:show()
        else
            bar.dmg:hide()
        end
    else
        state.damage_flash_timer = 0
        bar.dmg:hide()
    end

    if state.heal_flash_timer and state.heal_flash_timer > 0 and state.heal_flash_from and state.heal_flash_to and state.heal_flash_to > state.heal_flash_from then
        state.heal_flash_timer = math.max(0, state.heal_flash_timer - dt)
        local alpha = 210
        if state.heal_flash_timer < fade_secs then
            alpha = math.floor(210 * (state.heal_flash_timer / fade_secs))
        end
        if alpha > 0 then
            local hw = state.heal_flash_to - state.heal_flash_from
            bar.heal:pos(x + state.heal_flash_from, y)
            bar.heal:size(hw, h)
            bar.heal:alpha(alpha)
            bar.heal:show()
        else
            bar.heal:hide()
        end
    else
        state.heal_flash_timer = 0
        bar.heal:hide()
    end
end

local function hide_bar(bar)
    bar.shadow:hide()
    bar.border:hide()
    bar.bg:hide()
    bar.fg:hide()
    bar.dmg:hide()
    bar.heal:hide()
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
        icon:hide()
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

local function show_icon_grid(state, icon_pool, timer_pool, entries, x, y, size, spacing, limit, per_row, show_timers)
    limit = limit or #entries
    show_timers = (show_timers ~= false)
    per_row = math.max(1, per_row or limit)
    local timer_h = show_timers and 7 or 0
    local row_h = size + timer_h + spacing

    local shown = 0
    ensure_pool(icon_pool, math.min(limit, #entries))
    ensure_text_pool(timer_pool, math.min(limit, #entries))
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
            icon:path(path)
            icon:pos(px, py)
            icon:size(size, size)
            icon:show()
            state.visible_icon_entries[shown] = {icon = icon, entry = entry}

            if show_timers then
                local ttxt = format_remaining(entry.remaining or 0)
                timer:text(ttxt)
                local tw = timer:extents() or (#ttxt * 5)
                timer:pos(px + math.floor((size - tw) * 0.5), py + size)
                timer:show()
            else
                timer:hide()
            end
        end
    end

    for i = shown + 1, #icon_pool do
        icon_pool[i]:hide()
    end
    for i = shown + 1, #timer_pool do
        timer_pool[i]:hide()
    end
    for i = shown + 1, #state.visible_icon_entries do
        state.visible_icon_entries[i] = nil
    end
end

local function hide_pool(pool)
    for i = 1, #pool do
        pool[i]:hide()
    end
end

local function hide_text_pool(pool)
    for i = 1, #pool do
        pool[i]:hide()
    end
end

local function ensure_enemy_row(state, idx)
    if not state.enemy_rows[idx] then
        state.enemy_rows[idx] = {
            hp = make_bar('uibar_enemy_hp_' .. tostring(idx)),
            name = make_small_text({235, 235, 235}),
            info = make_small_text({215, 215, 215}),
            tot = make_small_text({190, 220, 255}),
            icons = {},
        }
    end
    return state.enemy_rows[idx]
end

local function hide_enemy_rows(state)
    for i = 1, #state.enemy_rows do
        local row = state.enemy_rows[i]
        hide_bar(row.hp)
        row.name:hide()
        row.info:hide()
        row.tot:hide()
        hide_pool(row.icons)
    end
    state.enemy_title:hide()
end

function M.create(settings)
    local addon_path = windower.addon_path or ''
    local targetjobicon = images.new('uibar_targetjobicon')
    targetjobicon:draggable(false)
    targetjobicon:fit(false)
    targetjobicon:hide()
    return {
        icon_root = addon_path .. 'images/icons/',
        icon_path_cache = {},
        target_hp = make_bar('uibar_target_hp'),
        target_name = make_text({90, 220, 255}),
        target_tot = make_text({230, 230, 230}),
        target_dist = make_text({235, 235, 235}),
        target_pct = make_text({245, 245, 245}),
        tooltip = make_tooltip_text(),
        target_job_icon = targetjobicon,
        job_icon_cache = {},
        target_debuffs = {},
        target_debuff_times = {},
        target_detect_icons = {},
        detect_icon_cache = {},
        visible_icon_entries = {},
        visible_detect_entries = {},
        visible_job_entry = nil,
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
    hide_bar(state.target_hp)
    state.target_name:hide()
    state.target_tot:hide()
    state.target_dist:hide()
    state.target_pct:hide()
    state.tooltip:hide()
    state.target_job_icon:hide()
    hide_pool(state.target_debuffs)
    hide_text_pool(state.target_debuff_times)
    hide_pool(state.target_detect_icons)
    hide_enemy_rows(state)
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
    pcall(function() state.enemy_title:destroy() end)
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
            for k = 1, #row.icons do
                pcall(function() row.icons[k]:destroy() end)
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
        state.tooltip:text(text)
        state.tooltip:pos((mouse_x or 0) + 14, (mouse_y or 0) + 14)
        state.tooltip:show()
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
        state.tooltip:text(text)
        state.tooltip:pos((mouse_x or 0) + 14, (mouse_y or 0) + 14)
        state.tooltip:show()
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
        state.tooltip:hide()
        return
    end

    local name = hit.name or debuffs.buff_name(hit.id)
    local desc = buff_description(hit.id)
    local text = string.format('%s (#%d)\n%s', name, hit.id, desc)
    if hit.remaining ~= nil then
        local rem = math.max(0, math.floor((hit.remaining or 0) + 0.5))
        text = string.format('%s\nRem: %ds', text, rem)
    end
    state.tooltip:text(text)
    state.tooltip:pos((mouse_x or 0) + 14, (mouse_y or 0) + 14)
    state.tooltip:show()
end

local function collect_enemy_aggro_rows(settings, mobdb)
    local mobs = windower.ffxi.get_mob_array()
    if not mobs then
        return {}
    end
    local party_ids, ally_ids, all_ids = party.get_claim_sets()
    local rows = {}
    local scan_sq = (settings.enemy_scan_range or 0) * (settings.enemy_scan_range or 0)

    for _, mob in pairs(mobs) do
        if mob and mob.is_npc and mob.valid_target and tonumber(mob.hpp or 0) > 0 and mob.distance then
            local within = (settings.enemy_scan_range or 0) <= 0 or mob.distance <= scan_sq
            if within then
                local tgt = get_target_of_target(mob)
                local tid = tonumber(tgt and tgt.id or 0) or 0
                if tid > 0 and all_ids and all_ids[tid] then
                    local info = mobdb and mobdb.get_mob_info and mobdb.get_mob_info(mob) or nil
                    rows[#rows + 1] = {
                        mob = mob,
                        info = info,
                        target = tgt,
                        distance = math.sqrt(math.max(0, mob.distance or 0)),
                        hpp = tonumber(mob.hpp or 0) or 0,
                        party_ids = party_ids,
                        ally_ids = ally_ids,
                    }
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        if a.hpp ~= b.hpp then
            return a.hpp < b.hpp
        end
        return tostring(a.mob.name or '') < tostring(b.mob.name or '')
    end)

    local maxn = math.max(1, tonumber(settings.max_enemies or 8) or 8)
    if #rows > maxn then
        local out = {}
        for i = 1, maxn do
            out[i] = rows[i]
        end
        return out
    end
    return rows
end

function M.update(state, settings, logic_state, mobdb, mouse_x, mouse_y)
    if not settings.graphics.enabled then
        M.hide(state)
        return
    end

    local bar_cfg = settings.graphics.bar
    local icon_cfg = settings.graphics.icons
    local now = os.clock()
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
            -- Match common mobdb/xiui style: lower 12 bits of server id in hex, no 0x prefix.
            idx_text = string.format('%03X', sid % 0x1000)
        end
        local is_npc = target.is_npc and true or false
        local info = (is_npc and mobdb and mobdb.get_mob_info) and mobdb.get_mob_info(target) or nil
        local party_ids, ally_ids = party.get_claim_sets()
        local nr, ng, nb = target_name_color(target, party_ids, ally_ids, info)
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
        pcall(function()
            state.target_name:color(nr, ng, nb)
        end)
        state.target_name:text(name)
        state.target_name:pos(tbar_x, tbar_y - 20)
        state.target_name:show()
        local name_w = state.target_name:extents() or (#name * 6)
        local di_size = math.max(16, math.floor((icon_cfg.size or 18) * 0.90 + 0.5))
        local job_size = di_size + 2
        local dx = tbar_x + name_w + 8
        local dy = tbar_y - 24

        if is_npc then
            local jp = job_icon_path(state, job)
            if jp then
                state.target_job_icon:path(jp)
                state.target_job_icon:pos(dx, dy)
                state.target_job_icon:size(job_size, job_size)
                state.target_job_icon:show()
                state.visible_job_entry = {
                    icon = state.target_job_icon,
                    title = job or '',
                    tooltip = '',
                }
                dx = dx + job_size + 3
            else
                state.target_job_icon:hide()
                state.visible_job_entry = nil
                if job and job ~= '' then
                    name = name .. ' ' .. tostring(job)
                    state.target_name:text(name)
                    name_w = state.target_name:extents() or (#name * 6)
                    dx = tbar_x + name_w + 8
                end
            end
        else
            state.target_job_icon:hide()
            state.visible_job_entry = nil
        end

        local det_entries = (is_npc and mobdb and mobdb.detection_entries and mobdb.detection_entries(info)) or {}
        ensure_pool(state.target_detect_icons, #det_entries)
        for i = 1, #det_entries do
            local e = det_entries[i]
            local icon = state.target_detect_icons[i]
            local p = detect_icon_path(state, e.file)
            if p then
                icon:path(p)
                icon:pos(dx, dy)
                icon:size(di_size, di_size)
                icon:show()
                state.visible_detect_entries[i] = {
                    icon = icon,
                    title = e.title,
                    tooltip = e.tooltip,
                }
                dx = dx + di_size + 2
            else
                icon:hide()
                state.visible_detect_entries[i] = nil
            end
        end
        for i = #det_entries + 1, #state.target_detect_icons do
            state.target_detect_icons[i]:hide()
            state.visible_detect_entries[i] = nil
        end

        state.target_dist:text(dist_text)
        local dist_w = state.target_dist:extents()
        dist_w = dist_w or (#dist_text * 6)
        state.target_dist:pos(tbar_x + bar_cfg.width - dist_w, tbar_y - 22)
        state.target_dist:show()

        local tot = get_target_of_target(target)
        if tot and tot.name and tot.name ~= '' then
            local tinfo = (tot.is_npc and mobdb and mobdb.get_mob_info) and mobdb.get_mob_info(tot) or nil
            local tr, tg, tb = target_name_color(tot, party_ids, ally_ids, tinfo)
            pcall(function()
                state.target_tot:color(tr, tg, tb)
            end)
            state.target_tot:text('-> ' .. short_name(tot.name, 20))
            state.target_tot:pos(tbar_x + bar_cfg.width + 10, tbar_y - 22)
            state.target_tot:show()
        else
            state.target_tot:hide()
        end

        state.target_pct:text(pct_text)
        local pct_w = state.target_pct:extents()
        local pct_h = select(2, state.target_pct:extents())
        pct_w = pct_w or (#pct_text * 6)
        pct_h = pct_h or 10
        state.target_pct:pos(tbar_x + math.floor((bar_cfg.width - pct_w) * 0.5), tbar_y + math.floor(((bar_cfg.height + 2) - pct_h) * 0.5) - 1)
        state.target_pct:show()

        local entries
        local show_timers = true
        if is_npc then
            entries = debuffs.get_active_entries(logic_state, target.id, icon_cfg.max_target_debuffs)
            sort_target_debuff_entries(entries)
            show_timers = true
        else
            entries = player_buff_entries_for_target(target, logic_state, icon_cfg.max_target_debuffs)
            show_timers = false
        end
        show_icon_grid(
            state,
            state.target_debuffs,
            state.target_debuff_times,
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
    else
        hide_bar(state.target_hp)
        state.target_name:hide()
        state.target_tot:hide()
        state.target_dist:hide()
        state.target_pct:hide()
        state.tooltip:hide()
        state.target_job_icon:hide()
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
    end

    -- Enemy list (graphical): only mobs with aggro on party/alliance.
    local erows = collect_enemy_aggro_rows(settings, mobdb)
    local ex = settings.enemy.x
    local ey = settings.enemy.y
    local ew = math.max(220, math.floor((bar_cfg.width or 500) * 0.62))
    local eh = math.max(7, math.floor((bar_cfg.height or 10) * 0.9))
    local row_gap = eh + 28
    local icon_size = math.max(12, math.floor((icon_cfg.size or 22) * 0.62))
    local icon_gap = 1

    state.enemy_title:text(string.format('ENEMY LIST (%d)', #erows))
    state.enemy_title:pos(ex, ey - 14)
    state.enemy_title:show()

    for i = 1, #erows do
        local e = erows[i]
        local row = ensure_enemy_row(state, i)
        local y = ey + (i - 1) * row_gap

        local mr, mg, mb = health_color(e.hpp)
        set_bar(row.hp, ex, y + 10, ew, eh, e.hpp, 100, mr, mg, mb)

        local nr, ng, nb = target_name_color(e.mob, e.party_ids, e.ally_ids, e.info)
        row.name:text(short_name(e.mob.name or 'Mob', 30))
        pcall(function() row.name:color(nr, ng, nb) end)
        row.name:pos(ex, y - 2)
        row.name:show()

        row.info:text(string.format('%d%%  %.1f', e.hpp, e.distance))
        local iw = row.info:extents() or 64
        row.info:pos(ex + ew - iw, y - 2)
        row.info:show()

        if e.target and e.target.name and e.target.name ~= '' then
            local tr, tg, tb = target_name_color(e.target, e.party_ids, e.ally_ids, nil)
            row.tot:text('-> ' .. short_name(e.target.name, 18))
            pcall(function() row.tot:color(tr, tg, tb) end)
            row.tot:pos(ex + ew + 8, y - 2)
            row.tot:show()
        else
            row.tot:hide()
        end

        local dents = debuffs.get_active_entries(logic_state, e.mob.id, settings.enemy.max_debuffs_per_enemy or 4)
        sort_target_debuff_entries(dents)
        local max_icons = math.min(#dents, settings.enemy.max_debuffs_per_enemy or 4)
        ensure_pool(row.icons, max_icons)
        local shown = 0
        for j = 1, max_icons do
            local did = dents[j].id
            local p = icon_path(state, did)
            if p then
                shown = shown + 1
                local ic = row.icons[shown]
                ic:path(p)
                ic:size(icon_size, icon_size)
                ic:pos(ex + (shown - 1) * (icon_size + icon_gap), y + eh + 13)
                ic:show()
            end
        end
        for j = shown + 1, #row.icons do
            row.icons[j]:hide()
        end
    end

    for i = #erows + 1, #state.enemy_rows do
        local row = state.enemy_rows[i]
        hide_bar(row.hp)
        row.name:hide()
        row.info:hide()
        row.tot:hide()
        hide_pool(row.icons)
    end
end

return M
