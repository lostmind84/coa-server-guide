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

print(string.format("\n%d passed, %d failure(s)", passed, failures))
os.exit(failures > 0 and 1 or 0)
