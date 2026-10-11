require('tables')

local res = require('resources')
local util = require('uibarutil')
local party = require('uibarparty')

local M = {}

local status_on_messages = S{
    101, 127, 160, 164, 166, 186, 194, 203, 205, 230, 236, 266, 267, 268, 269,
    237, 271, 272, 277, 278, 279, 280, 319, 320, 375, 412, 645, 754, 755, 804, 141
}
local status_off_messages = S{64, 83, 159, 168, 204, 206, 321, 322, 341, 342, 343, 344, 350, 378, 531, 647, 805, 806}
local death_messages = S{6, 20, 97, 113, 406, 605, 646}
local spell_damage_messages = S{2, 252, 264, 265}
-- Retail Dia/Bio overwrite order. A failed overwrite still deals damage, so damage alone is not proof.
local dot_priority = {
    [23] = 1, [33] = 1, -- Dia, Diaga
    [230] = 2,          -- Bio
    [24] = 3,           -- Dia II
    [231] = 4,          -- Bio II
    [25] = 5,           -- Dia III
    [232] = 6,          -- Bio III
}
-- Natural wear-off messages (used to learn real durations).
local natural_wear_messages = S{204, 206}
-- Often broken early (damage wakes/unbinds): learn upward only.
local early_ending_buffs = S{2, 10, 11, 19, 193}
local sleep_family_ids = {2, 19, 193}
local learned_duration = {}
local PARTY_TOUCH_KEEP_SECS = 60
local monster_ability_status_overrides = {
    [3564] = 173, -- Aetheric Pull -> Dread Spikes
}

local known_debuff_duration = {
    [2] = 60, [3] = 120, [4] = 120, [5] = 180, [6] = 120, [10] = 5, [11] = 60, [12] = 120, [13] = 180,
    [19] = 90, [128] = 180, [129] = 180, [130] = 180, [131] = 180, [132] = 180, [133] = 180,
    [134] = 150, [135] = 150, [147] = 180, [148] = 180, [149] = 180, [167] = 120, [173] = 45, [186] = 90, [193] = 30, [194] = 216, [404] = 120
}

-- Durations by spell id (preferred over the buff-id table).
local spell_duration = {
    -- Dia/Bio
    [23] = 60, [24] = 120, [25] = 150, [33] = 60, [230] = 60, [231] = 120, [232] = 150,
    -- Core enfeebles
    [58] = 120, [80] = 120, [56] = 180, [79] = 180, [216] = 120, [254] = 180, [276] = 180,
    [59] = 120, [359] = 120, [253] = 60, [273] = 60, [363] = 60, [259] = 90, [274] = 90, [364] = 90,
    [258] = 60, [362] = 60, [252] = 5, [220] = 90, [221] = 120,
    -- Ninjutsu enfeebles
    [341] = 180, [342] = 300, [344] = 180, [345] = 300, [347] = 180, [348] = 300,
    -- Elemental debuffs
    [235] = 120, [236] = 120, [237] = 120, [238] = 120, [239] = 120, [240] = 120,
    -- BRD
    [376] = 30, [377] = 30, [463] = 30, [464] = 30, [421] = 216, [422] = 216,
    [454] = 78, [455] = 78, [456] = 78, [457] = 78, [458] = 78, [459] = 78, [460] = 78, [461] = 78,
    [368] = 120, [369] = 120, [370] = 120, [371] = 120, [372] = 120, [373] = 120, [374] = 120, [375] = 120,
    -- Helix
    [278] = 90, [279] = 90, [280] = 90, [281] = 90, [282] = 90, [283] = 90, [284] = 90, [285] = 90,
    [885] = 90, [886] = 90, [887] = 90, [888] = 90, [889] = 90, [890] = 90, [891] = 90, [892] = 90,
    -- BLU
    [722] = 60, [727] = 300, [728] = 180, -- Entomb / Silent Storm / Tenebral Crush
}

local bard_spell_duration = {
    [368] = 120, [369] = 120, [370] = 120, [371] = 120, [372] = 120, [373] = 120, [374] = 120, [375] = 120, -- Requiem
    [376] = 30,  [377] = 30, [463] = 30, [464] = 30,                                                          -- Lullaby
    [421] = 216, [422] = 216,                                                                                  -- Elegy
    [454] = 78,  [455] = 78,  [456] = 78,  [457] = 78,  [458] = 78,  [459] = 78,  [460] = 78,  [461] = 78,  -- Threnody
}

local spell_to_buff = {
    [230] = 135, [23] = 134, [24] = 134, [25] = 134,
    [58] = 4, [80] = 4, [56] = 13, [79] = 13, [357] = 13,
    [216] = 12, [217] = 12, [254] = 5, [276] = 5, [361] = 5,
    [59] = 6, [359] = 6, [253] = 2, [259] = 2, [273] = 2, [274] = 2,
    [258] = 11, [362] = 11, [252] = 10,
    [220] = 3, [221] = 3, [222] = 3, [223] = 3, [224] = 3, [225] = 3, [226] = 3, [227] = 3, [228] = 3, [229] = 3, [536] = 3,
    [239] = 132, [238] = 131, [237] = 130, [236] = 129, [608] = 129, [235] = 128, [240] = 133,
    [421] = 194, [422] = 194, [423] = 194,
    [368] = 192, [369] = 192, [370] = 192, [371] = 192, [372] = 192, [373] = 192,
    [463] = 193, [464] = 193, [376] = 193, [377] = 193,
    [454] = 217, [455] = 217, [456] = 217, [457] = 217, [458] = 217, [459] = 217, [460] = 217, [461] = 217,
    [278] = 186, [279] = 186, [280] = 186, [281] = 186, [282] = 186, [283] = 186, [284] = 186, [285] = 186,
    [885] = 186, [886] = 186, [887] = 186, [888] = 186, [889] = 186, [890] = 186, [891] = 186, [892] = 186,
    [722] = 7, [727] = 6, [728] = 149, -- Entomb / Silent Storm / Tenebral Crush
}

