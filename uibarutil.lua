local M = {}

-- On Windows os.clock() is wall time with sub-second resolution (os.time() has whole seconds).
function M.frame_now()
    return os.clock()
end

-- High-resolution clock for timers and caches (old name kept for callers).
function M.unix_now()
    return os.clock()
end

local player_id = 0

-- get_player() builds a large table (buffs, skills, jobs); avoid it in hot paths.
function M.player_id()
    if player_id <= 0 then
        local me = windower.ffxi.get_player()
        player_id = tonumber(me and me.id or 0) or 0
    end
    return player_id
end

function M.invalidate_player()
    player_id = 0
end

function M.to_bar(value, max_value, width)
    if max_value <= 0 then
        max_value = 1
    end
    local pct = math.max(0, math.min(1, value / max_value))
    local filled = math.floor(pct * width + 0.5)
    return '[' .. string.rep('#', filled) .. string.rep('-', width - filled) .. ']'
end

function M.shorten(list, max_items)
    if #list <= max_items then
        return list
    end
    local out = {}
    for i = 1, max_items do
        out[i] = list[i]
    end
    out[#out + 1] = '+' .. tostring(#list - max_items)
    return out
end

function M.sanitize_name(name)
    if not name or name == '' then
        return 'Unknown'
    end
    return name:gsub('%s+', ' ')
end

return M
