-- Continuous capture of what the client shows and then forgets: UI errors ("Not enough rage"), system messages,
-- and the player's spell casts with their failure reason. The lab agent cannot read the screen, and /reload (which
-- is how answers reach disk) clears the chat frame, so these events are the only trace of why an action failed.
CoaProbe = CoaProbe or {}
local Events = {}
CoaProbe.Events = Events

Events.MAX = 200

function Events.record(log, entry)
    log[#log + 1] = entry
    while #log > Events.MAX do
        table.remove(log, 1)
    end
    return log
end

-- Turns one game event into a flat record; returns nil for events we do not keep.
function Events.entry(api, event, arg1, arg2, arg3, arg4)
    if event == "UI_ERROR_MESSAGE" then
        return { time = api.time(), kind = "error", text = arg1 }
    elseif event == "UI_INFO_MESSAGE" then
        return { time = api.time(), kind = "info", text = arg1 }
    elseif event == "CHAT_MSG_SYSTEM" then
        return { time = api.time(), kind = "system", text = arg1 }
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" then
        return { time = api.time(), kind = "cast", spell = arg2, spellId = arg4 }
    elseif event == "UNIT_SPELLCAST_FAILED" and arg1 == "player" then
        return { time = api.time(), kind = "cast_failed", spell = arg2, spellId = arg4 }
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" and arg1 == "player" then
        return { time = api.time(), kind = "cast_interrupted", spell = arg2, spellId = arg4 }
    end
end

Events.WATCHED = {
    "UI_ERROR_MESSAGE", "UI_INFO_MESSAGE", "CHAT_MSG_SYSTEM",
    "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
}