local spell_effects = {
    [23] = {buff = 134, duration = 60, clear = 135, on_damage = true},     -- Dia
    [24] = {buff = 134, duration = 120, clear = 135, on_damage = true},    -- Dia II
    [25] = {buff = 134, duration = 150, clear = 135, on_damage = true},    -- Dia III
    [33] = {buff = 134, duration = 60, clear = 135, on_damage = true},     -- Diaga
    [230] = {buff = 135, duration = 60, clear = 134, on_damage = true},    -- Bio
    [231] = {buff = 135, duration = 120, clear = 134, on_damage = true},   -- Bio II
    [232] = {buff = 135, duration = 150, clear = 134, on_damage = true},   -- Bio III
    [421] = {buff = 194, duration = 216},                                   -- Battlefield Elegy
    [422] = {buff = 194, duration = 216},                                   -- Carnage Elegy
    [278] = {buff = 186, duration = 90, on_damage = true},
    [279] = {buff = 186, duration = 90, on_damage = true},
    [280] = {buff = 186, duration = 90, on_damage = true},
    [281] = {buff = 186, duration = 90, on_damage = true},
    [282] = {buff = 186, duration = 90, on_damage = true},
    [283] = {buff = 186, duration = 90, on_damage = true},
    [284] = {buff = 186, duration = 90, on_damage = true},
    [285] = {buff = 186, duration = 90, on_damage = true},
    [885] = {buff = 186, duration = 90, on_damage = true},
    [886] = {buff = 186, duration = 90, on_damage = true},
    [887] = {buff = 186, duration = 90, on_damage = true},
    [888] = {buff = 186, duration = 90, on_damage = true},
    [889] = {buff = 186, duration = 90, on_damage = true},
    [890] = {buff = 186, duration = 90, on_damage = true},
    [891] = {buff = 186, duration = 90, on_damage = true},
    [892] = {buff = 186, duration = 90, on_damage = true},
    -- BLU AoE enfeebles deal damage even when resisted: track from explicit status-on only.
    [722] = {buff = 7},                                                     -- Entomb
    [727] = {buff = 6, duration = 300},                                     -- Silent Storm
    [728] = {buff = 149},                                                   -- Tenebral Crush
}

-- AoE CC that some parsers/servers report without per-target status messages.
local aoe_cc_spells = {
    [253] = true, -- Sleep
    [273] = true, -- Sleepga
    [363] = true, -- Sleepga II
    [259] = true, -- Sleep II
    [274] = true, -- Sleepga II
    [364] = true, -- Sleepga III
    [376] = true, -- Foe Lullaby
    [377] = true, -- Foe Lullaby II
    [463] = true, -- Horde Lullaby
    [464] = true, -- Horde Lullaby II
}
local lullaby_spells = {
    [376] = true, -- Foe Lullaby
    [377] = true, -- Foe Lullaby II
    [463] = true, -- Horde Lullaby
    [464] = true, -- Horde Lullaby II
}
local wake_damage_messages = {
    [1] = true,   -- melee/ranged hit
    [67] = true,  -- critical hit
    [2] = true,   -- spell damage
    [185] = true, -- weaponskill/job ability damage
    [252] = true, -- spell damage variant
    [264] = true, -- spell damage variant
    [265] = true, -- spell damage variant
}
local negative_player_status = S{
    2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 19, 21, 28, 29, 30, 31, 128, 129, 130, 131, 132, 133, 134, 135,
    136, 137, 138, 139, 140, 141, 142, 144, 145, 146, 147, 148, 149, 156, 167, 168, 174, 175, 186,
    192, 193, 194, 217, 404, 597,
    386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400, -- Step dazes
    448, 449, 450, 451, 452,
}
-- DNC steps: message -> first buff id of that daze family; param is the daze level (1-5).
local step_daze_messages = {
    [519] = 386, -- Quickstep: Lethargic Daze
    [520] = 391, -- Box Step: Sluggish Daze
    [521] = 396, -- Stutter Step: Weakened Daze
    [591] = 448, -- Feather Step: Bewildered Daze
}
local STEP_DAZE_SECS = 60
local claim_cache = {
    at = 0,
    all_ids = {},
}
local bard_actor_cache = {
    at = 0,
    ids = {},
}
local claim_cache_ttl = 0.20
local bard_cache_ttl = 0.75

function M.is_negative_player_status(buff_id)
    return negative_player_status:contains(buff_id)
end

function M.is_positive_player_status(buff_id)
    return (tonumber(buff_id) or 0) > 0 and not negative_player_status:contains(buff_id)
end

function M.is_trackable_enemy_status(buff_id)
    local id = tonumber(buff_id or 0) or 0
    return id > 0 and id <= 1024 and res.buffs[id] ~= nil
end

local function get_all_ids_cached()
    local now_u = util.unix_now()
    if type(claim_cache.all_ids) == 'table' and (now_u - (tonumber(claim_cache.at or 0) or 0)) <= claim_cache_ttl then
        return claim_cache.all_ids
    end
    local _, _, all_ids = party.get_claim_sets()
    claim_cache.all_ids = all_ids or {}
    claim_cache.at = now_u
    return claim_cache.all_ids
end

function M.buff_name(buff_id)
    local entry = res.buffs[buff_id]
    if not entry then
        return tostring(buff_id)
    end
    return entry.en or tostring(buff_id)
end

local function spell_tier(spell_id)
    local s = spell_id and res.spells[spell_id]
    local n = s and s.en or ''
    if n == '' then
        return nil
    end
    if n:find(' V', 1, true) then return 5 end
    if n:find(' IV', 1, true) then return 4 end
    if n:find(' III', 1, true) then return 3 end
    if n:find(' II', 1, true) then return 2 end
    return nil
end

