-- /coaprobe <req> <command> [args]: run a probe command and append the JSON answer to CoaProbeDB. The client writes
-- SavedVariables on /reload or logout; coa-client-lab probe reads the answer from disk after a /reload.
CoaProbe = CoaProbe or {}

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
    if type(CoaProbe.Commands.packetApi(api).RegisterPacket) ~= "function" then
        return 0
    end
    local restored = 0
    for key, bytes in pairs(api.CoaProbeWatch or {}) do
        local opcode = tonumber(key)
        if opcode and pcall(CoaProbe.Commands.watch, api, opcode, tonumber(bytes)) then
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
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == "CoaProbe" then
            CoaProbe.restoreWatches(_G)
        end
        return
    end
    CoaProbe.onEvent(_G, event, ...)
end)
