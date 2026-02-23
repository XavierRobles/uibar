local bit = require('bit')

local M = {}

local function unpack_bits_be(data, bit_offset, length)
    local value = 0
    for i = 0, length - 1 do
        local pos = bit_offset + i
        local byte_index = math.floor(pos / 8) + 1
        local bit_in_byte = pos % 8
        local b = data:byte(byte_index) or 0
        local bit_val = bit.band(bit.rshift(b, 7 - bit_in_byte), 0x01)
        value = value * 2 + bit_val
    end
    return value
end

function M.parse_action_packet(data)
    if type(data) ~= 'string' then
        return nil
    end

    local bit_offset = 40
    local max_length = #data * 8

    local function read_bits(length)
        if (bit_offset + length) > max_length then
            return nil
        end
        local v = unpack_bits_be(data, bit_offset, length)
        bit_offset = bit_offset + length
        return v
    end

    local action_packet = {}
    action_packet.UserId = read_bits(32)
    if not action_packet.UserId then
        return nil
    end
    action_packet.Actor = action_packet.UserId

    local target_count = read_bits(6)
    if not target_count then
        return nil
    end

    bit_offset = bit_offset + 4 -- unknown bits
    if bit_offset > max_length then
        return nil
    end

    action_packet.Type = read_bits(4)
    if not action_packet.Type then
        return nil
    end

    if action_packet.Type == 8 or action_packet.Type == 9 then
        action_packet.Param = read_bits(16) or 0
        action_packet.SpellGroup = read_bits(16) or 0
    else
        action_packet.Param = read_bits(32) or 0
    end
    action_packet.Recast = read_bits(32) or 0

    action_packet.Targets = {}
    action_packet.targets = action_packet.Targets

    for _ = 1, target_count do
        local target_id = read_bits(32)
        local action_count = read_bits(4)
        if (not target_id) or (not action_count) then
            break
        end

        local target = {Id = target_id, id = target_id, Actions = {}, actions = {}}
        if action_count == 0 then
            break
        end

        for _ = 1, action_count do
            local reaction = read_bits(5)
            local animation = read_bits(12)
            local special_effect = read_bits(7)
            local knockback = read_bits(3)
            local param = read_bits(17)
            local message = read_bits(10)
            local flags = read_bits(31)
            if (not reaction) or (not animation) or (not special_effect) or (not knockback) or (not param) or (not message) or (not flags) then
                return nil
            end

            local action = {
                Reaction = reaction,
                Animation = animation,
                SpecialEffect = special_effect,
                Knockback = knockback,
                Param = param,
                param = param,
                Message = message,
                message = message,
                Flags = flags,
            }

            local has_additional = read_bits(1)
            if has_additional == nil then
                return nil
            end
            if has_additional == 1 then
                local add_damage = read_bits(10)
                local add_param = read_bits(17)
                local add_message = read_bits(10)
                if (not add_damage) or (not add_param) or (not add_message) then
                    return nil
                end
                action.AdditionalEffect = {
                    Damage = add_damage,
                    Param = add_param,
                    Message = add_message,
                }
            end

            local has_spikes = read_bits(1)
            if has_spikes == nil then
                return nil
            end
            if has_spikes == 1 then
                local spikes_damage = read_bits(10)
                local spikes_param = read_bits(14)
                local spikes_message = read_bits(10)
                if (not spikes_damage) or (not spikes_param) or (not spikes_message) then
                    return nil
                end
                action.SpikesEffect = {
                    Damage = spikes_damage,
                    Param = spikes_param,
                    Message = spikes_message,
                }
            end

            table.insert(target.Actions, action)
            table.insert(target.actions, action)
        end

        table.insert(action_packet.Targets, target)
    end

    if #action_packet.Targets > 0 then
        return action_packet
    end
    return nil
end

return M
