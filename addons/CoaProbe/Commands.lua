-- CoaProbe commands. Each handler takes the WoW API table (_G in the client) and the argument words, and
-- returns a result table, or nil and an error message.
CoaProbe = CoaProbe or {}
local Commands = {}
CoaProbe.Commands = Commands
Commands.handlers = {}

local MAX_AURAS = 40
local MAX_SPELLBOOK = 1024

local function tooltipLines(api, link)
    local tip = api.GameTooltip
    tip:SetOwner(api.UIParent, "ANCHOR_NONE")
    tip:SetHyperlink(link)
    local lines = {}
    for i = 1, tip:NumLines() do
        local left = api["GameTooltipTextLeft" .. i]
        local right = api["GameTooltipTextRight" .. i]
        lines[i] = {
            left = left and left:GetText() or "",
            right = right and right:GetText() or "",
        }
    end
    tip:Hide()
    return lines
end

local function numberArg(args, usage)
    local id = tonumber(args[1])
    if not id then
        return nil, usage
    end
    return id
end

Commands.handlers.ping = function()
    return { pong = true }
end

Commands.handlers.spell = function(api, args)
    local id, err = numberArg(args, "usage: spell <id>")
    if not id then
        return nil, err
    end
    local name, rank, icon, cost, _, powerType, castTime, minRange, maxRange = api.GetSpellInfo(id)
    if not name then
        return nil, "unknown spell " .. id
    end
    return {
        id = id, name = name, rank = rank, icon = icon, cost = cost, powerType = powerType,
        castTime = castTime, minRange = minRange, maxRange = maxRange,
        known = api.IsSpellKnown(id) and true or false,
        tooltip = tooltipLines(api, "spell:" .. id),
    }
end

Commands.handlers.item = function(api, args)
    local id, err = numberArg(args, "usage: item <id>")
    if not id then
        return nil, err
    end
    return { id = id, tooltip = tooltipLines(api, "item:" .. id) }
end

Commands.handlers.auras = function(api, args)
    local unit = args[1] or "player"
    local auras = {}
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for i = 1, MAX_AURAS do
            local name, _, _, count, _, duration, expirationTime, caster, _, _, spellId = api.UnitAura(unit, i, filter)
            if not name then
                break
            end
            auras[#auras + 1] = {
                name = name, spellId = spellId, count = count, duration = duration,
                expirationTime = expirationTime, caster = caster, harmful = filter == "HARMFUL",
            }
        end
    end
    return { unit = unit, auras = auras }
end

Commands.handlers.spellbook = function(api)
    local spells = {}
    for index = 1, MAX_SPELLBOOK do
        local name, rank = api.GetSpellName(index, "spell")
        if not name then
            break
        end
        local link = api.GetSpellLink(index, "spell")
        spells[#spells + 1] = { name = name, rank = rank, id = link and tonumber(link:match("spell:(%d+)")) }
    end
    return { spells = spells }
end

Commands.handlers.known = function(api, args)
    local id, err = numberArg(args, "usage: known <id>")
    if not id then
        return nil, err
    end
    return { id = id, known = api.IsSpellKnown(id) and true or false }
end

function Commands.run(api, line)
    local words = {}
    for word in line:gmatch("%S+") do
        words[#words + 1] = word
    end
    local req, command = words[1], words[2]
    local answer = { req = req or "", command = command or "", time = api.time() }
    if not req or not command then
        answer.error = "usage: /coaprobe <req> <command> [args]"
        return answer
    end
    local handler = Commands.handlers[command]
    if not handler then
        answer.error = "unknown command " .. command
        return answer
    end
    local args = {}
    for i = 3, #words do
        args[#args + 1] = words[i]
    end
    local ok, result, err = pcall(handler, api, args)
    if not ok then
        answer.error = tostring(result)
    elseif result == nil then
        answer.error = err or "no result"
    else
        answer.result = result
    end
    return answer
end
