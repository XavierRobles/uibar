local M = {}

local current_zone = 0
local zone_data = {Names = {}, Indices = {}}
local job_abbr = {
    [1] = 'WAR', [2] = 'MNK', [3] = 'WHM', [4] = 'BLM', [5] = 'RDM', [6] = 'THF',
    [7] = 'PLD', [8] = 'DRK', [9] = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU', [17] = 'COR', [18] = 'PUP',
    [19] = 'DNC', [20] = 'SCH', [21] = 'GEO', [22] = 'RUN'
}

local function reset()
    zone_data.Names = {}
    zone_data.Indices = {}
end

local function data_path(zone_id)
    return (windower.addon_path or '') .. 'data/mobdb/' .. tostring(zone_id) .. '.lua'
end

function M.load_zone(zone_id)
    zone_id = tonumber(zone_id) or 0
    if zone_id == current_zone then
        return
    end

    current_zone = zone_id
    reset()
    if zone_id == 0 then
        return
    end

    local path = data_path(zone_id)
    local f = io.open(path, 'rb')
    if not f then
        return
    end
    f:close()

    local chunk = loadfile(path)
    if not chunk then
        return
    end

    local ok, result = pcall(chunk)
    if not ok or type(result) ~= 'table' then
        return
    end

    zone_data.Names = type(result.Names) == 'table' and result.Names or {}
    zone_data.Indices = type(result.Indices) == 'table' and result.Indices or {}
end

function M.on_zone_change()
    local info = windower.ffxi.get_info()
    M.load_zone(info and info.zone or 0)
end

function M.get_mob_info(mob)
    if not mob then
        return nil
    end

    local z = zone_data.Indices[mob.index]
    if z then
        return z
    end

    return zone_data.Names[mob.name]
end

function M.level_string(info)
    if not info then
        return '?'
    end
    local min_level = info.MinLevel or info.Level
    local max_level = info.MaxLevel or info.Level
    if not min_level and not max_level then
        return '?'
    end
    if not max_level or min_level == max_level then
        return tostring(min_level or max_level)
    end
    return tostring(min_level) .. '-' .. tostring(max_level)
end

function M.job_string(info)
    if not info then
        return nil
    end
    local j = tonumber(info.Job or 0) or 0
    if j <= 0 then
        return nil
    end
    return job_abbr[j] or tostring(j)
end

function M.detection_icons(info)
    if not info then
        return ''
    end

    local out = {}
    if info.Aggro then out[#out + 1] = '[A]' end
    if info.Sight then out[#out + 1] = '[Eye]' end
    if info.TrueSight then out[#out + 1] = '[TEye]' end
    if info.Sound then out[#out + 1] = '[Ear]' end
    if info.Scent then out[#out + 1] = '[Scent]' end
    if info.Magic then out[#out + 1] = '[Magic]' end
    if info.JA then out[#out + 1] = '[JA]' end
    if info.Blood then out[#out + 1] = '[Blood]' end
    return table.concat(out, '')
end

function M.detection_entries(info)
    if not info then
        return {}
    end

    local out = {}
    local hq = info.Notorious and true or false
    if info.Aggro then
        out[#out + 1] = {file = hq and 'AggroHQ' or 'AggroNQ', title = 'Aggro', tooltip = hq and 'Aggressive (NM)' or 'Aggressive'}
    else
        out[#out + 1] = {file = hq and 'PassiveHQ' or 'PassiveNQ', title = 'Passive', tooltip = hq and 'Passive (NM)' or 'Passive'}
    end
    if info.Link then out[#out + 1] = {file = 'Link', title = 'Link', tooltip = 'Links with nearby mobs'} end
    if info.Sight then out[#out + 1] = {file = 'Sight', title = 'Sight', tooltip = 'Detects by sight'} end
    if info.TrueSight then out[#out + 1] = {file = 'TrueSight', title = 'True Sight', tooltip = 'Detects through invisible'} end
    if info.Sound then out[#out + 1] = {file = 'Sound', title = 'Sound', tooltip = 'Detects by sound'} end
    if info.Scent then out[#out + 1] = {file = 'Scent', title = 'Scent', tooltip = 'Detects by scent'} end
    if info.Magic then out[#out + 1] = {file = 'Magic', title = 'Magic', tooltip = 'Detects magic casting'} end
    if info.JA then out[#out + 1] = {file = 'JA', title = 'Job Ability', tooltip = 'Detects job abilities'} end
    if info.Blood then out[#out + 1] = {file = 'Blood', title = 'Blood', tooltip = 'Detects blood'} end
    return out
end

return M
