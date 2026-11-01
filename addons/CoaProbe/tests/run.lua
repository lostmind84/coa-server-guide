-- Tests for the CoaProbe addon, outside the game client.
-- Run from the repository root: lua5.1 addons/CoaProbe/tests/run.lua
local passed, failures = 0, 0
local write = print

local function check(name, got, want)
    if got == want then
        passed = passed + 1
        write("ok   " .. name)
    else
        failures = failures + 1
        write("FAIL " .. name .. ": expected [" .. tostring(want) .. "], got [" .. tostring(got) .. "]")
    end
end

local function contains(name, text, part)
    if type(text) == "string" and text:find(part, 1, true) then
        passed = passed + 1
        write("ok   " .. name)
    else
        failures = failures + 1
        write("FAIL " .. name .. ": [" .. part .. "] not in [" .. tostring(text) .. "]")
    end
end

local root = arg[0]:match("^(.*)/tests/run%.lua$") or "."
dofile(root .. "/Json.lua")
local encode = CoaProbe.Json.encode

check("nil", encode(nil), "null")
check("true", encode(true), "true")
check("false", encode(false), "false")
check("integer", encode(9931032), "9931032")
check("float", encode(12.5), "12.5")
check("nan", encode(0 / 0), "null")
check("string escapes", encode('a"b\\c\nd\te'), '"a\\"b\\\\c\\nd\\te"')
check("control char", encode("x\1y"), '"x\\u0001y"')
check("pipe kept", encode("|cff71d5ff"), '"|cff71d5ff"')
check("utf8 kept", encode("Frère"), '"Frère"')
check("empty table", encode({}), "[]")
check("array", encode({ 1, "two", false }), '[1,"two",false]')
check("object sorted", encode({ b = 1, a = "x" }), '{"a":"x","b":1}')
check("nested", encode({ list = { { n = 1 } } }), '{"list":[{"n":1}]}')
check("sparse is object", encode({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}')
check("gapped keys are object", encode({ [2] = "b", [3] = "c", [5] = "e" }), '{"2":"b","3":"c","5":"e"}')

-- COMMANDS TESTS (Task 2)

dofile(root .. "/Commands.lua")
local run = CoaProbe.Commands.run

local function fontString(text)
    return { GetText = function() return text end }
end

local function makeApi()
    local api = {}
    api.time = function() return 1000 end
    api.UIParent = {}
    local lines = {}
    api.GameTooltip = {
        SetOwner = function() end,
        SetHyperlink = function(_, link)
            lines = { link, "second line" }
        end,
        NumLines = function() return #lines end,
        Hide = function() end,
    }
    setmetatable(api, { __index = function(_, key)
        local i = key:match("^GameTooltipTextLeft(%d+)$")
        if i then return fontString(lines[tonumber(i)]) end
        if key:match("^GameTooltipTextRight%d+$") then return fontString(nil) end
    end })
    api.GetSpellInfo = function(id)
        if id == 501281 then
            return "Fel Fireball", "Rank 2", "Interface\\Icons\\spell_fire_fireballgreen", 35, false, 3, 2000, 0, 30
        end
    end
    api.IsSpellKnown = function(id) return id == 501281 end
    api.UnitAura = function(unit, index, filter)
        if unit == "player" and index == 1 and filter == "HELPFUL" then
            return "PvE Mode", "", "icon", 0, nil, 0, 0, "player", nil, nil, 9931032
        end
    end
    local book = { { "Auto Attack", "", "|cff71d5ff|Hspell:6603|h[Auto Attack]|h|r" } }
    api.GetSpellName = function(index, bookType)
        local entry = bookType == "spell" and book[index]
        if entry then return entry[1], entry[2] end
    end
    api.GetSpellLink = function(index, bookType)
        local entry = bookType == "spell" and book[index]
        return entry and entry[3]
    end
    return api
end

local api = makeApi()
local answer = run(api, "r1 ping")
check("ping req", answer.req, "r1")
check("ping command", answer.command, "ping")
check("ping time", answer.time, 1000)
check("ping result", answer.result.pong, true)

answer = run(api, "r2 spell 501281")
check("spell name", answer.result.name, "Fel Fireball")
check("spell cast time", answer.result.castTime, 2000)
check("spell known", answer.result.known, true)
check("spell tooltip line", answer.result.tooltip[1].left, "spell:501281")
check("spell tooltip right empty", answer.result.tooltip[1].right, "")

answer = run(api, "r3 spell 42")
check("unknown spell error", answer.error, "unknown spell 42")
check("unknown spell no result", answer.result, nil)

answer = run(api, "r4 spell")
check("spell usage", answer.error, "usage: spell <id>")

answer = run(api, "r5 item 6948")
check("item tooltip", answer.result.tooltip[1].left, "item:6948")

answer = run(api, "r6 auras")
check("auras unit", answer.result.unit, "player")
check("auras count", #answer.result.auras, 1)
check("aura spell id", answer.result.auras[1].spellId, 9931032)
check("aura harmful", answer.result.auras[1].harmful, false)

answer = run(api, "r7 spellbook")
check("spellbook count", #answer.result.spells, 1)
check("spellbook id from link", answer.result.spells[1].id, 6603)
check("spellbook name", answer.result.spells[1].name, "Auto Attack")

answer = run(api, "r8 known 78")
check("known false", answer.result.known, false)

answer = run(api, "r9 dance")
check("unknown command", answer.error, "unknown command dance")

answer = run(api, "")
check("missing req", answer.error, "usage: /coaprobe <req> <command> [args]")

api.GetSpellInfo = function() error("boom") end
answer = run(api, "r10 spell 1")
contains("handler error captured", answer.error, "boom")

-- ADDON TESTS (Task 3)

SlashCmdList = {}
local printed = {}
print_original = print
print = function(text) printed[#printed + 1] = text end
CreateFrame = function()
    return { RegisterEvent = function() end, SetScript = function() end }
end
dofile(root .. "/Events.lua")
dofile(root .. "/CoaProbe.lua")

check("slash registered", SLASH_COAPROBE1, "/coaprobe")
CoaProbeDB = nil
local stub = makeApi()
CoaProbe.handle(stub, "s1 ping")
check("db created", type(CoaProbeDB), "table")
contains("answer stored as json", CoaProbeDB[1], '"req":"s1"')
contains("answer result", CoaProbeDB[1], '"pong":true')

for i = 1, 60 do
    CoaProbe.handle(stub, "bulk" .. i .. " ping")
end
check("db capped", #CoaProbeDB, 50)
contains("oldest dropped", CoaProbeDB[1], '"req":"bulk11"')

printed = {}
CoaProbe.handle(stub, "s2 dance")
check("error line", printed[1], "COAPROBE s2 error: unknown command dance")

print = print_original

-- Events and the log/state commands
local eventApi = makeApi()
local entry = CoaProbe.Events.entry(eventApi, "UI_ERROR_MESSAGE", "Not enough rage")
check("ui error kind", entry.kind, "error")
check("ui error text", entry.text, "Not enough rage")
-- 3.3.5 payload: (unit, spellName, spellRank, castID, spellID). arg4 (castID) and arg5 (spellID) are given
-- different values here so a test that reads spellId from the wrong argument fails.
local failed = CoaProbe.Events.entry(eventApi, "UNIT_SPELLCAST_FAILED", "player", "Witchbane", "Rank 7", 42)
check("cast failed kind", failed.kind, "cast_failed")
check("cast failed spell name", failed.spell, "Witchbane")
check("cast failed cast id", failed.castId, 42)
check("cast failed rank", failed.spellRank, "Rank 7")
check("other unit ignored", CoaProbe.Events.entry(eventApi, "UNIT_SPELLCAST_FAILED", "target", "X"), nil)
check("unwatched event ignored", CoaProbe.Events.entry(eventApi, "BAG_UPDATE"), nil)

local ring = {}
for i = 1, CoaProbe.Events.MAX + 5 do
    CoaProbe.Events.record(ring, { time = i, kind = "info", text = "e" .. i })
end
check("log capped", #ring, CoaProbe.Events.MAX)
check("log keeps the newest", ring[#ring].text, "e" .. (CoaProbe.Events.MAX + 5))

eventApi.CoaProbeLog = { { time = 1, kind = "error", text = "a" }, { time = 2, kind = "info", text = "b" } }
local logged = run(eventApi, "l1 log 1")
check("log total", logged.result.total, 2)
check("log returns the newest", logged.result.entries[1].text, "b")
check("log count", #logged.result.entries, 1)

eventApi.UnitExists = function(token) return token == "player" end
eventApi.UnitName = function() return "Labarba" end
eventApi.UnitLevel = function() return 60 end
eventApi.UnitHealth = function() return 1200 end
eventApi.UnitHealthMax = function() return 2236 end
eventApi.UnitIsDeadOrGhost = function() return false end
eventApi.UnitPowerType = function() return 1 end
eventApi.UnitPower = function(_, index) return index == 1 and 35 or 0 end
local state = run(eventApi, "s1 state")
check("state player name", state.result.player.name, "Labarba")
check("state player auras", #state.result.player.auras, 1)
check("state no target", state.result.target.exists, false)
check("state player rage", state.result.player.powers.rage, 35)
check("state player mana", state.result.player.powers.mana, 0)
check("state player power type", state.result.player.powerType, 1)

-- CHARACTER ADVANCEMENT

local caApi = makeApi()
local ca = run(caApi, "c0 ca 31194")
check("ca without service errors", ca.error,
    "C_CharacterAdvancement is not available on this client")

caApi.C_CharacterAdvancement = {
    GetActiveChrSpec = function() return 49 end,
    GetLearnedAE = function() return 26 end,
    GetLearnedTE = function() return 25 end,
    IsKnownID = function(id) return id == 31194 end,
    GetTalentRankByID = function(id) return id == 31194 and 3 or 0 end,
    IsTalentID = function() return true end,
    -- IsLockedID, IsKnownSpellID, GetPendingRankByEntryID and GetClassPointInvestment are
    -- absent here on purpose: the handler must report them rather than fail.
}

ca = run(caApi, "c1 ca 31194")
check("ca known", ca.result.known, true)
check("ca rank", ca.result.rank, 3)
check("ca active spec", ca.result.activeSpec, 49)
check("ca learned AE", ca.result.learnedAE, 26)
check("ca is talent", ca.result.isTalent, true)

-- PACKET API TESTS: CreatePacket/Put*/Send and RegisterPacket as the binary exposes them

local sentPackets, registered = {}, {}
local function makePacket(opcode)
    local packet = { opcode = opcode, writes = {}, bytes = { 1, 2, 3 }, cursor = 0 }
    local function put(kind)
        return function(self, value)
            self.writes[#self.writes + 1] = kind .. "=" .. tostring(value)
        end
    end
    packet.PutUInt8, packet.PutUInt16, packet.PutUInt32 = put("u8"), put("u16"), put("u32")
    packet.PutInt8, packet.PutInt16, packet.PutInt32 = put("i8"), put("i16"), put("i32")
    packet.PutFloat, packet.PutBool, packet.PutString = put("f"), put("b"), put("s")
    packet.GetUInt8 = function(self)
        self.cursor = self.cursor + 1
        if self.cursor > #self.bytes then
            error("past the end")
        end
        return self.bytes[self.cursor]
    end
    return packet
end
local pkApi = makeApi()
pkApi.CreatePacket = makePacket
pkApi.Send = function(packet) sentPackets[#sentPackets + 1] = packet end
pkApi.RegisterPacket = function(opcode, fn) registered[opcode] = fn end

local noApi = makeApi()
local pk = run(noApi, "p0 pksend 2347")
contains("pksend without the API errors", pk.error, "not available")

pk = run(pkApi, "p1 pksend 2347 u32:5 u8:1 s:abc f:1.5 b:1")
check("pksend sent", pk.result.sent, true)
check("pksend opcode", sentPackets[1].opcode, 2347)
check("pksend writes in order", table.concat(sentPackets[1].writes, ","), "u32=5,u8=1,s=abc,f=1.5,b=true")
check("pksend field count", #pk.result.fields, 5)

pk = run(pkApi, "p2 pksend 2347 x:1")
contains("pksend bad field", pk.error, "bad field")
pk = run(pkApi, "p3 pksend 2347 u32:abc")
contains("pksend bad number", pk.error, "bad number")

pk = run(pkApi, "p4 pkwatch 2347")
check("pkwatch answers", pk.result.watching, true)
check("pkwatch remembered", pkApi.CoaProbeWatch["2347"], 64)
check("pkwatch registered", type(registered[2347]), "function")
registered[2347](2347, makePacket(2347))
check("packet logged", pkApi.CoaProbeLog[1].kind, "packet")
check("packet opcode", pkApi.CoaProbeLog[1].opcode, 2347)
check("packet hex", pkApi.CoaProbeLog[1].hex, "010203")
check("packet bytes read", pkApi.CoaProbeLog[1].read, 3)
check("packet bytes asked", pkApi.CoaProbeLog[1].asked, 64)

pk = run(pkApi, "p6 pkwatch 2347 12")
check("pkwatch with a byte count", pk.result.bytes, 12)
pk = run(pkApi, "p7 pkwatch 2347 99999")
contains("pkwatch refuses a huge count", pk.error, "between 1 and")
pk = run(pkApi, "p8 pkmeta")
check("pkmeta packet type", pk.result.packetType, "table")
pk = run(pkApi, "p9 pkfind")
check("pkfind global", pk.result.where.CreatePacket, "_G")
local nsApi = makeApi()
nsApi.C_Packet = { CreatePacket = makePacket, Send = function(packet) sentPackets[#sentPackets + 1] = packet end }
pk = run(nsApi, "p10 pkfind")
check("pkfind namespaced", pk.result.where.Send, "C_Packet")
pk = run(nsApi, "p11 pksend 5 u16:7")
check("pksend through a namespace", pk.result.sent, true)
local evalApi = makeApi()
evalApi.loadstring, evalApi.setfenv, evalApi.pcall = loadstring, setfenv, pcall
evalApi.GetRealmName = function() return "Atlas" end
evalApi.Enum = { RecoveryCategory = { DeletedItems = 5 } }
local ev = run(evalApi, "e1 eval GetRealmName(), 1 + 1")
check("eval count", ev.result.count, 2)
check("eval first", ev.result.values[1], "Atlas")
check("eval second", ev.result.values[2], 2)
ev = run(evalApi, "e2 eval Enum.RecoveryCategory")
check("eval table", ev.result.values[1].DeletedItems, 5)
ev = run(evalApi, "e3 eval nosuchfunction()")
contains("eval runtime error", ev.error, "runtime:")
ev = run(evalApi, "e4 eval 1 +")
contains("eval compile error", ev.error, "compile:")
ev = run(evalApi, "e5 eval")
contains("eval usage", ev.error, "usage")
local evFrames = {}
pkApi.CreateFrame = function()
    local frame = { events = {}, RegisterEvent = function(self, e) self.events[#self.events + 1] = e end,
                    SetScript = function(self, _, fn) self.handler = fn end }
    evFrames[#evFrames + 1] = frame
    return frame
end
pk = run(pkApi, "e6 evwatch MY_EVENT")
check("evwatch answers", pk.result.watching, true)
check("evwatch remembered", pkApi.CoaProbeWatch["event:MY_EVENT"], true)
check("evwatch registered", evFrames[#evFrames].events[1], "MY_EVENT")
evFrames[#evFrames].handler(nil, "MY_EVENT", 7, "seven", true, {})
local last = pkApi.CoaProbeLog[#pkApi.CoaProbeLog]
check("event logged", last.kind, "event")
check("event args", table.concat({ tostring(last.args[1]), last.args[2], tostring(last.args[3]), last.args[4] }, ","), "7,seven,true,table")
pk = run(pkApi, "e7 evunwatch MY_EVENT")
check("evunwatch forgets", pkApi.CoaProbeWatch["event:MY_EVENT"], nil)
pk = run(pkApi, "p5 pkunwatch 2347")
check("pkunwatch forgets", pkApi.CoaProbeWatch["2347"], nil)

-- CoaProbe.lua restores the watches once the saved variables are in.
CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
SlashCmdList = {}
dofile(root .. "/CoaProbe.lua")
registered = {}
pkApi.CoaProbeWatch = { ["2347"] = 12, ["bad"] = true, ["event:X"] = true }
check("watches restored", CoaProbe.restoreWatches(pkApi), 2)
check("restored registration", type(registered[2347]), "function")
check("no API restores nothing", CoaProbe.restoreWatches(noApi), 0)
check("ca shim absent", ca.result.shim, false)
check("ca reports missing call", ca.result.unavailable.IsLockedID, "absent")
check("ca reports missing investment", ca.result.unavailable.GetClassPointInvestment, "absent")

ca = run(caApi, "c2 ca 999")
check("ca unknown entry", ca.result.known, false)
check("ca unknown rank", ca.result.rank, 0)

caApi.ASCENSION_LOCAL_CHARACTER_ADVANCEMENT_COMPAT = true
ca = run(caApi, "c3 ca")
check("ca shim reported", ca.result.shim, true)
check("ca without id has no entry", ca.result.id, nil)
check("ca without id still has spec", ca.result.activeSpec, 49)

caApi.C_CharacterAdvancement.IsKnownID = function() error("boom") end
ca = run(caApi, "c4 ca 31194")
check("ca reports throwing call", ca.result.unavailable.IsKnownID, "error")

ca = run(caApi, "c5 ca notanumber")
check("ca rejects bad id", ca.error, "usage: ca [entryId]")

-- RELAY TESTS

dofile(root .. "/Relay.lua")
local Relay = CoaProbe.Relay
CoaProbe.loadId = "load-1"

local function relayApi(sent, name)
    local api = makeApi()
    api.UnitName = function(unit) if unit == "player" then return name or "Coalabone" end end
    api.SendAddonMessage = function(prefix, message, channel, target)
        sent[#sent + 1] = { prefix = prefix, message = message, channel = channel, target = target }
    end
    return api
end

local function decodeField(json, field)
    return json:match('"' .. field .. '":"([^"]*)"')
end

local function joined(sent)
    local parts = {}
    for i, call in ipairs(sent) do
        parts[i] = call.message:match("^R:%w+:%d+:%d+:(.*)$")
    end
    return table.concat(parts)
end

local sent = {}
Relay.onAddonMessage(relayApi(sent), "CoaProbe", "Q:q1:ping", "WHISPER", "Coalabone")
check("relay answers ping in one chunk", #sent, 1)
contains("relay ping header", sent[1].message:sub(1, 9), "R:q1:1:1:")
check("relay ping prefix", sent[1].prefix, "CoaProbe")
check("relay ping channel", sent[1].channel, "WHISPER")
check("relay ping target", sent[1].target, "Coalabone")
check("relay ping req", decodeField(joined(sent), "req"), "q1")
contains("relay ping pong", joined(sent), '"pong":true')
check("relay ping loadId", decodeField(joined(sent), "loadId"), "load-1")
check("relay ping names the character", decodeField(joined(sent), "character"), "Coalabone")

sent = {}
local longApi = relayApi(sent)
longApi.GameTooltip.SetHyperlink = function() end
local longText = string.rep("Deals 35 Fire damage. ", 20)
longApi.GameTooltip.NumLines = function() return 1 end
setmetatable(longApi, { __index = function(_, key)
    if key == "GameTooltipTextLeft1" then return fontString(longText) end
    if key:match("^GameTooltipText") then return fontString(nil) end
end })
Relay.onAddonMessage(longApi, "CoaProbe", "Q:q2:spell 501281", "WHISPER", "Coalabone")
check("relay splits a long answer", #sent >= 3, true)
local within, fits = true, true
for i, call in ipairs(sent) do
    local index, total, data = call.message:match("^R:q2:(%d+):(%d+):(.*)$")
    if tonumber(index) ~= i or tonumber(total) ~= #sent or #data > Relay.CHUNK then
        within = false
    end
    if #Relay.PREFIX + 1 + #call.message > 255 then
        fits = false
    end
end
check("relay chunk headers and size", within, true)
check("relay messages fit 255 bytes", fits, true)
contains("relay joined answer is whole", joined(sent), longText)
check("relay joined answer ends the json", joined(sent):sub(-1), "}")

sent = {}
local spied = 0
CoaProbe.Commands.handlers.eval = function() spied = spied + 1 return {} end
local evalApi = relayApi(sent)
Relay.onAddonMessage(evalApi, "CoaProbe", "Q:q3:eval 1", "WHISPER", "Coalabone")
Relay.onAddonMessage(evalApi, "CoaProbe", "Q:q4:pksend 1", "WHISPER", "Coalabone")
check("relay refuses eval and pksend", #sent, 2)
check("relay refusal text", decodeField(joined({ sent[1] }), "error"), "not read-only over the relay")
check("relay refusal command", decodeField(joined({ sent[2] }), "command"), "pksend")
check("relay refused handler not called", spied, 0)

sent = {}
local quiet = relayApi(sent)
Relay.onAddonMessage(quiet, "Other", "Q:q5:ping", "WHISPER", "Coalabone")
Relay.onAddonMessage(quiet, "CoaProbe", "Q:q5:ping", "GUILD", "Coalabone")
Relay.onAddonMessage(quiet, "CoaProbe", "Q:q5:ping", "WHISPER", "Stranger")
Relay.onAddonMessage(quiet, "CoaProbe", "Q:q5:ping", "WHISPER", "Coalabonex")
Relay.onAddonMessage(quiet, "CoaProbe", "Q:q5:ping", "WHISPER", nil)
check("relay ignores other prefixes, channels and senders", #sent, 0)

Relay.onAddonMessage(quiet, "CoaProbe", "R:q5:1:1:{}", "WHISPER", "Coalabone")
check("relay ignores its own reply echo", #sent, 0)

Relay.onAddonMessage(quiet, "CoaProbe", "Q:q6:ping", "WHISPER", "Coalabone-Realm")
check("relay accepts Name-Realm sender", #sent, 1)

sent = {}
local bigApi = relayApi(sent)
CoaProbe.Commands.handlers.ping = function() return { blob = string.rep("x", 200 * 65) } end
Relay.onAddonMessage(bigApi, "CoaProbe", "Q:q7:ping", "WHISPER", "Coalabone")
check("relay replaces an oversized answer with an error", #sent, 1)
check("relay oversized error text", decodeField(joined(sent), "error"), "answer too large")
CoaProbe.Commands.handlers.ping = function() return { pong = true } end

sent = {}
local pipeApi = relayApi(sent)
CoaProbe.Commands.handlers.ping = function() return { text = "|cffffffffName|r" } end
Relay.onAddonMessage(pipeApi, "CoaProbe", "Q:q8:ping", "WHISPER", "Coalabone")
check("relay escapes pipes", sent[1].message:find("|", 1, true), nil)
contains("relay pipe as json escape", sent[1].message, "\\u007ccffffffffName\\u007cr")
CoaProbe.Commands.handlers.ping = function() return { pong = true } end

local utf = Relay.chunks("ab\195\168cd", 3)
check("chunks keep utf8 sequences", utf[1], "ab")
check("chunks utf8 second", utf[2], "\195\168c")
check("chunks of empty text", Relay.chunks("", 200)[1], "")
check("chunks of empty text count", #Relay.chunks("", 200), 1)

-- ERRORS AND FRAME TESTS

-- CoaProbe reads ERROR_HANDLER_DATABASE.errors (SharedXML/ErrorHandler/ErrorHandler.lua:11-16, 290-318), the
-- client's own error store, instead of installing its own handler (seterrorhandler is a client no-op,
-- SharedXML/Util/SharedOverwrites.lua:89-95, so the old handler never ran).
local function errorEntry(i)
    return { message = "boom " .. i, stack = "stack " .. i, locals = "locals " .. i, time = 1000 + i, counter = i }
end

local function fillErrors(api, count, previousCount)
    local current, previous = {}, {}
    for i = 1, count do
        current[i] = errorEntry(i)
    end
    for i = 1, previousCount or 0 do
        previous[i] = errorEntry(900 + i)
    end
    api.ERROR_HANDLER_DATABASE = { errors = { current = current, previous = previous } }
    return api.ERROR_HANDLER_DATABASE
end

local errApi = makeApi()
check("errors without the table errors", run(errApi, "e0 errors").error,
    "ERROR_HANDLER_DATABASE is not available on this client")

fillErrors(errApi, 7)
local defaultAnswer = run(errApi, "e1 errors").result
check("errors default count", #defaultAnswer.entries, 5)
check("errors newest first", defaultAnswer.entries[1].message, "boom 7")
check("errors newest first, oldest of the five", defaultAnswer.entries[5].message, "boom 3")
check("errors total current", defaultAnswer.total_current, 7)
check("errors total previous", defaultAnswer.total_previous, 0)
check("errors omits locals by default", defaultAnswer.entries[1].locals, nil)
check("errors source", defaultAnswer.source, "ERROR_HANDLER_DATABASE")
check("errors carries counter", defaultAnswer.entries[1].counter, 7)
check("errors carries time", defaultAnswer.entries[1].time, 1007)

check("errors N argument", #run(errApi, "e2 errors 2").result.entries, 2)
check("errors N argument newest", run(errApi, "e2b errors 2").result.entries[1].message, "boom 7")
check("errors N above total still returns what exists", #run(errApi, "e3 errors 100").result.entries, 7)

fillErrors(errApi, 30)
check("errors N capped at 20", #run(errApi, "e4 errors 100").result.entries, 20)
check("errors cap keeps newest", run(errApi, "e4b errors 100").result.entries[1].message, "boom 30")

fillErrors(errApi, 7, 2)
local prevAnswer = run(errApi, "e5 errors 1 previous").result
check("errors previous reads the previous table", prevAnswer.entries[1].message, "boom 902")
check("errors previous total", prevAnswer.total_previous, 2)
check("errors previous does not touch current count", prevAnswer.total_current, 7)

local localsAnswer = run(errApi, "e6 errors 1 locals").result
check("errors locals opt-in", localsAnswer.entries[1].locals, "locals 7")
local combinedAnswer = run(errApi, "e7 errors 1 previous locals").result
check("errors previous and locals together", combinedAnswer.entries[1].message, "boom 902")
check("errors previous and locals carries locals", combinedAnswer.entries[1].locals, "locals 902")

local longApi = makeApi()
longApi.ERROR_HANDLER_DATABASE = { errors = { current = {
    { message = string.rep("m", 600), stack = string.rep("s", 2000), locals = string.rep("l", 2000),
      time = 1, counter = 1 },
}, previous = {} } }
local truncated = run(longApi, "e8 errors 1 locals").result.entries[1]
check("errors truncates message to 500", #truncated.message, 500)
check("errors marks message truncated", truncated.messageTruncated, true)
check("errors truncates stack to 1500", #truncated.stack, 1500)
check("errors marks stack truncated", truncated.stackTruncated, true)
check("errors truncates locals to 1500", #truncated.locals, 1500)
check("errors marks locals truncated", truncated.localsTruncated, true)
check("errors leaves short fields unmarked", run(errApi, "e9 errors 1").result.entries[1].messageTruncated, false)

local emptyApi = makeApi()
emptyApi.ERROR_HANDLER_DATABASE = { errors = {} }
check("errors tolerates a database with no current/previous", #run(emptyApi, "e10 errors").result.entries, 0)

local frameApi = makeApi()
check("frame missing", run(frameApi, "f1 frame NoSuchFrame").result.exists, false)
rawset(frameApi, "MyFrame", {
    GetObjectType = function() return "Frame" end,
    IsShown = function() return 1 end,
    IsVisible = function() return nil end,
    GetText = function() return "hello" end,
})
local shown = run(frameApi, "f2 frame MyFrame").result
check("frame shown with text", shown.text, "hello")
check("frame type", shown.type, "Frame")
check("frame shown flag", shown.shown, true)
check("frame visible flag", shown.visible, false)
check("frame rejects bad name", run(frameApi, "f3 frame Bad.Name").error, "usage: frame <GlobalFrameName>")
check("frame rejects missing name", run(frameApi, "f4 frame").error, "usage: frame <GlobalFrameName>")
rawset(frameApi, "Broken", { GetObjectType = function() error("nope") end, IsShown = function() return 1 end })
local broken = run(frameApi, "f5 frame Broken").result
check("frame survives a throwing method", broken.exists, true)
check("frame throwing method gives nil", broken.type, nil)

local chainApi = makeApi()
local rootFrame = { GetName = function() return "UIParent" end, IsShown = function() return 1 end, GetParent = function() return nil end }
local hidden = { GetName = function() return "CharacterFrame" end, IsShown = function() return nil end, GetParent = function() return rootFrame end }
rawset(chainApi, "PaperDollFrame", {
    GetObjectType = function() return "Frame" end, IsShown = function() return 1 end, IsVisible = function() return nil end,
    GetParent = function() return hidden end, GetRect = function() return 10, 20, 300, 400 end,
})
local chain = run(chainApi, "f6 frame PaperDollFrame").result
check("frame lists its hidden parent", table.concat(chain.parents, ","), "CharacterFrame:0,UIParent:1")
check("frame reports its rectangle", chain.rect.width, 300)
check("frame without GetRect has no rectangle", run(frameApi, "f7 frame MyFrame").result.rect, nil)

local barApi = makeApi()
barApi.HasAction = function(slot) return slot == 6 end
barApi.GetActionInfo = function() return "spell", 680421 end
barApi.GetActionCooldown = function() return 100.5, 180, 1 end
barApi.GetActionTexture = function() return "Interface\\Icons\\ability_racial_avatar" end
rawset(barApi, "ActionButton5", { action = 5, IsVisible = function() return true end })
local bar = run(barApi, "a1 actionbar").result
check("actionbar lists only filled slots", #bar.slots, 1)
check("actionbar slot id", bar.slots[1].slot, 6)
check("actionbar spell id", bar.slots[1].id, 680421)
check("actionbar cooldown duration", bar.slots[1].cooldown.duration, 180)
check("actionbar lists the buttons", bar.buttons[1].button, "ActionButton5")
check("actionbar button slot", bar.buttons[1].slot, 5)
check("frame missing method gives nil", broken.text, nil)

-- CoaProbe.lua routes CHAT_MSG_ADDON to the relay. It no longer installs its own error handler (no
-- seterrorhandler call anywhere in the addon any more -- `errors` only reads ERROR_HANDLER_DATABASE).
local scripts, events = {}, {}
CreateFrame = function()
    return { RegisterEvent = function(_, e) events[e] = true end, SetScript = function(_, _, fn) scripts[1] = fn end }
end
time = function() return 4242 end
GetTime = function() return 1234.5678 end
SlashCmdList = {}
dofile(root .. "/CoaProbe.lua")
check("addon registers CHAT_MSG_ADDON", events.CHAT_MSG_ADDON, true)
check("addon does not register PLAYER_ENTERING_WORLD any more", events.PLAYER_ENTERING_WORLD, nil)
contains("addon load id uses time", CoaProbe.loadId, "4242-1234567-")
local routed
local originalOnAddon = Relay.onAddonMessage
Relay.onAddonMessage = function(api, ...) routed = { ... } end
scripts[1](nil, "CHAT_MSG_ADDON", "CoaProbe", "Q:z:ping", "WHISPER", "Me")
check("addon routes addon messages", routed and routed[2], "Q:z:ping")
Relay.onAddonMessage = originalOnAddon

-- The relay answer for the default `errors` request stays well under the 64 x 200 byte budget, and a
-- request for the maximum 20 entries at the maximum truncated size does not crash the chunker even though
-- it no longer fits (Relay.onAddonMessage falls back to its own "answer too large" answer, same as any
-- other oversized result).
local sizeSent = {}
local sizeApi = relayApi(sizeSent)
fillErrors(sizeApi, 20)
Relay.onAddonMessage(sizeApi, "CoaProbe", "Q:s1:errors", "WHISPER", "Coalabone")
check("errors default relay answer fits in one chunk budget", #sizeSent <= Relay.MAX_CHUNKS, true)
check("errors default relay answer is not an error", decodeField(joined(sizeSent), "error"), nil)

sizeSent = {}
sizeApi = relayApi(sizeSent)
local maxEntries = {}
for i = 1, 20 do
    maxEntries[i] = { message = string.rep("m", 500), stack = string.rep("s", 1500), time = i, counter = i }
end
sizeApi.ERROR_HANDLER_DATABASE = { errors = { current = maxEntries, previous = {} } }
Relay.onAddonMessage(sizeApi, "CoaProbe", "Q:s2:errors 20", "WHISPER", "Coalabone")
check("errors worst case 20 entries never exceeds the relay chunk budget", #sizeSent <= Relay.MAX_CHUNKS, true)
check("errors worst case 20 entries reports answer too large",
    decodeField(joined(sizeSent), "error"), "answer too large")

-- log entries carry the client's millisecond clock (GetTime) next to the one-second wall time
local clockLog = {}
GetTime = function() return 12.3456 end
CoaProbe.Events.record(clockLog, { time = 1, kind = "info", text = "a" })
GetTime = nil
CoaProbe.Events.record(clockLog, { time = 2, kind = "info", text = "b" })
check("record stamps the millisecond clock", clockLog[1].clock, 12345)
check("record leaves the clock out without GetTime", clockLog[2].clock, nil)

print(string.format("\n%d passed, %d failure(s)", passed, failures))
os.exit(failures > 0 and 1 or 0)
