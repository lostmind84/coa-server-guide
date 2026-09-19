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

-- log [n]: the last n captured events (default 25), oldest first. The agent reads this after an action to learn
-- why it failed, because the message only ever appeared on screen.
Commands.handlers.log = function(api, args)
    local count = tonumber(args[1]) or 25
    local log = api.CoaProbeLog or {}
    local from = #log - count + 1
    if from < 1 then
        from = 1
    end
    local entries = {}
    for i = from, #log do
        entries[#entries + 1] = log[i]
    end
    return { total = #log, entries = entries }
end

-- state: one snapshot of the player and the current target. A probe writes its answer through /reload, which clears
-- the target selection, so asking for the target in a second probe would always find nothing.
Commands.handlers.state = function(api, args)
    local function unit(token)
        if not api.UnitExists(token) then
            return { exists = false }
        end
        return {
            exists = true,
            name = api.UnitName(token),
            level = api.UnitLevel(token),
            health = api.UnitHealth(token),
            maxHealth = api.UnitHealthMax(token),
            dead = api.UnitIsDeadOrGhost(token) and true or false,
            powerType = api.UnitPowerType(token),
            -- The displayed bar is not always the resource the server charges: CoA classes can spend rage while
            -- the client shows mana, so report every power index the spell costs could come from.
            powers = {
                mana = api.UnitPower(token, 0),
                rage = api.UnitPower(token, 1),
                focus = api.UnitPower(token, 2),
                energy = api.UnitPower(token, 3),
                runicPower = api.UnitPower(token, 6),
            },
            auras = Commands.handlers.auras(api, { token }).auras,
        }
    end
    return { player = unit("player"), target = unit("target") }
end

Commands.handlers.known = function(api, args)
    local id, err = numberArg(args, "usage: known <id>")
    if not id then
        return nil, err
    end
    return { id = id, known = api.IsSpellKnown(id) and true or false }
end

-- Character Advancement, the client's own talent service. `ca` answers from
-- C_CharacterAdvancement, which is what the server's 0x0725/0x0726 packets feed.
--
-- The answer always carries `shim`: the CoA client patch ships
-- Ascension_Collections/CharacterAdvancementCompat.lua, which overrides this API and sets
-- ASCENSION_LOCAL_CHARACTER_ADVANCEMENT_COMPAT. While that is true the answers come from
-- the patch's Lua reconstruction, not from what the realm sent, so a protocol experiment
-- needs a client running the stock patch-B.MPQ.
local function callService(service, name, ...)
    local fn = service[name]
    if type(fn) ~= "function" then
        return nil, "absent"
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil, "error"
    end
    return value, nil
end

local function record(answer, key, service, name, ...)
    local value, problem = callService(service, name, ...)
    if problem then
        answer.unavailable = answer.unavailable or {}
        answer.unavailable[name] = problem
    elseif type(value) == "boolean" then
        answer[key] = value
    elseif value ~= nil then
        answer[key] = value
    end
end

Commands.handlers.ca = function(api, args)
    local service = api.C_CharacterAdvancement
    if type(service) ~= "table" then
        return nil, "C_CharacterAdvancement is not available on this client"
    end

    local answer = {
        shim = api.ASCENSION_LOCAL_CHARACTER_ADVANCEMENT_COMPAT and true or false,
    }
    record(answer, "activeSpec", service, "GetActiveChrSpec")
    record(answer, "learnedAE", service, "GetLearnedAE")
    record(answer, "learnedTE", service, "GetLearnedTE")
    record(answer, "classPointInvestment", service, "GetClassPointInvestment")

    if args[1] then
        local id = tonumber(args[1])
        if not id then
            return nil, "usage: ca [entryId]"
        end
        answer.id = id
        -- IsKnownID and GetTalentRankByID are the two the known-entries packet drives.
        record(answer, "known", service, "IsKnownID", id)
        record(answer, "rank", service, "GetTalentRankByID", id)
        record(answer, "locked", service, "IsLockedID", id)
        record(answer, "isTalent", service, "IsTalentID", id)
        record(answer, "knownSpell", service, "IsKnownSpellID", id)
        record(answer, "pendingRank", service, "GetPendingRankByEntryID", id)
    end

    return answer
end

-- The binary's own packet API, exposed to Lua as globals: CreatePacket(opcode) returns a CDataStore
-- userdata with the opcode written, its metatable carries PutUInt8/16/32, PutInt8/16/32, PutFloat, PutBool,
-- PutString and the matching Get* plus GetGUID, Send(packet) sends it, RegisterPacket(opcode, fn) has fn(opcode,
-- packet) called for every packet with that opcode. Located by coa-protocol-atlas (client/client-senders.md,
-- "The Lua packet API"); whether an addon may use them is what these commands establish.
local PUT = {
    u8 = "PutUInt8", u16 = "PutUInt16", u32 = "PutUInt32",
    i8 = "PutInt8", i16 = "PutInt16", i32 = "PutInt32",
    f = "PutFloat", b = "PutBool", s = "PutString",
}
-- GetUInt8 has no bounds check: past the payload it returns whatever memory follows, without failing. A watch
-- therefore reads a fixed number of bytes -- the layout's size when known, a window otherwise -- and the
-- record says how many were asked for, not how long the packet was.
local DEFAULT_PACKET_BYTES = 64
local MAX_PACKET_BYTES = 4096

-- Where the three functions live is the client's business: RegisterPacket is a global (SharedXML/Util/
-- OpcodeUtil.lua calls it bare), CreatePacket and Send were not found there on the first lab run, so the
-- lookup also walks every global table one level deep and takes the first that carries the name.
local packetApiCache
function Commands.packetApi(api)
    if packetApiCache and packetApiCache.source == api then
        return packetApiCache
    end
    local found = { source = api, where = {} }
    for _, name in ipairs({ "CreatePacket", "Send", "RegisterPacket", "ClearPacket" }) do
        if type(api[name]) == "function" then
            found[name], found.where[name] = api[name], "_G"
        end
    end
    for key, value in pairs(api) do
        if type(value) == "table" and type(key) == "string" and key ~= "_G" then
            for _, name in ipairs({ "CreatePacket", "Send", "RegisterPacket", "ClearPacket" }) do
                local ok, fn = pcall(rawget, value, name)
                if not found[name] and ok and type(fn) == "function" then
                    found[name], found.where[name] = fn, key
                end
            end
        end
    end
    packetApiCache = found
    return found
end

-- pkfind: where CreatePacket/Send/RegisterPacket/ClearPacket were found, if anywhere.
Commands.handlers.pkfind = function(api)
    packetApiCache = nil
    local found = Commands.packetApi(api)
    return { where = found.where }
end

-- pksend <opcode> [u8:N u16:N u32:N i8:N i16:N i32:N f:X b:0|1 s:TEXT ...]: build and send a packet.
Commands.handlers.pksend = function(api, args)
    local usage = "usage: pksend <opcode> [u8:N u16:N u32:N i8:N i16:N i32:N f:X b:0|1 s:TEXT ...]"
    local opcode, err = numberArg(args, usage)
    if not opcode then
        return nil, err
    end
    local packetApi = Commands.packetApi(api)
    if type(packetApi.CreatePacket) ~= "function" or type(packetApi.Send) ~= "function" then
        return nil, "CreatePacket/Send are not available on this client"
    end
    local packet = packetApi.CreatePacket(opcode)
    if packet == nil then
        return nil, "CreatePacket returned nothing"
    end
    local fields = {}
    for i = 2, #args do
        local kind, text = args[i]:match("^(%a+%d*):(.*)$")
        local method = kind and PUT[kind]
        if not method then
            return nil, "bad field " .. args[i] .. "; " .. usage
        end
        local value = text
        if kind == "b" then
            value = text == "1" or text == "true"
        elseif kind ~= "s" then
            value = tonumber(text)
            if value == nil then
                return nil, "bad number in " .. args[i]
            end
        end
        local fn = packet[method]
        if type(fn) ~= "function" then
            return nil, method .. " is not available on this packet"
        end
        fn(packet, value)
        fields[#fields + 1] = { kind = kind, value = value }
    end
    packetApi.Send(packet)
    return { opcode = opcode, fields = fields, sent = true }
end

-- The bytes of a received packet, read one at a time until the store refuses. Recorded into the event log
-- as kind "packet", so `log` shows them after the /reload that writes SavedVariables.
function Commands.packetEntry(api, opcode, packet, count)
    local bytes = {}
    local getByte = packet and packet.GetUInt8
    if type(getByte) == "function" then
        for _ = 1, count or DEFAULT_PACKET_BYTES do
            local ok, value = pcall(getByte, packet)
            if not ok or type(value) ~= "number" then
                break
            end
            bytes[#bytes + 1] = string.format("%02x", value % 256)
        end
    end
    return { time = api.time(), kind = "packet", opcode = opcode, asked = count or DEFAULT_PACKET_BYTES,
             read = #bytes, hex = table.concat(bytes) }
end

-- pkmeta: the methods a packet userdata offers, from its metatable, so a client build can be asked what it exposes.
Commands.handlers.pkmeta = function(api)
    local packetApi = Commands.packetApi(api)
    if type(packetApi.CreatePacket) ~= "function" then
        return nil, "CreatePacket is not available on this client"
    end
    local packet = packetApi.CreatePacket(0)
    local meta = api.getmetatable and api.getmetatable(packet) or getmetatable(packet)
    local names = {}
    local function collect(table)
        if type(table) ~= "table" then
            return
        end
        for key, value in pairs(table) do
            names[#names + 1] = tostring(key) .. ":" .. type(value)
        end
    end
    collect(meta)
    if type(meta) == "table" then
        collect(meta.__index)
    end
    table.sort(names)
    return { packetType = type(packet), metatable = type(meta), names = names }
end

-- pkwatch <opcode> [bytes]: from now on, and again after every /reload, record that opcode's packets into the
-- log, `bytes` of them each (default 64). The registration itself does not survive /reload, so the opcode and
-- its byte count are kept in CoaProbeWatch (SavedVariables) and CoaProbe.lua registers them again on load.
Commands.handlers.pkwatch = function(api, args)
    local opcode, err = numberArg(args, "usage: pkwatch <opcode> [bytes]")
    if not opcode then
        return nil, err
    end
    local count = tonumber(args[2]) or DEFAULT_PACKET_BYTES
    if count < 1 or count > MAX_PACKET_BYTES then
        return nil, "bytes must be between 1 and " .. MAX_PACKET_BYTES
    end
    if type(Commands.packetApi(api).RegisterPacket) ~= "function" then
        return nil, "RegisterPacket is not available on this client"
    end
    api.CoaProbeWatch = api.CoaProbeWatch or {}
    api.CoaProbeWatch[tostring(opcode)] = count
    local ok, problem = pcall(Commands.watch, api, opcode, count)
    if not ok then
        return nil, "RegisterPacket failed: " .. tostring(problem)
    end
    return { opcode = opcode, bytes = count, watching = true }
end

Commands.handlers.pkunwatch = function(api, args)
    local opcode, err = numberArg(args, "usage: pkunwatch <opcode>")
    if not opcode then
        return nil, err
    end
    if api.CoaProbeWatch then
        api.CoaProbeWatch[tostring(opcode)] = nil
    end
    return { opcode = opcode, watching = false, note = "stops after the next /reload" }
end

function Commands.watch(api, opcode, count)
    Commands.packetApi(api).RegisterPacket(opcode, function(receivedOpcode, packet)
        api.CoaProbeLog = api.CoaProbeLog or {}
        CoaProbe.Events.record(api.CoaProbeLog,
            Commands.packetEntry(api, receivedOpcode or opcode, packet, count))
    end)
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