local tier_markable_buffs = {[3] = true, [5] = true, [134] = true, [135] = true} -- Poison, Blind, Dia, Bio

function M.resolve_tier_label(buff_id, spell_id)
    if tonumber(buff_id or 0) == 19 then
        return '2' -- Sleep II
    end
    if tonumber(buff_id or 0) == 193 then
        local t = spell_tier(spell_id)
        if t and t >= 2 then
            return tostring(t) -- Lullaby II
        end
    end
    if not tier_markable_buffs[tonumber(buff_id or 0)] then
        return nil
    end
    local t = spell_tier(spell_id)
    if t and t >= 2 then
        return tostring(t)
    end
    return nil
end

local function spell_name(spell_id)
    local s = spell_id and res.spells[spell_id]
    return (s and s.en) or ''
end

local function infer_family_buff(spell_id)
    local n = spell_name(spell_id)
    if n == '' then
        return nil
    end
    if n:find('Dia', 1, true) == 1 then
        return 134
    end
    if n:find('Bio', 1, true) == 1 then
        return 135
    end
    if n == 'Entomb' then
        return 7
    end
    if n == 'Tenebral Crush' then
        return 149
    end
    return nil
end

local function infer_named_effect(spell_id)
    local n = spell_name(spell_id)
    if n == '' then
        return nil
    end
    if n == 'Entomb' then
        return {buff = 7}
    end
    if n == 'Silent Storm' then
        return {buff = 6, duration = 300}
    end
    if n == 'Tenebral Crush' then
        return {buff = 149}
    end
    return nil
end

local function infer_spell_status_buff(spell_id)
    local sid = tonumber(spell_id or 0) or 0
    if sid <= 0 then
        return nil
    end
    local s = res.spells and res.spells[sid] or nil
    local buff_id = tonumber(s and s.status or 0) or 0
    if buff_id > 0 and buff_id <= 1024 and res.buffs[buff_id] then
        return buff_id
    end
    return nil
end

local function parse_override_duration(value)
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

local function resolve_kind_override(tbl, id)
    if type(tbl) ~= 'table' then
        return nil
    end
    local n = tonumber(id or 0) or 0
    if n <= 0 then
        return nil
    end
    local key = 'id_' .. tostring(n)
    local d = parse_override_duration(tbl[n]) or parse_override_duration(tbl[tostring(n)]) or parse_override_duration(tbl[key])
    if d and d > 0 then
        return d
    end
    return nil
end

local function resolve_duration_override(state, buff_id, spell_id)
    local ov = state and state.duration_overrides or nil
    if type(ov) ~= 'table' then
        return nil
    end

    local sid = tonumber(spell_id or 0) or 0
    if sid > 0 and type(ov.spell) == 'table' then
        local d = resolve_kind_override(ov.spell, sid)
        if d then
            return d
        end
    end

    local bid = tonumber(buff_id or 0) or 0
    if bid > 0 and type(ov.buff) == 'table' then
        local d = resolve_kind_override(ov.buff, bid)
        if d then
            return d
        end
    end

    return nil
end

local function monster_ability_status(ability_id)
    local id = tonumber(ability_id or 0) or 0
    if id <= 0 then
        return nil
    end
    local forced_status = tonumber(monster_ability_status_overrides[id] or 0) or 0
    if forced_status > 0 and forced_status <= 1024 and res.buffs[forced_status] then
        return forced_status
    end
    local ability = res.monster_abilities and res.monster_abilities[id] or nil
    local status_id = tonumber(ability and ability.status or 0) or 0
    if status_id > 0 and status_id <= 1024 and res.buffs[status_id] then
        return status_id
    end
    return nil
end

local function monster_ability_actor_status(ability_id)
    local id = tonumber(ability_id or 0) or 0
    if id <= 0 then
        return nil
    end
    local forced_status = tonumber(monster_ability_status_overrides[id] or 0) or 0
    if forced_status > 0 and forced_status <= 1024 and res.buffs[forced_status] then
        return forced_status
    end
    return nil
end

local function is_spike_buff(buff_id)
    local id = tonumber(buff_id or 0) or 0
    if id <= 0 or id > 1024 then
        return false
    end
    local b = res.buffs and res.buffs[id] or nil
    if not b then
        return false
    end
    local en = string.lower(tostring(b.en or b.enl or ''))
    return en:find('spikes', 1, true) ~= nil
end

local function resolve_buff_id(act, action)
    local action_type = tonumber(act.category or act.type or act.Type or 0) or 0
    local spell_like = (action_type == 0 or action_type == 4 or action_type == 8)
    local spell_id = tonumber(act.param or act.Param or 0) or 0
    if spell_id > 0 and (action_type == 11 or action_type == 7) then
        local status_id = monster_ability_status(spell_id)
        if status_id then
            return status_id
        end
    end
    if spell_like and spell_id > 0 and aoe_cc_spells[spell_id] and spell_to_buff[spell_id] then
        return spell_to_buff[spell_id]
    end
    local buff_id = action.param or action.Param
    -- action.param may hold a spell id; accept it only if it is a real buff id.
    if buff_id and buff_id > 0 and buff_id <= 1024 and res.buffs[buff_id] then
        return buff_id
    end

    if action_type == 4 and spell_id > 0 and spell_to_buff[spell_id] then
        return spell_to_buff[spell_id]
    end

    if spell_like and spell_id > 0 and spell_to_buff[spell_id] then
        return spell_to_buff[spell_id]
    end

    if spell_like then
        local inferred_status = infer_spell_status_buff(spell_id)
        if inferred_status then
            return inferred_status
        end
    end

    if spell_like then
        local inferred = infer_family_buff(spell_id)
        if inferred then
            return inferred
        end
    end

    return nil
end

