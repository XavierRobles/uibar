local util = require('uibarutil')
local debuffs = require('uibardebuffs')
local hate = require('uibarhate')

local M = {}

local function colorize(text, r, g, b)
    return string.format('\\cs(%d,%d,%d)%s\\cr', r, g, b, text)
end

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

local function mana_color(pct)
    if pct >= 60 then
        return 110, 170, 255
    elseif pct >= 30 then
        return 120, 130, 230
    end
    return 100, 95, 180
end

local function tp_color(tp)
    if tp >= 2000 then
        return 255, 210, 80
    elseif tp >= 1000 then
        return 240, 165, 80
    end
    return 170, 140, 95
end

local function to_n(v)
    return tonumber(v or 0) or 0
end

function M.format_main(settings)
    local player = windower.ffxi.get_player()
    if not player then
        return 'MAIN\nEsperando datos de personaje...'
    end

    local hp = player.vitals and player.vitals.hp or 0
    local hp_max = player.vitals and player.vitals.max_hp or 1
    local mp = player.vitals and player.vitals.mp or 0
    local mp_max = player.vitals and player.vitals.max_mp or 1
    local tp = player.vitals and player.vitals.tp or 0

    local buffs = {}
    local player_debuffs = {}
    for _, buff_id in ipairs(player.buffs or {}) do
        if buff_id and buff_id > 0 then
            local name = debuffs.buff_name(buff_id)
            if debuffs.is_negative_player_status(buff_id) then
                player_debuffs[#player_debuffs + 1] = name
            else
                buffs[#buffs + 1] = name
            end
        end
    end

    local hp_pct = math.floor((hp / math.max(1, hp_max)) * 100 + 0.5)
    local mp_pct = math.floor((mp / math.max(1, mp_max)) * 100 + 0.5)
    local hp_r, hp_g, hp_b = health_color(hp_pct)
    local mp_r, mp_g, mp_b = mana_color(mp_pct)
    local tp_r, tp_g, tp_b = tp_color(tp)
    buffs = util.shorten(buffs, settings.main.max_buffs)
    player_debuffs = util.shorten(player_debuffs, settings.main.max_debuffs)

    local lines = {
        string.format('%s  %s  %s', colorize('MAIN', 235, 235, 235), player.name or 'Player', colorize('(' .. (player.main_job_full or '') .. ')', 170, 190, 220)),
        colorize(string.format('HP %4d/%4d %3d%%', hp, hp_max, hp_pct), hp_r, hp_g, hp_b),
        colorize(string.format('MP %4d/%4d %3d%%', mp, mp_max, mp_pct), mp_r, mp_g, mp_b),
        colorize(string.format('TP %4d', tp), tp_r, tp_g, tp_b),
        colorize('BUFF :', 145, 210, 255) .. ' [icons]',
        colorize('DEBUFF:', 255, 130, 130) .. ' [icons]',
    }

    return table.concat(lines, '\n')
end

function M.format_target(settings, state)
    local target = windower.ffxi.get_mob_by_target('t')
    if not target or not target.is_npc or not target.valid_target then
        return 'TARGET\nSin target de enemigo.'
    end

    local hpp = target.hpp or 0
    local hp_r, hp_g, hp_b = health_color(hpp)
    local distance = math.sqrt(math.max(0, target.distance or 0))
    local claimed = target.claim_id and target.claim_id ~= 0
    local claim_str = claimed and colorize('claim:' .. tostring(target.claim_id), 230, 170, 85) or colorize('claim:-', 145, 145, 145)
    local dlist = debuffs.get_active_names(state, target.id, settings.enemy.max_debuffs_per_enemy)
    local lines = {
        string.format('%s  %s', colorize('TARGET', 240, 235, 200), util.sanitize_name(target.name)),
        colorize(string.format('HP %3d%%', hpp), hp_r, hp_g, hp_b),
        string.format('DIST %.1fy  %s', distance, claim_str),
        colorize('DEBUFF: ', 255, 130, 130) .. ((#dlist > 0 and table.concat(dlist, '/')) or '-'),
    }

    return table.concat(lines, '\n')
end

function M.format_enemy_list(settings, state)
    local rows = hate.collect(settings, state)
    local enemies = {}
    for _, r in ipairs(rows) do
        local claimed = to_n(r.mob.claim_id) > 0
        enemies[#enemies + 1] = {
            id = r.mob.id,
            name = util.sanitize_name(r.mob.name),
            hpp = r.hpp,
            distance = r.distance,
            target = r.target and util.sanitize_name(r.target.name) or '?',
            label = r.claim_is_ours and '[PT]' or (claimed and '[CL]' or '[AG]'),
        }
    end

    local lines = {string.format('%s (%d)', colorize('ENEMY LIST', 235, 235, 235), #enemies)}
    if #enemies == 0 then
        lines[#lines + 1] = 'Sin aggro en party/alliance.'
        return table.concat(lines, '\n')
    end

    for i, e in ipairs(enemies) do
        local dlist = debuffs.get_active_names(state, e.id, settings.enemy.max_debuffs_per_enemy)
        local label = e.label
        if e.label == '[PT]' then
            label = colorize(e.label, 140, 230, 145)
        elseif e.label == '[CL]' then
            label = colorize(e.label, 240, 185, 100)
        else
            label = colorize(e.label, 210, 140, 115)
        end

        local hp_r, hp_g, hp_b = health_color(e.hpp)
        local hpp = colorize(string.format('%3d%%', e.hpp), hp_r, hp_g, hp_b)
        lines[#lines + 1] = string.format(
            '%d. %s %s %s %4.1fy -> %s {%s}',
            i, label, e.name, hpp, e.distance, e.target, table.concat(dlist, '/')
        )
    end

    return table.concat(lines, '\n')
end

return M
