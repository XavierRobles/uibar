local M = {}
local bit = require('bit')

local party_buffs = {}
local name_to_id = {}

local function u32le(data, pos)
    local b1 = data:byte(pos) or 0
    local b2 = data:byte(pos + 1) or 0
    local b3 = data:byte(pos + 2) or 0
    local b4 = data:byte(pos + 3) or 0
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function read_party_buffs_076(data)
    local next_table = {}
    for slot = 0, 4 do
        local base = 5 + slot * 48
        local member_id = u32le(data, base)
        if member_id and member_id > 0 then
            local set = {}
            local done = false
            for i = 1, 32 do
                if done then
                    break
                end
                local raw = data:byte(base + 16 + (i - 1)) or 0
                if raw == 255 then
                    done = true
                else
                    local hb = data:byte(base + 8 + math.floor((i - 1) / 4)) or 0
                    local add2 = bit.band(bit.rshift(hb, 2 * ((i - 1) % 4)), 0x03)
                    local buff = raw + add2 * 256
                    if buff > 0 then
                        set[buff] = true
                    end
                end
            end
            next_table[member_id] = set
        end
    end
    party_buffs = next_table
end

function M.clear()
    party_buffs = {}
    name_to_id = {}
end

function M.handlechunk(id, data, packets)
    if not data then
        return
    end

    if id == 0x076 then
        read_party_buffs_076(data)
        return
    end

    if id == 0x0DD then
        local p = packets and packets.parse and packets.parse('incoming', data)
        local name = p and p.Name
        local mid = p and (p.ID or p.Id)
        mid = tonumber(mid or 0) or 0
        if type(name) == 'string' and mid > 0 then
            name_to_id[name] = mid
        end
    end
end

local function merge_set(dst, src)
    if type(src) ~= 'table' then
        return
    end
    for k, v in pairs(src) do
        local id = 0
        local vv = tonumber(v)
        if vv and vv > 0 then
            -- Array/list format: {33, 40, ...}
            id = vv
        else
            -- Set/map format: {[33]=true, ...}
            local vk = v
            if vk == true or vk == 1 or vk == '1' then
                id = tonumber(k) or 0
            end
        end
        if id > 0 and id ~= 255 then
            dst[id] = true
        end
    end
end

function M.collecttargetbuffids(target)
    local out = {}
    if not target then
        return out
    end

    local me = windower.ffxi.get_player()
    local tid = tonumber(target.id or 0) or 0
    local myid = tonumber(me and me.id or 0) or 0
    if me and tid > 0 and tid == myid then
        merge_set(out, me.buffs)
        return out
    end

    local party = windower.ffxi.get_party() or {}
    local function try_member(member)
        if type(member) ~= 'table' then
            return false
        end
        local mid = nil
        if member.mob and type(member.mob) == 'table' then
            mid = tonumber(member.mob.id)
        elseif member.mob_id then
            mid = tonumber(member.mob_id)
        elseif member.id then
            mid = tonumber(member.id)
        end
        if not mid and type(member.name) == 'string' then
            mid = name_to_id[member.name]
        end

        if mid and tid > 0 and mid == tid then
            merge_set(out, party_buffs[mid])
            merge_set(out, member.buffs)
            if member.mob and type(member.mob) == 'table' then
                merge_set(out, member.mob.buffs)
            end
            return true
        end
        return false
    end

    for i = 0, 5 do
        if try_member(party['p' .. i]) then
            return out
        end
    end
    for i = 10, 18 do
        if try_member(party['a' .. i]) then
            return out
        end
    end
    for i = 10, 18 do
        if try_member(party['b' .. i]) then
            return out
        end
    end

    if type(target.name) == 'string' then
        for _, member in pairs(party) do
            if type(member) == 'table' and member.name == target.name then
                local mid = member.mob and member.mob.id or member.id or name_to_id[member.name]
                mid = tonumber(mid or 0) or 0
                if mid > 0 then
                    merge_set(out, party_buffs[mid])
                end
                merge_set(out, member.buffs)
                if member.mob and type(member.mob) == 'table' then
                    merge_set(out, member.mob.buffs)
                end
                break
            end
        end
    end

    merge_set(out, target.buffs)
    return out
end

return M