local function resolve_duration(buff_id, spell_id)
    if spell_id and spell_duration[spell_id] then
        return spell_duration[spell_id]
    end
    if spell_id and bard_spell_duration[spell_id] then
        return bard_spell_duration[spell_id]
    end
    if known_debuff_duration[buff_id] then
        return known_debuff_duration[buff_id]
    end
    if spell_id then
        local s = res.spells[spell_id]
        local d = s and tonumber(s.duration or 0) or 0
        if d and d > 0 then
            return d
        end
    end
    return 299
end

local function is_sleep_family_buff(buff_id)
    local b = tonumber(buff_id or 0) or 0
    return b == 2 or b == 19 or b == 193
end

local function spell_is_sleep_family(spell_id)
    local sid = tonumber(spell_id or 0) or 0
    if sid <= 0 then
        return false
    end
    local mapped = tonumber(spell_to_buff[sid] or 0) or 0
    if is_sleep_family_buff(mapped) then
        return true
    end
    return false
end

local function is_brd_job(v)
    if type(v) == 'number' then
        return v == 10
    end
    if type(v) == 'string' then
        local s = string.upper(v)
        return s == 'BRD' or s == 'BARD'
    end
    return false
end

local function member_job_is_brd(m)
    if type(m) ~= 'table' then
        return false
    end
    if is_brd_job(m.main_job_id) or is_brd_job(m.main_job) or is_brd_job(m.mjob) or is_brd_job(m.job) then
        return true
    end
    local mob = m.mob
    if type(mob) == 'table' then
        if is_brd_job(mob.main_job_id) or is_brd_job(mob.main_job) or is_brd_job(mob.mjob) or is_brd_job(mob.job) then
            return true
        end
    end
    return false
end

local function refresh_bard_actor_cache(windower_ref)
    local now_u = util.unix_now()
    if type(bard_actor_cache.ids) == 'table' and (now_u - (tonumber(bard_actor_cache.at or 0) or 0)) <= bard_cache_ttl then
        return bard_actor_cache.ids
    end

    local ids = {}
    local ffxi = windower_ref and windower_ref.ffxi or nil
    local pt = ffxi and ffxi.get_party and ffxi.get_party() or nil
    if type(pt) == 'table' then
        for _, m in pairs(pt) do
            if type(m) == 'table' and member_job_is_brd(m) then
                local mid = tonumber((m.mob and m.mob.id) or m.mob_id or m.id or 0) or 0
                if mid > 0 then
                    ids[mid] = true
                end
            end
        end
    end

    local me = ffxi and ffxi.get_player and ffxi.get_player() or nil
    local myid = tonumber(me and me.id or 0) or 0
    if myid > 0 and me and (is_brd_job(me.main_job_id) or is_brd_job(me.main_job) or is_brd_job(me.mjob) or is_brd_job(me.job)) then
        ids[myid] = true
    end

    bard_actor_cache.ids = ids
    bard_actor_cache.at = now_u
    return ids
end

local function actor_is_bard(windower_ref, actor_id)
    local aid = tonumber(actor_id or 0) or 0
    if aid <= 0 then
        return false
    end
    local ids = refresh_bard_actor_cache(windower_ref)
    return ids[aid] == true
end

local function pick_sleep_family_from_values(v1, v2, v3)
    local a = tonumber(v1 or 0) or 0
    local b = tonumber(v2 or 0) or 0
    local c = tonumber(v3 or 0) or 0
    if a == 193 or b == 193 or c == 193 then
        return 193
    end
    if a == 19 or b == 19 or c == 19 then
        return 19
    end
    if a == 2 or b == 2 or c == 2 then
        return 2
    end
    return 0
end

local function learned_key(actor_id, spell_id)
    local aid = tonumber(actor_id or 0) or 0
    local sid = tonumber(spell_id or 0) or 0
    if aid <= 0 or sid <= 0 then
        return nil
    end
    return aid * 4096 + sid
end

local function apply_debuff(state, tid, buff_id, duration, clear_buff, spell_id, actor_id)
    if not state.mob_debuffs[tid] then
        state.mob_debuffs[tid] = {}
    end
    state.mob_debuff_marks = state.mob_debuff_marks or {}
    state.mob_debuff_marks[tid] = state.mob_debuff_marks[tid] or {}
    -- Sleep family is mutually exclusive.
    if is_sleep_family_buff(buff_id) then
        state.mob_debuffs[tid][2] = nil
        state.mob_debuffs[tid][19] = nil
        state.mob_debuffs[tid][193] = nil
        state.mob_debuff_marks[tid][2] = nil
        state.mob_debuff_marks[tid][19] = nil
        state.mob_debuff_marks[tid][193] = nil
    end
    if clear_buff then
        state.mob_debuffs[tid][clear_buff] = nil
        state.mob_debuff_marks[tid][clear_buff] = nil
    end
    local forced = resolve_duration_override(state, buff_id, spell_id)
    local key = learned_key(actor_id, spell_id)
    local learned = key and learned_duration[key] or nil
    local base = duration or resolve_duration(buff_id, spell_id)
    local final_duration = forced or learned or base
    local now_u = util.unix_now()
    state.mob_debuffs[tid][buff_id] = now_u + final_duration
    state.mob_debuff_marks[tid][buff_id] = M.resolve_tier_label(buff_id, spell_id)
    state.mob_debuff_meta = state.mob_debuff_meta or {}
    state.mob_debuff_meta[tid] = state.mob_debuff_meta[tid] or {}
    state.mob_debuff_meta[tid][buff_id] = {
        at = now_u,
        spell_id = tonumber(spell_id or 0) or 0,
        key = key,
        base = base,
        forced = forced ~= nil,
        predicted = final_duration,
        actor = tonumber(actor_id or 0) or 0,
    }
end

