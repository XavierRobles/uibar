-- Enemy casts and TP moves. 0x028 category 8 = spell begins, 7 = readies (param 28787 = interrupted),
-- 4/11 = finished. Interrupt messages 16/84/106 flash white. Hostile mobs only.
local res = require('resources')
local util = require('uibarutil')
local party = require('uibarparty')

local M = {}

local BEGIN_PARAM = 24931
local INTERRUPT_PARAM = 28787
local INTERRUPT_MESSAGES = {[16] = true, [84] = true, [106] = true}
local FLASH_SECS = 1.0
local FINISH_GRACE = 2.0
local READY_SECS = 3.0   -- ready time is not in the packet; bar fills over this and waits
local READY_TIMEOUT = 10.0
local SP_NOTICE_SECS = 4.0

-- Two-hour / SP abilities shown as a notice.
local sp_abilities = {
    ['Mighty Strikes'] = true, ['Hundred Fists'] = true, ['Benediction'] = true, ['Manafont'] = true,
    ['Chainspell'] = true, ['Perfect Dodge'] = true, ['Invincible'] = true, ['Blood Weapon'] = true,
    ['Familiar'] = true, ['Soul Voice'] = true, ['Eagle Eye Shot'] = true, ['Meikyo Shisui'] = true,
    ['Mijin Gakure'] = true, ['Call Wyvern'] = true, ['Astral Flow'] = true, ['Azure Lore'] = true,
    ['Wild Card'] = true, ['Overdrive'] = true, ['Trance'] = true, ['Tabula Rasa'] = true,
    ['Bolster'] = true, ['Elemental Sforzo'] = true, ['Charm'] = true,
}

-- [actor_id] = {name, kind = 'spell'|'tp'|'sp', id, target_id, start, duration, interrupted, interrupt_at, progress_at_interrupt}
local casts = {}

local function to_n(v)
    return tonumber(v or 0) or 0
end

local function is_hostile_actor(actor_id)
    if actor_id <= 0 or party.is_member_or_pet(actor_id) then
        return false
    end
    local m = windower.ffxi.get_mob_by_id(actor_id)
    return m ~= nil and m.is_npc == true and to_n(m.spawn_type) ~= 14 and m.in_party ~= true and m.in_alliance ~= true
end

local function ability_name(id)
    if id >= 256 then
        local ma = res.monster_abilities[id]
        return ma and ma.en or nil
    end
    local ws = res.weapon_skills[id]
    if ws then
        return ws.en
    end
    local ja = res.job_abilities[id]
    return ja and ja.en or nil
end

local function interrupt(actor_id)
    local c = casts[actor_id]
    if not c or c.interrupted or c.kind == 'sp' then
        return
    end
    local now_u = util.unix_now()
    c.progress_at_interrupt = math.min(1, (now_u - c.start) / math.max(0.1, c.duration))
    c.interrupted = true
    c.interrupt_at = now_u
end

function M.clear()
    casts = {}
end

M.debug = false

local function trace(fmt, ...)
    if M.debug then
        windower.add_to_chat(207, '[uibar][cast] ' .. string.format(fmt, ...))
    end
end

