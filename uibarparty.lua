local M = {}
local cache_ttl = 0.20
local cache = {
    at = 0,
    party_ids = {},
    ally_ids = {},
    all_ids = {},
    member_ids = {},
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
            end
        end
    end

    cache.at = now_u
    cache.party_ids = party_ids
    cache.ally_ids = ally_ids
    cache.all_ids = all_ids
    cache.member_ids = member_ids
end

function M.get_party_member_ids()
    rebuild_cache()
    return cache.member_ids
end

function M.get_claim_sets()
    rebuild_cache()
    return cache.party_ids, cache.ally_ids, cache.all_ids
end

return M
