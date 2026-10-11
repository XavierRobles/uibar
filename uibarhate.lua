-- Hate list: mobs fighting our party/alliance (members and pets).
-- A mob stays while there is evidence (acted on us, our claim, targets us, our enfeeble, still engaged).
-- Removals other than death are debounced so one odd scan never makes a row blink.
-- enemy_scan_range only limits which mobs are added.
local util = require('uibarutil')
local party = require('uibarparty')
local debuffs = require('uibardebuffs')

local M = {}

local GRACE_SECS = 10
local PARTY_TOUCH_SECS = 45
local REMOVE_DELAY = 2.0      -- a removal condition must hold this long
local RANGE_KEEP_MARGIN = 15  -- yalms beyond enemy_scan_range before a listed mob is dropped
local SEQ_MEMORY_SECS = 15    -- a mob that comes back quickly keeps its place in the order

local death_messages = {[6] = true, [20] = true, [97] = true, [113] = true, [406] = true, [605] = true, [646] = true}

-- [mob_id] = {seq, last_evidence, acted_at, target_id, target_at, bad_since, bad_reason}
local entries = {}
-- [mob_id] = {seq, at}: recently removed, so a returning mob keeps its place
local recent = {}
local order_seq = 0

M.debug = false

local function to_n(v)
    return tonumber(v or 0) or 0
end

local function trace(fmt, ...)
    if M.debug then
        windower.add_to_chat(207, '[uibar][hate] ' .. string.format(fmt, ...))
    end
end

local function mob_name(id)
    local m = windower.ffxi.get_mob_by_id(id)
    return m and m.name or tostring(id)
end

local function is_hostile_mob(m)
    if type(m) ~= 'table' then
        return false
    end
    if m.in_party == true or m.in_alliance == true then
        return false
    end
    local st = to_n(m.spawn_type)
    if st == 14 then -- trust
        return false
    end
    return m.is_npc == true and (st == 16 or m.is_mob == true)
end

local function touch(mob_id, target_id, reason, acted)
    local now_u = util.unix_now()
    local e = entries[mob_id]
    if not e then
        local r = recent[mob_id]
        local seq
        if r and (now_u - r.at) <= SEQ_MEMORY_SECS then
            seq = r.seq
        else
            order_seq = order_seq + 1
            seq = order_seq
        end
        recent[mob_id] = nil
        e = {seq = seq}
        entries[mob_id] = e
        trace('+ %s (%s)', mob_name(mob_id), reason or '?')
    end
    e.last_evidence = now_u
    if acted then
        e.acted_at = now_u
    end
    if target_id and target_id > 0 then
        e.target_id = target_id
        e.target_at = now_u
    end
end

local function drop(mob_id, reason)
    local e = entries[mob_id]
    if not e then
        return
    end
    entries[mob_id] = nil
    recent[mob_id] = {seq = e.seq, at = util.unix_now()}
    trace('- %s (%s)', mob_name(mob_id), reason or '?')
end

function M.clear()
    entries = {}
    recent = {}
    order_seq = 0
end

function M.remove(mob_id, reason)
    mob_id = to_n(mob_id)
    if entries[mob_id] then
        drop(mob_id, reason or 'death')
    end
    recent[mob_id] = nil
end

function M.handle_action(act)
    if type(act) ~= 'table' then
        return
    end
    local actor_id = to_n(act.actor_id or act.Actor or act.actor)
    local targets = act.targets or act.Targets
    if actor_id <= 0 or type(targets) ~= 'table' then
        return
    end

    -- Deaths reported inside action packets.
    for _, t in pairs(targets) do
        local acts = t.actions or t.Actions
        if type(acts) == 'table' then
            for _, a in pairs(acts) do
                if death_messages[to_n(a.message or a.Message)] then
                    M.remove(to_n(t.id or t.ID), 'death msg')
                end
            end
        end
    end

    if party.is_member_or_pet(actor_id) then
        return
    end
    local actor = windower.ffxi.get_mob_by_id(actor_id)
    if not is_hostile_mob(actor) or to_n(actor.hpp) <= 0 then
        return
    end
    for _, t in pairs(targets) do
        local tid = to_n(t.id or t.ID)
        if tid > 0 and party.is_member_or_pet(tid) then
            touch(actor_id, tid, 'acted on us', true)
            return
        end
    end
end

function M.handle_message(basic)
    if type(basic) == 'table' and death_messages[to_n(basic.message_id)] then
        M.remove(basic.target_id, 'death msg')
    end
end

local function resolve_target(mob, e, by_index, now_u)
    local tix = to_n(mob.target_index)
    if tix > 0 then
        local m = by_index[tix] or windower.ffxi.get_mob_by_index(tix)
        if m and m.name and m.name ~= '' then
            return m
        end
    end
    -- Fall back to the last member this mob acted on.
    if e and to_n(e.target_id) > 0 and (now_u - to_n(e.target_at)) <= GRACE_SECS then
        for _, m in pairs(by_index) do
            if m.id == e.target_id then
                return m
            end
        end
        local m = windower.ffxi.get_mob_by_id(e.target_id)
        if m and m.name and m.name ~= '' then
            return m
        end
    end
    return nil
end

-- Our enfeebles only; a mob's own buffs say nothing about hate.
local function has_active_debuff(logic_state, mid, now_u)
    local dset = logic_state and logic_state.mob_debuffs and logic_state.mob_debuffs[mid] or nil
    if type(dset) ~= 'table' then
        return false
    end
    for buff_id, expires in pairs(dset) do
        if to_n(expires) > now_u and debuffs.is_negative_player_status(buff_id) then
            return true
        end
    end
    return false
