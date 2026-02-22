local M = {}

local function add_id(set, id)
    if type(id) ~= 'number' or id <= 0 then
        return
    end
    set[id] = true
end

function M.get_party_member_ids()
    local ids = {}
    local party = windower.ffxi.get_party()
    if not party then
        return ids
    end

    for _, member in pairs(party) do
        if type(member) == 'table' then
            local id = nil
            if member.mob and type(member.mob) == 'table' then
                id = member.mob.id
            elseif member.mob_id then
                id = member.mob_id
            elseif member.id then
                id = member.id
            end

            add_id(ids, id)
        end
    end

    return ids
end

function M.get_claim_sets()
    local party_ids = {}
    local ally_ids = {}
    local all_ids = {}
    local party = windower.ffxi.get_party()
    if not party then
        return party_ids, ally_ids, all_ids
    end

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

    return party_ids, ally_ids, all_ids
end

return M
