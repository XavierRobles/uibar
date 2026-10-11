local M = {}

local last_targets = {}
local combat_categories = {
    [1] = true,   -- melee/ranged hit
    [2] = true,   -- ranged start/related
    [3] = true,   -- ws/ranged finish (variant by packet parser)
    [4] = true,   -- spell finish
    [6] = true,   -- job ability/pet/monster variants
    [7] = true,   -- ws/ability start
    [8] = true,   -- magic/ability variant
    [10] = true,  -- finisher variant
    [11] = true,  -- mob skill finish
    [13] = true,  -- readies/starts (parser dependent)
    [14] = true,  -- readies/starts (parser dependent)
}
local expiry_secs = 30
local cleanup_counter = 0
local entity_type_cache = {}
local index_cache = {}
local entity_cache_ttl = 5
local index_cache_ttl = 1

local function now()
    return os.time()
end

local function to_n(v)
    return tonumber(v or 0) or 0
end

local function cleanup_stale()
    local t = now()
    for sid, data in pairs(last_targets) do
        if type(data) ~= 'table' or (to_n(data.timestamp) + expiry_secs) < t then
            last_targets[sid] = nil
        end
    end
end

local function get_mob_by_id(id)
    if id <= 0 then
        return nil
    end
    return windower and windower.ffxi and windower.ffxi.get_mob_by_id and windower.ffxi.get_mob_by_id(id) or nil
end

local function get_index_from_id(id)
    local t = now()
    local c = index_cache[id]
    if type(c) == 'table' and to_n(c.expires) >= t then
        return to_n(c.index)
    end
    local m = get_mob_by_id(id)
    local idx = to_n(m and m.index)
    index_cache[id] = {
        index = idx,
        expires = t + index_cache_ttl,
    }
    return idx
end

local function is_non_player_entity(id)
    local t = now()
    local c = entity_type_cache[id]
    if type(c) == 'table' and to_n(c.expires) >= t then
        return c.value == true
    end
    local m = get_mob_by_id(id)
    if not m then
        entity_type_cache[id] = {value = false, expires = t + 1}
        return false
    end
    local is_non_player = (m.is_npc == true) or ((to_n(m.spawn_type) == 16) and (m.is_mob ~= false))
    entity_type_cache[id] = {value = is_non_player, expires = t + entity_cache_ttl}
    return is_non_player
end

function M.clear()
    last_targets = {}
    entity_type_cache = {}
    index_cache = {}
end

function M.handle_action(act)
    if type(act) ~= 'table' then
        return
    end

    local category = to_n(act.category or act.type)
    if not combat_categories[category] then
        return
    end

    local actor_id = to_n(act.actor_id or act.user_id or act.UserId)
    if actor_id <= 0 then
        return
    end

    -- Mobs/NPCs only.
    if not is_non_player_entity(actor_id) then
        return
    end

    local targets = act.targets
    if type(targets) ~= 'table' or #targets == 0 then
        return
    end

    local first = targets[1]
    local target_id = to_n(first and (first.id or first.Id))
    if target_id <= 0 then
        return
    end

    local target_index = get_index_from_id(target_id)
    last_targets[actor_id] = {
        target_id = target_id,
        target_index = target_index,
        timestamp = now(),
    }

    -- Cheap periodic cleanup.
    cleanup_counter = cleanup_counter + 1
    if cleanup_counter >= 100 then
        cleanup_counter = 0
        cleanup_stale()
    end
end

local function extract_first_target_id_from_parsed(p)
    if type(p) ~= 'table' then
        return 0
    end
    local ts = p.Targets or p.targets
    if type(ts) == 'table' then
        local first = ts[1]
        local tid = to_n(first and (first.id or first.Id or first.target_id or first.Target))
        if tid > 0 then
            return tid
        end
    end
    -- Some parsers expose single-target fields.
    return to_n(p.Target or p.target or p['Target ID'] or p.target_id)
end

function M.handle_chunk(id, data, packets, parsed_action)
    if id ~= 0x028 then
        return
    end

    local p = parsed_action
    if type(p) ~= 'table' and data then
        p = packets and packets.parse and packets.parse('incoming', data) or nil
    end
    if type(p) ~= 'table' then
        return
    end

    local category = to_n(p.category or p.Category or p.type or p.Type)
    if category > 0 and not combat_categories[category] then
        return
    end

    local actor_id = to_n(p.actor_id or p.Actor or p.actor or p.UserId or p.user_id or p.ActorId)
    if actor_id <= 0 then
        return
    end
    if not is_non_player_entity(actor_id) then
        return
    end

    local tid = extract_first_target_id_from_parsed(p)
    if tid <= 0 or tid == actor_id then
        return
    end

    local tix = get_index_from_id(tid)
    last_targets[actor_id] = {
        target_id = tid,
        target_index = tix,
        timestamp = now(),
    }
end

function M.get_last_target_index(actor_id)
    local sid = to_n(actor_id)
    if sid <= 0 then
        return nil
    end

    local data = last_targets[sid]
    if type(data) ~= 'table' then
        return nil
    end

    if (to_n(data.timestamp) + expiry_secs) < now() then
        last_targets[sid] = nil
        return nil
    end

    local idx = to_n(data.target_index)
    if idx > 0 then
        return idx
    end

    local tid = to_n(data.target_id)
    if tid > 0 then
        idx = get_index_from_id(tid)
        if idx > 0 then
            data.target_index = idx
            return idx
        end
    end
    return nil
end

return M