end

local function targets_outsider(mob, tix, by_index)
    if tix <= 0 or by_index[tix] or tix == to_n(mob.index) then
        return false
    end
    local t = windower.ffxi.get_mob_by_index(tix)
    return t ~= nil and t.is_npc == false
end

-- True once `reason` has held for REMOVE_DELAY.
local function bad_for_long(e, reason, now_u)
    if e.bad_reason ~= reason then
        e.bad_reason = reason
        e.bad_since = now_u
        return false
    end
    return (now_u - e.bad_since) >= REMOVE_DELAY
end

local sorters = {
    aggro = function(a, b)
        return a.seq < b.seq
    end,
    distance = function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.seq < b.seq
    end,
    hp = function(a, b)
        if a.hpp ~= b.hpp then
            return a.hpp < b.hpp
        end
        return a.seq < b.seq
    end,
}

-- Rows sorted by settings.enemy_sort: {mob, target, distance, hpp, seq, claim_is_ours}
function M.collect(settings, logic_state)
    local mobs = windower.ffxi.get_mob_array()
    if type(mobs) ~= 'table' then
        return {}
    end
    local party_ids, ally_ids, all_ids = party.get_claim_sets()
    local pet_ids = party.get_pet_ids()
    local by_index = party.get_member_index_map()
    local now_u = util.unix_now()
    -- 0 = no limit.
    local range = to_n(settings and settings.enemy_scan_range)
    local add_sq = range > 0 and range * range or math.huge
    local keep_sq = range > 0 and (range + RANGE_KEEP_MARGIN) ^ 2 or math.huge
    local touches = logic_state and logic_state.mob_party_touch or nil
    local seen = {}
    local rows = {}

    for _, mob in pairs(mobs) do
        if is_hostile_mob(mob) then
            local mid = to_n(mob.id)
            local status = to_n(mob.status)
            local dead = to_n(mob.hpp) <= 0 or status == 2 or status == 3
            local e = entries[mid]
            if mid > 0 then
                seen[mid] = true
            end

            if mid <= 0 then
            elseif dead then
                if e then
                    drop(mid, 'dead')
                end
            else
                local dist_sq = tonumber(mob.distance)
                local claim_id = to_n(mob.claim_id)
                local claim_is_ours = claim_id > 0 and (all_ids[claim_id] == true or pet_ids[claim_id] == true)
                local foreign_claim = claim_id > 0 and not claim_is_ours
                local tix = to_n(mob.target_index)
                local targets_us = tix > 0 and by_index[tix] ~= nil
                local outsider = targets_outsider(mob, tix, by_index)
                local touched_at = touches and to_n(touches[mid]) or 0
                local touched = touched_at > 0 and (now_u - touched_at) <= PARTY_TOUCH_SECS
                local debuffed = has_active_debuff(logic_state, mid, now_u)
                local acted_recently = e and e.acted_at and (now_u - e.acted_at) <= GRACE_SECS

                -- New mobs must be within range; listed ones keep refreshing.
                local can_add = e ~= nil or (dist_sq == nil or dist_sq <= add_sq)
                if can_add and not foreign_claim then
                    if claim_is_ours or targets_us then
                        touch(mid, targets_us and by_index[tix].id or nil, claim_is_ours and 'claim' or 'targets us')
                    elseif touched or debuffed then
                        touch(mid, nil, debuffed and 'our enfeeble' or 'party touch')
                    elseif e and status == 1 and not outsider then
                        touch(mid, nil, 'engaged')
                    end
                elseif e and acted_recently then
                    -- Claimed by someone else but still hitting us.
                    e.last_evidence = now_u
                end
                e = entries[mid]

                if e then
                    local reason = nil
                    if foreign_claim and not acted_recently then
                        reason = 'claimed by other'
                    elseif outsider and not claim_is_ours and not acted_recently then
                        reason = 'targets outsider'
                    elseif dist_sq and dist_sq > keep_sq then
                        reason = 'out of range'
                    end
                    if reason then
                        if bad_for_long(e, reason, now_u) then
                            drop(mid, reason)
                            e = nil
                        end
                    else
                        e.bad_reason, e.bad_since = nil, nil
                    end
                end

                if e and (now_u - to_n(e.last_evidence)) > GRACE_SECS then
                    drop(mid, 'no hate evidence')
                    e = nil
                end

                if e then
                    rows[#rows + 1] = {
                        mob = mob,
                        target = resolve_target(mob, e, by_index, now_u),
                        distance = math.sqrt(math.max(0, dist_sq or 0)),
                        hpp = to_n(mob.hpp),
                        seq = e.seq,
                        claim_is_ours = claim_is_ours,
                        party_ids = party_ids,
                        ally_ids = ally_ids,
                    }
                end
            end
        end
    end

    -- The entity array can miss a mob for a frame, so despawns are debounced too.
    for mid, e in pairs(entries) do
        if not seen[mid] and bad_for_long(e, 'despawned', now_u) then
            drop(mid, 'despawned')
        end
    end
    for mid, r in pairs(recent) do
        if now_u - r.at > SEQ_MEMORY_SECS then
            recent[mid] = nil
        end
    end

    local sorter = sorters[settings and settings.enemy_sort or 'aggro'] or sorters.aggro
    table.sort(rows, sorter)

    local maxn = math.max(1, to_n(settings and settings.max_enemies or 8))
    for i = #rows, maxn + 1, -1 do
        rows[i] = nil
    end
    return rows
end

return M
