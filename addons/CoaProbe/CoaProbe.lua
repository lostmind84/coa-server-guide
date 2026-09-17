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

SLASH_COAPROBE1 = "/coaprobe"
SlashCmdList["COAPROBE"] = function(msg)
    CoaProbe.handle(_G, msg)
end