-- On a natural wear-off, remember how long it really lasted for this caster + spell.
local function learn_duration(state, tid, buff_id)
    local metas = state.mob_debuff_meta and state.mob_debuff_meta[tid] or nil
    if not metas then
        return
    end
    local meta_id = buff_id
    if not metas[meta_id] and (buff_id == 2 or buff_id == 19 or buff_id == 193) then
        -- Lullaby goes on as 193 but can wear off reported as plain sleep (and vice versa).
        for _, sid in ipairs(sleep_family_ids) do
            if metas[sid] then
                meta_id = sid
                break
            end
        end
    end
    local meta = metas[meta_id]
    metas[meta_id] = nil
    if not meta or meta.forced or not meta.key then
        return
    end
    local observed = util.unix_now() - (meta.at or 0)
    local base = tonumber(meta.base or 0) or 0
    if base <= 0 then
        return
    end
    local prev = learned_duration[meta.key]
    if early_ending_buffs:contains(meta_id) then
        -- Keep the longest natural duration seen.
        if observed > (tonumber(meta.predicted or base) or base) and observed <= base * 4 then
            learned_duration[meta.key] = math.max(prev or 0, observed)
        end
        return
    end
    -- Reject outliers (missed re-apply, packet loss, early removal).
    if observed < base * 0.5 or observed > base * 3 then
        return
    end
    learned_duration[meta.key] = prev and (prev * 0.5 + observed * 0.5) or observed
end

local function dot_can_apply(state, tid, spell_id)
    local p = dot_priority[tonumber(spell_id or 0) or 0]
    if not p then
        return true
    end
    local dset = state.mob_debuffs[tid]
    local metas = state.mob_debuff_meta and state.mob_debuff_meta[tid] or nil
    if not dset or not metas then
        return true
    end
    local now_u = util.unix_now()
    for _, b in ipairs({134, 135}) do
        local m = metas[b]
        if dset[b] and dset[b] > now_u and m then
            local cur = dot_priority[m.spell_id] or 0
            if cur > p then
                return false
            end
        end
    end
    return true
end

function M.reset_learned_durations()
    learned_duration = {}
end

-- Player ids are below 0x01000000; mob ids are per zone and not worth saving.
local function key_is_player(key)
    return math.floor(key / 4096) < 0x01000000
end

function M.export_learned_durations()
    local out = {}
    for key, secs in pairs(learned_duration) do
        if key_is_player(key) then
            out[key] = math.floor(secs * 10 + 0.5) / 10
        end
    end
    return out
end

function M.import_learned_durations(tbl)
    if type(tbl) ~= 'table' then
        return
    end
    for key, secs in pairs(tbl) do
        local k, v = tonumber(key), tonumber(secs)
        if k and v and v > 0 and key_is_player(k) then
            learned_duration[k] = v
        end
    end
end

local clear_target_buff

local function clear_sleep_family(state, tid)
    if not tid or not state.mob_debuffs or not state.mob_debuffs[tid] then
        return
    end
    state.mob_debuffs[tid][2] = nil
    state.mob_debuffs[tid][19] = nil
    state.mob_debuffs[tid][193] = nil
    if state.mob_debuff_marks and state.mob_debuff_marks[tid] then
        state.mob_debuff_marks[tid][2] = nil
        state.mob_debuff_marks[tid][19] = nil
        state.mob_debuff_marks[tid][193] = nil
    end
    clear_target_buff(state, tid, 2)
    clear_target_buff(state, tid, 19)
    clear_target_buff(state, tid, 193)
end

local function ensure_target_buffs(state, tid)
    if not state.target_buffs then
        state.target_buffs = {}
    end
    if not state.target_buffs[tid] then
        state.target_buffs[tid] = {}
    end
    return state.target_buffs[tid]
end

local function set_target_buff(state, tid, buff_id)
    if not tid or not buff_id or buff_id <= 0 then
        return
    end
    local bset = ensure_target_buffs(state, tid)
    bset[buff_id] = util.unix_now()
end

clear_target_buff = function(state, tid, buff_id)
    if not state.target_buffs or not state.target_buffs[tid] or not buff_id then
        return
    end
    state.target_buffs[tid][buff_id] = nil
end

local function mark_party_touch(state, tid)
    tid = tonumber(tid or 0) or 0
    if tid <= 0 then
        return
    end
    state.mob_party_touch = state.mob_party_touch or {}
    state.mob_party_touch[tid] = util.unix_now()
end

local function has_actions(tbl)
    if type(tbl) ~= 'table' then
        return false
    end
    return next(tbl) ~= nil
end

