-- Relay transport: the worldserver whispers `Q:<req>:<line>` to this character as an addon message (prefix
-- CoaProbe, sent by the server in the character's own name); the answer goes back as chunked addon whispers
-- `R:<req>:<index>:<total>:<data>` to the character itself, which the server relay swallows and reassembles.
-- Only read-only commands run over the relay, and nothing is written to SavedVariables, so no /reload is needed.
CoaProbe = CoaProbe or {}
local Relay = {}
CoaProbe.Relay = Relay

Relay.PREFIX = "CoaProbe"
Relay.CHUNK = 200
Relay.MAX_CHUNKS = 64
Relay.READ_ONLY = {
    ping = true, spell = true, item = true, auras = true, spellbook = true, known = true,
    log = true, state = true, ca = true, frame = true, errors = true,
}

-- Cut text into pieces of at most `size` bytes without splitting a UTF-8 sequence.
function Relay.chunks(text, size)
    local parts, first, last = {}, 1, #text
    while first <= last do
        local cut = math.min(first + size - 1, last)
        while cut < last and cut > first do
            local nextByte = text:byte(cut + 1)
            if nextByte < 0x80 or nextByte >= 0xC0 then
                break
            end
            cut = cut - 1
        end
        parts[#parts + 1] = text:sub(first, cut)
        first = cut + 1
    end
    if #parts == 0 then
        parts[1] = ""
    end
    return parts
end

-- `|` starts an escape sequence in WoW chat strings; | keeps the JSON identical once decoded.
local function wireJson(answer)
    return (CoaProbe.Json.encode(answer):gsub("|", "\\u007c"))
end

function Relay.onAddonMessage(api, prefix, message, channel, sender)
    if prefix ~= Relay.PREFIX or channel ~= "WHISPER" or type(message) ~= "string" or type(sender) ~= "string" then
        return false
    end
    local me = api.UnitName("player")
    if not me or sender:match("^[^-]*") ~= me then
        return false
    end
    local req, line = message:match("^Q:(%w+):(.*)$")
    if not req then
        return false
    end
    local command = line:match("^(%S+)") or ""
    local answer
    if Relay.READ_ONLY[command] then
        answer = CoaProbe.Commands.run(api, req .. " " .. line)
    else
        answer = { req = req, command = command, error = "not read-only over the relay" }
    end
    answer.loadId = CoaProbe.loadId
    local parts = Relay.chunks(wireJson(answer), Relay.CHUNK)
    if #parts > Relay.MAX_CHUNKS then
        parts = Relay.chunks(wireJson({ req = req, command = command, error = "answer too large",
            loadId = CoaProbe.loadId }), Relay.CHUNK)
    end
    for index, part in ipairs(parts) do
        api.SendAddonMessage(Relay.PREFIX, "R:" .. req .. ":" .. index .. ":" .. #parts .. ":" .. part, "WHISPER", me)
    end
    return true
end
