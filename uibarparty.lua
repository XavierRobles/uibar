local M = {}
local cache_ttl = 0.20
local cache = {
    at = 0,
    party_ids = {},
    ally_ids = {},
    all_ids = {},
    member_ids = {},
    pet_ids = {},
    by_index = {},
}

local function add_id(set, id)
    if type(id) ~= 'number' or id <= 0 then
        return
    end
    set[id] = true
end

function M.invalidate_cache()
    cache.at = 0
    cache.party_ids = {}
    cache.ally_ids = {}
    cache.all_ids = {}
    cache.member_ids = {}
    cache.pet_ids = {}
    cache.by_index = {}
end

local function rebuild_cache()
    local now_u = os.clock()
    if (now_u - (tonumber(cache.at or 0) or 0)) <= cache_ttl then
        return
    end

    local party_ids = {}
    local ally_ids = {}
    local all_ids = {}
    local member_ids = {}
    local pet_ids = {}
    local by_index = {}

    local party = windower.ffxi.get_party()
    if type(party) == 'table' then
        for key, member in pairs(party) do
            if type(member) == 'table' then
                local id = nil
                if member.mob and type(member.mob) == 'table' then
                    id = member.mob.id
                elseif member.mob_id then
                    id = member.mob_id
                elseif member.id then
                    id = member.id
                end

                if type(id) == 'number' and id > 0 then
                    add_id(member_ids, id)
                    add_id(all_ids, id)
                    if type(key) == 'string' and string.match(key, '^p%d$') then
                        add_id(party_ids, id)
                    elseif type(key) == 'string' and string.match(key, '^a%d+$') then
                        add_id(ally_ids, id)
                    else
                        add_id(party_ids, id)
                    end
                end

                local mob = type(member.mob) == 'table' and member.mob or nil
                local idx = tonumber(mob and mob.index or member.index or 0) or 0
                if idx > 0 and type(id) == 'number' and id > 0 then
                    by_index[idx] = {id = id, index = idx, name = member.name, is_npc = false}
                end

                -- Pets take hate for their master's party.
                local pet_idx = tonumber(mob and mob.pet_index or 0) or 0
                if pet_idx > 0 then
                    local pet = windower.ffxi.get_mob_by_index(pet_idx)
                    local pid = tonumber(pet and pet.id or 0) or 0
                    if pid > 0 then
                        pet_ids[pid] = true
                        by_index[pet_idx] = {id = pid, index = pet_idx, name = pet.name, is_npc = true, is_pet = true}
                    end
                end
            end
        end
    end

    cache.at = now_u
    cache.party_ids = party_ids
    cache.ally_ids = ally_ids
    cache.all_ids = all_ids
    cache.member_ids = member_ids
    cache.pet_ids = pet_ids
    cache.by_index = by_index
end

function M.get_party_member_ids()
    rebuild_cache()
    return cache.member_ids
end

function M.get_claim_sets()
    rebuild_cache()
    return cache.party_ids, cache.ally_ids, cache.all_ids
end

-- Members and pets: anything a mob can hold hate on for us.
function M.is_member_or_pet(id)
    rebuild_cache()
    id = tonumber(id or 0) or 0
    return id > 0 and (cache.all_ids[id] == true or cache.pet_ids[id] == true)
end

function M.get_pet_ids()
    rebuild_cache()
    return cache.pet_ids
end

-- index -> {id, index, name, is_npc, is_pet} for members and pets.
function M.get_member_index_map()
    rebuild_cache()
    return cache.by_index
end

return M