function M.apply_action(state, act, settings, windower_ref)
    local targets = act and (act.targets or act.Targets)
    if not act or not targets then
        return
    end
    if settings and type(settings.duration) == 'table' then
        state.duration_overrides = settings.duration
    end

    local action_type = tonumber(act.category or act.type or act.Type or 0) or 0
    local spell_id = act.param or act.Param
    local effect = nil
    if action_type == 4 and spell_id then
        effect = spell_effects[spell_id] or nil
        if not effect then
            effect = infer_named_effect(spell_id)
        end
        if not effect then
            local fam = infer_family_buff(spell_id)
            if fam == 134 then
                effect = {buff = 134, duration = 60, clear = 135, on_damage = true}
            elseif fam == 135 then
                effect = {buff = 135, duration = 60, clear = 134, on_damage = true}
            end
        end
    end
    local actor_id = tonumber(act.actor_id or act.actor or act.Actor or act.UserId or act.user_id or 0) or 0
    local all_ids = get_all_ids_cached()
    local myid = util.player_id()
    local actor_is_party = (actor_id > 0 and all_ids and all_ids[actor_id]) or (actor_id > 0 and actor_id == myid) or false

    -- Some monster abilities buff the caster without a per-target status-on.
    local actor_buff = monster_ability_actor_status(spell_id)
    if actor_buff and actor_id > 0 then
        local actor_mob = windower_ref and windower_ref.ffxi and windower_ref.ffxi.get_mob_by_id and windower_ref.ffxi.get_mob_by_id(actor_id) or nil
        if actor_mob and actor_mob.is_npc then
            apply_debuff(state, actor_id, actor_buff, nil, nil, spell_id)
        end
    end

    if actor_is_party and action_type == 4 and spell_id and aoe_cc_spells[spell_id] then
        state.last_cc_by_actor = state.last_cc_by_actor or {}
        state.last_cc_by_actor[actor_id] = {
            spell_id = tonumber(spell_id or 0) or 0,
            at = util.unix_now(),
        }
    end

    local act_fallback_buff = nil
    for _, target in pairs(targets) do
        local tid = target.id or target.Id
        local tactions = target.actions or target.Actions
        local target_mob = tid and windower_ref and windower_ref.ffxi and windower_ref.ffxi.get_mob_by_id and windower_ref.ffxi.get_mob_by_id(tid) or nil
        local target_is_npc = target_mob and target_mob.is_npc or false
        if tid then
            if actor_is_party then
                -- Record engagement even when the packet has no per-target actions.
                mark_party_touch(state, tid)
                -- AoE fallback only when the parser gives no per-target actions.
                if action_type == 4 and spell_id and aoe_cc_spells[spell_id] and (not has_actions(tactions)) then
                    local b = spell_to_buff[spell_id]
                    if b and M.is_negative_player_status(b) and target_is_npc then
                        apply_debuff(state, tid, b, nil, nil, spell_id)
                    end
                end
            end
        end
        if tid and tactions then
            if actor_is_party and target_is_npc then
                mark_party_touch(state, tid)
            end
            for _, action in pairs(tactions) do
                local message = action.message or action.Message
                local ap = tonumber(action.param or action.Param or 0) or 0
                local cc_like_message = (message == 270 and (ap == 2 or ap == 19 or ap == 193))

                if target_is_npc and state.mob_debuffs and state.mob_debuffs[tid] and
                    (state.mob_debuffs[tid][2] or state.mob_debuffs[tid][19] or state.mob_debuffs[tid][193]) and
                    wake_damage_messages[tonumber(message or 0) or 0] and ap > 0 then
                    clear_sleep_family(state, tid)
                end

                if target_is_npc and action and action.has_spike_effect then
                    local spike_id = tonumber(action.spike_effect_param or action.SpikeEffectParam or 0) or 0
                    if is_spike_buff(spike_id) then
                        apply_debuff(state, tid, spike_id, nil, nil, spell_id)
                    end
                end

                if target_is_npc and actor_is_party then
                    local has_add = action.has_add_effect or action['Has Added Effect']
                    local add_msg = tonumber(action.add_effect_message or action['Added Effect Message'] or 0) or 0
                    local add_buff = tonumber(action.add_effect_param or action['Added Effect Param'] or 0) or 0
                    if has_add and status_on_messages:contains(add_msg) and M.is_negative_player_status(add_buff)
                        and M.is_trackable_enemy_status(add_buff) then
                        apply_debuff(state, tid, add_buff, nil, nil, nil, actor_id)
                        mark_party_touch(state, tid)
                    end
                end

                local daze_base = step_daze_messages[tonumber(message or 0) or 0]
                if daze_base and target_is_npc then
                    local lv = math.max(1, math.min(5, ap))
                    for i = 0, 4 do
                        if state.mob_debuffs[tid] then
                            state.mob_debuffs[tid][daze_base + i] = nil
                        end
                    end
                    apply_debuff(state, tid, daze_base + lv - 1, STEP_DAZE_SECS, nil, nil, actor_id)
                    state.mob_debuff_marks[tid][daze_base + lv - 1] = tostring(lv)
                    if actor_is_party then
                        mark_party_touch(state, tid)
                    end
                end

                if death_messages:contains(message) then
                    state.mob_debuffs[tid] = nil
                    if state.mob_debuff_marks then
                        state.mob_debuff_marks[tid] = nil
                    end
                    if state.mob_party_touch then
                        state.mob_party_touch[tid] = nil
                    end
                    if state.mob_debuff_meta then
                        state.mob_debuff_meta[tid] = nil
                    end
                    if state.target_buffs then
                        state.target_buffs[tid] = nil
                    end
                elseif effect and effect.on_damage and spell_damage_messages:contains(message) then
                    if target_is_npc and dot_can_apply(state, tid, spell_id) then
                        apply_debuff(state, tid, effect.buff, effect.duration, effect.clear, spell_id, actor_id)
                    end
                    if actor_is_party and target_is_npc then
                        mark_party_touch(state, tid)
                    end
                elseif status_on_messages:contains(message) or (message == 270 and ((spell_id and aoe_cc_spells[spell_id]) or cc_like_message)) then
                    local buff_id = resolve_buff_id(act, action)
                    local applied_spell_id = spell_id
                    local actor_is_brdish = actor_is_bard(windower_ref, actor_id)
                    if cc_like_message and (not spell_id or spell_id == 0) and (buff_id == 2 or buff_id == 19) then
                        local original_sleep = buff_id
                        -- Retail can omit the BRD spell id on recasts: prefer Lullaby when the caster is likely a BRD.
                        if state.mob_debuffs[tid] and state.mob_debuffs[tid][193] then
                            buff_id = 193
                            applied_spell_id = (original_sleep == 19) and 377 or 376
                        elseif actor_is_brdish then
                            buff_id = 193
                            applied_spell_id = (original_sleep == 19) and 377 or 376
                        else
                            local last_cc = state.last_cc_by_actor and state.last_cc_by_actor[actor_id] or nil
                            local now_u = util.unix_now()
                            if last_cc and (now_u - (tonumber(last_cc.at or 0) or 0)) <= 3 and lullaby_spells[tonumber(last_cc.spell_id or 0) or 0] then
                                buff_id = 193
                                applied_spell_id = tonumber(last_cc.spell_id or 0) or applied_spell_id
                            end
                        end
                    end
                    if not buff_id and cc_like_message then
                        if state.mob_debuffs[tid] and state.mob_debuffs[tid][193] then
                            buff_id = 193
                        else
                            buff_id = ap
                        end
                    end
                    if cc_like_message and (buff_id == 2 or buff_id == 19) and actor_is_brdish then
                        local prev = buff_id
                        buff_id = 193
                        if not applied_spell_id or applied_spell_id == 0 then
                            applied_spell_id = (prev == 19) and 377 or 376
                        end
                    end
                    if (not spell_id or spell_id == 0) and (buff_id == 2 or buff_id == 19) and actor_is_brdish then
                        -- Some Retail packets report Lullaby as plain sleep.
                        local prev = buff_id
                        buff_id = 193
                        if not applied_spell_id or applied_spell_id == 0 then
                            applied_spell_id = (prev == 19) and 377 or 376
                        end
                    end
                    if not buff_id and act_fallback_buff then
                        buff_id = act_fallback_buff
                    end
                    if not buff_id and spell_id and spell_to_buff[spell_id] then
                        buff_id = spell_to_buff[spell_id]
                    end
                    local duration = nil
                    local clear = nil
                    if effect and effect.buff and (not buff_id) then
                        buff_id = effect.buff
                    end
                    if buff_id then
                        duration = resolve_duration(buff_id, applied_spell_id)
                    end
                    if effect and effect.buff and buff_id == effect.buff then
                        duration = effect.duration
                        clear = effect.clear
                    end
                    if buff_id then
                        act_fallback_buff = act_fallback_buff or buff_id
                        local track_on_npc = M.is_trackable_enemy_status(buff_id)
                        if target_is_npc then
                            if track_on_npc then
                                apply_debuff(state, tid, buff_id, duration, clear, applied_spell_id, actor_id)
                                if actor_is_party and M.is_negative_player_status(buff_id) then
                                    mark_party_touch(state, tid)
                                end
                            end
                        elseif M.is_positive_player_status(buff_id) then
                            set_target_buff(state, tid, buff_id)
                        end
                    end
                elseif status_off_messages:contains(message) then
                    -- Status-off: trust only the explicit param (a spell-id fallback falsely clears re-slept targets).
                    local raw = tonumber(action.param or action.Param or 0) or 0
                    local buff_id = nil
                    if raw > 0 and raw <= 1024 and res.buffs[raw] then
                        buff_id = raw
                    end
                    if buff_id and buff_id > 0 then
                        local sleep_family = is_sleep_family_buff(buff_id)
                        if sleep_family then
                            -- Unless this same action is a sleep-family recast.
                            if not spell_is_sleep_family(spell_id) then
                                clear_sleep_family(state, tid)
                            end
                        else
                            clear_target_buff(state, tid, buff_id)
                            if state.mob_debuffs[tid] then
                                state.mob_debuffs[tid][buff_id] = nil
                                if state.mob_debuff_marks and state.mob_debuff_marks[tid] then
                                    state.mob_debuff_marks[tid][buff_id] = nil
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function M.apply_basic_message(state, basic, windower_ref)
    if not basic then
        return
    end

    local target_id = basic.target_id or basic.target
    local actor_id = basic.actor_id or basic.actor
    local message_id = basic.message_id or basic.message
    local p = tonumber(basic.param or 0) or 0
    local p1 = tonumber(basic.param_1 or 0) or 0
    local v = tonumber(basic.value or 0) or 0
    local buff_id = 0
    local sleep_candidate = pick_sleep_family_from_values(p1, p, v)
    if sleep_candidate > 0 then
        buff_id = sleep_candidate
    elseif p1 > 0 then
        buff_id = p1
    elseif p > 0 then
        buff_id = p
    elseif v > 0 then
        buff_id = v
    end
    -- Map CC spell ids to buff ids for status-on only (status-off params may not be buff ids).
    if status_on_messages:contains(message_id) and buff_id > 0 and aoe_cc_spells[buff_id] and spell_to_buff[buff_id] then
        buff_id = spell_to_buff[buff_id]
    end
    if status_on_messages:contains(message_id) and buff_id > 0 and not res.buffs[buff_id] then
        local status_id = monster_ability_status(buff_id)
        if status_id then
            buff_id = status_id
        end
    end
    if not target_id or not message_id then
        return
    end

    if death_messages:contains(message_id) then
        state.mob_debuffs[target_id] = nil
        if state.mob_debuff_marks then
            state.mob_debuff_marks[target_id] = nil
        end
        if state.mob_party_touch then
            state.mob_party_touch[target_id] = nil
        end
        if state.mob_debuff_meta then
            state.mob_debuff_meta[target_id] = nil
        end
        if state.target_buffs then
            state.target_buffs[target_id] = nil
        end
        return
    end

    -- 0x029 status-on is the reliable per-target signal for AoE CC.
    if status_on_messages:contains(message_id) then
        local b = tonumber(buff_id or 0) or 0
        local original_b = b
        local inferred_spell_id = nil
        if b == 2 or b == 19 then
            if state.mob_debuffs and state.mob_debuffs[target_id] and state.mob_debuffs[target_id][193] then
                b = 193
                inferred_spell_id = (original_b == 19) and 377 or 376
            else
                local aid = tonumber(actor_id or 0) or 0
                local last_cc = state.last_cc_by_actor and state.last_cc_by_actor[aid] or nil
                local now_u = util.unix_now()
                if last_cc and (now_u - (tonumber(last_cc.at or 0) or 0)) <= 3 and lullaby_spells[tonumber(last_cc.spell_id or 0) or 0] then
                    b = 193
                    inferred_spell_id = tonumber(last_cc.spell_id or 0) or nil
                elseif actor_is_bard(windower_ref, aid) then
                    b = 193
                    inferred_spell_id = (original_b == 19) and 377 or 376
                end
            end
        end
        if b > 0 then
            local t = windower_ref and windower_ref.ffxi and windower_ref.ffxi.get_mob_by_id and windower_ref.ffxi.get_mob_by_id(target_id) or nil
            if t and t.is_npc then
                local aid = tonumber(actor_id or 0) or 0
                local all_ids = get_all_ids_cached()
                local myid = util.player_id()
                local actor_ok = (aid == 0) or ((aid > 0 and all_ids and all_ids[aid]) or (aid > 0 and aid == myid))
                local track_on_npc = M.is_trackable_enemy_status(b)
                if track_on_npc then
                    local used_spell = inferred_spell_id
                    apply_debuff(state, target_id, b, resolve_duration(b, used_spell), nil, used_spell, actor_ok and aid or nil)
                    if actor_ok and M.is_negative_player_status(b) then
                        mark_party_touch(state, target_id)
                    end
                end
            end
        end
    end

    -- Learn first: the effect may have outlived our timer.
    if natural_wear_messages:contains(message_id) and buff_id and buff_id > 0 then
        learn_duration(state, target_id, buff_id)
    end

    if not state.mob_debuffs[target_id] then
        return
    end

    if message_id == 321 then
        local v = basic.value or buff_id
        if v then
            state.mob_debuffs[target_id][v] = nil
            if state.mob_debuff_marks and state.mob_debuff_marks[target_id] then
                state.mob_debuff_marks[target_id][v] = nil
            end
            clear_target_buff(state, target_id, v)
        end
        return
    end

    if not status_off_messages:contains(message_id) then
        return
    end

    if is_sleep_family_buff(buff_id) then
        clear_sleep_family(state, target_id)
        return
    elseif buff_id and buff_id > 0 then
        state.mob_debuffs[target_id][buff_id] = nil
        if state.mob_debuff_marks and state.mob_debuff_marks[target_id] then
            state.mob_debuff_marks[target_id][buff_id] = nil
        end
        clear_target_buff(state, target_id, buff_id)
    end