-- alt_ids: ids from other parsers (Retail 0x028 layouts can disagree); the first that resolves wins.
function M.handle_action(act, alt_ids)
    if type(act) ~= 'table' then
        return
    end
    local actor_id = to_n(act.actor_id or act.Actor)
    local category = to_n(act.category or act.Category)
    local param = to_n(act.param or act.Param)
    if not (category == 4 or category == 6 or category == 7 or category == 8 or category == 11) then
        return
    end
    local hostile = is_hostile_actor(actor_id)
    if M.debug and (category == 7 or category == 8) then
        local m = windower.ffxi.get_mob_by_id(actor_id)
        local t1d = (act.targets or act.Targets or {})[1]
        local a1d = t1d and ((t1d.actions or t1d.Actions or {})[1]) or nil
        trace('cat=%d top=%d a.param=%s a.msg=%s alt=%s actor=%s npc=%s spawn=%s hostile=%s',
            category, param, tostring(a1d and (a1d.param or a1d.Param)), tostring(a1d and (a1d.message or a1d.Message)),
            table.concat(alt_ids or {}, '/'), tostring(m and m.name), tostring(m and m.is_npc),
            tostring(m and m.spawn_type), tostring(hostile))
    end
    if not hostile then
        return
    end
    local targets = act.targets or act.Targets
    local t1 = type(targets) == 'table' and targets[1] or nil
    local actions = t1 and (t1.actions or t1.Actions) or nil
    local a1 = type(actions) == 'table' and actions[1] or nil
    local a_param = to_n(a1 and (a1.param or a1.Param))
    local a_msg = to_n(a1 and (a1.message or a1.Message))
    local target_id = to_n(t1 and (t1.id or t1.ID))
    local now_u = util.unix_now()

    if category == 8 or category == 7 then
        if param == INTERRUPT_PARAM or (category == 7 and a_msg == 0 and param ~= BEGIN_PARAM) then
            interrupt(actor_id)
            return
        end
        local candidates = {a_param}
        for _, v in ipairs(alt_ids or {}) do
            candidates[#candidates + 1] = to_n(v)
        end
        local name, duration, kind, used_id
        for _, cid in ipairs(candidates) do
            if cid > 0 then
                if category == 8 then
                    local sp = res.spells[cid]
                    if sp and sp.en then
                        name, used_id, kind = sp.en, cid, 'spell'
                        duration = math.max(0.5, tonumber(sp.cast_time or 0) or 0)
                    end
                else
                    local n = ability_name(cid)
                    if n then
                        name, used_id, kind, duration = n, cid, 'tp', READY_SECS
                    end
                end
                if name then
                    break
                end
            end
        end
        trace('  -> %s', name and (kind .. ' ' .. name .. ' (id ' .. used_id .. ')') or 'no name resolved')
        if name then
            a_param = used_id
            casts[actor_id] = {
                name = name, kind = kind, id = a_param, target_id = target_id,
                start = now_u, duration = duration,
            }
        end
        return
    end

    -- 6 = job ability: some mobs use 2-hours this way.
    if INTERRUPT_MESSAGES[a_msg] then
        interrupt(actor_id)
        return
    end
    local sp_name = nil
    if category == 11 then
        local ma = res.monster_abilities[param]
        sp_name = ma and sp_abilities[ma.en] and ma.en or nil
    elseif category == 6 then
        local ja = res.job_abilities[param]
        sp_name = ja and sp_abilities[ja.en] and ja.en or nil
    end
    if sp_name then
        casts[actor_id] = {name = sp_name, kind = 'sp', start = now_u, duration = SP_NOTICE_SECS}
    elseif category ~= 6 then
        casts[actor_id] = nil
    end
end

function M.handle_message(basic)
    if type(basic) == 'table' and INTERRUPT_MESSAGES[to_n(basic.message_id)] then
        interrupt(to_n(basic.actor_id))
    end
end

-- Render state or nil: {name, kind, progress 0..1, interrupted, alpha, target_id}
function M.get(actor_id)
    actor_id = to_n(actor_id)
    local c = casts[actor_id]
    if not c then
        return nil
    end
    local now_u = util.unix_now()
    if c.interrupted then
        local e = now_u - c.interrupt_at
        if e >= FLASH_SECS then
            casts[actor_id] = nil
            return nil
        end
        return {name = 'Interrupted', kind = c.kind, progress = c.progress_at_interrupt,
            interrupted = true, alpha = 1 - e / FLASH_SECS}
    end
    local elapsed = now_u - c.start
    local limit = (c.kind == 'tp') and READY_TIMEOUT or (c.duration + (c.kind == 'sp' and 0 or FINISH_GRACE))
    if elapsed > limit then
        casts[actor_id] = nil
        return nil
    end
    local progress = (c.kind == 'sp') and 1 or math.min(1, elapsed / c.duration)
    return {name = c.name, kind = c.kind, progress = progress, interrupted = false, alpha = 1, target_id = c.target_id}
end

return M
