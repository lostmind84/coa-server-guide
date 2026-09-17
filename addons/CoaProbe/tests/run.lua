-- Tests for the CoaProbe addon, outside the game client.
-- Run from the repository root: lua5.1 addons/CoaProbe/tests/run.lua
local passed, failures = 0, 0

local function check(name, got, want)
    if got == want then
        passed = passed + 1
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. ": expected [" .. tostring(want) .. "], got [" .. tostring(got) .. "]")
    end
end

local function contains(name, text, part)
    if type(text) == "string" and text:find(part, 1, true) then
        passed = passed + 1
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. ": [" .. part .. "] not in [" .. tostring(text) .. "]")
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

print(string.format("\n%d passed, %d failure(s)", passed, failures))
os.exit(failures > 0 and 1 or 0)