end

function M.clear_expired(state)
    local t = util.unix_now()
    if state.mob_debuff_meta then
        for mob_id, metas in pairs(state.mob_debuff_meta) do
            for buff_id, m in pairs(metas) do
                if t > (m.at or 0) + (m.base or 0) * 4 + 5 then
                    metas[buff_id] = nil
                end
            end
            if next(metas) == nil then
                state.mob_debuff_meta[mob_id] = nil
            end
        end
    end
    for mob_id, debuffs in pairs(state.mob_debuffs) do
        local has_any = false
        for buff_id, expires in pairs(debuffs) do
            if expires <= t then
                debuffs[buff_id] = nil
                if state.mob_debuff_marks and state.mob_debuff_marks[mob_id] then
                    state.mob_debuff_marks[mob_id][buff_id] = nil
                end
            else
                has_any = true
            end
        end
        if not has_any then
            state.mob_debuffs[mob_id] = nil
            if state.mob_debuff_marks then
                state.mob_debuff_marks[mob_id] = nil
            end
        end
    end
    -- Party touch is hate evidence with its own lifetime.
    if state.mob_party_touch then
        for mob_id, at in pairs(state.mob_party_touch) do
            if t - (tonumber(at) or 0) > PARTY_TOUCH_KEEP_SECS then
                state.mob_party_touch[mob_id] = nil
            end
        end
    end
