-- /coaprobe <req> <command> [args]: run a probe command and append the JSON answer to CoaProbeDB. The client writes
-- SavedVariables on /reload or logout; coa-client-lab probe reads the answer from disk after a /reload.
-- Relay requests (addon whispers from the server, Relay.lua) answer without /reload.
CoaProbe = CoaProbe or {}

-- Changes on every UI load: answers carrying the same loadId prove no /reload happened between them. math.random
-- repeats across client processes (seen live), so the millisecond clock of GetTime() keeps instances apart.
CoaProbe.loadId = table.concat({
    tostring(type(time) == "function" and time() or 0),
    tostring(type(GetTime) == "function" and math.floor(GetTime() * 1000) or 0),
    tostring(math.random(100000, 999999)),
}, "-")

local MAX_ANSWERS = 50

function CoaProbe.handle(api, line)
    CoaProbeDB = CoaProbeDB or {}
    local answer = CoaProbe.Commands.run(api, line)
    CoaProbeDB[#CoaProbeDB + 1] = CoaProbe.Json.encode(answer)
    while #CoaProbeDB > MAX_ANSWERS do
        table.remove(CoaProbeDB, 1)
    end
    if answer.error then
        print("COAPROBE " .. answer.req .. " error: " .. answer.error)
    else
        print("COAPROBE " .. answer.req .. " ok")
    end
end

function CoaProbe.onEvent(api, event, ...)
    CoaProbeLog = CoaProbeLog or {}
    local entry = CoaProbe.Events.entry(api, event, ...)
    if entry then
        CoaProbe.Events.record(CoaProbeLog, entry)
    end
end

SLASH_COAPROBE1 = "/coaprobe"
SlashCmdList["COAPROBE"] = function(msg)
    CoaProbe.handle(_G, msg)
end

-- Packet watches asked for with `pkwatch` live in CoaProbeWatch (SavedVariables) and are registered again
-- here once the saved variables are in, since /reload -- the way every answer reaches disk -- drops them.
function CoaProbe.restoreWatches(api)
    local restored = 0
    for key, bytes in pairs(api.CoaProbeWatch or {}) do
        local opcode = tonumber(key)
        if opcode and pcall(CoaProbe.Commands.watch, api, opcode, tonumber(bytes)) then
            restored = restored + 1
        elseif type(key) == "string" and key:sub(1, 6) == "event:" and pcall(CoaProbe.Commands.watchEvent, api, key:sub(7)) then
            restored = restored + 1
        end
    end
    return restored
end

local frame = CreateFrame("Frame")
for _, event in ipairs(CoaProbe.Events.WATCHED) do
    frame:RegisterEvent(event)
end
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        CoaProbe.Relay.onAddonMessage(_G, ...)
        return
    end
    if event == "ADDON_LOADED" then
        if ... == "CoaProbe" then
            CoaProbe.restoreWatches(_G)
        end
        return
    end
    CoaProbe.onEvent(_G, event, ...)
end)