end

function M.get_active_names(state, mob_id, max_items)
    local dset = state.mob_debuffs[mob_id]
    if not dset then
        return {'-'}
    end

    local t = util.unix_now()
    local names = {}
    local seen = {}
    for buff_id, expires in pairs(dset) do
        if expires > t then
            local name = M.buff_name(buff_id)
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end

    if #names == 0 then
        return {'-'}
    end

    table.sort(names)
    return util.shorten(names, max_items or 4)
end

function M.get_active_ids(state, mob_id, max_items)
    local dset = state.mob_debuffs[mob_id]
    if not dset then
        return {}
    end

    local t = util.unix_now()
    local ids = {}
    for buff_id, expires in pairs(dset) do
        if expires > t then
            ids[#ids + 1] = buff_id
        end
    end

    table.sort(ids, function(a, b)
        local na = M.buff_name(a)
        local nb = M.buff_name(b)
        if na ~= nb then
            return na < nb
        end
        return a < b
    end)

    if max_items and #ids > max_items then
        local out = {}
        for i = 1, max_items do
            out[i] = ids[i]
        end
        return out
    end

    return ids
end

local function entry_owner(state, mob_id, buff_id)
    local metas = state.mob_debuff_meta and state.mob_debuff_meta[mob_id] or nil
    local m = metas and metas[buff_id] or nil
    local actor = m and tonumber(m.actor or 0) or 0
    if actor <= 0 then
        return nil
    end
    return actor == util.player_id()
end

function M.get_active_entries(state, mob_id, max_items)
    local dset = state.mob_debuffs[mob_id]
    if not dset then
        return {}
    end

    local t = util.unix_now()
    local entries = {}
    for buff_id, expires in pairs(dset) do
        if expires > t then
            entries[#entries + 1] = {
                id = buff_id,
                remaining = math.max(0, expires - t),
                name = M.buff_name(buff_id),
                mark = state.mob_debuff_marks and state.mob_debuff_marks[mob_id] and state.mob_debuff_marks[mob_id][buff_id] or nil,
                -- true = cast by me, false = cast by someone else, nil = unknown caster
                mine = entry_owner(state, mob_id, buff_id),
            }
        end
    end
    return entries
end

function M.get_known_target_buffs(state, mob_id, max_items)
    if not state.target_buffs then
        return {}
    end
    local bset = state.target_buffs[mob_id]
    if not bset then
        return {}
    end

    local out = {}
    for buff_id, seen_at in pairs(bset) do
        if M.is_positive_player_status(buff_id) then
            out[#out + 1] = {
                id = buff_id,
                name = M.buff_name(buff_id),
                seen_at = tonumber(seen_at) or 0,
            }
        end
    end

    table.sort(out, function(a, b)
        if a.seen_at ~= b.seen_at then
            return a.seen_at > b.seen_at
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

return M
