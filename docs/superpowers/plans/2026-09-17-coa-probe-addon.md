# CoaProbe Addon (Milestone 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An addon (`CoaProbe`) that answers agent requests inside the lab client with structured JSON (spell,
item, auras, spellbook, known spell), and a `coa-client-lab probe COMMAND...` command that sends a request, forces
the answer to disk and prints it as JSON.

**Architecture:** Pure Lua 5.1 modules (`Json.lua`, `Commands.lua`) take the WoW API as a table, so `lua5.1` tests
run them with stubs outside the client. `CoaProbe.lua` wires a `/coaprobe <req> <command> [args]` slash command
that appends the JSON answer to the `CoaProbeDB` SavedVariable. On the host, `coa-client-lab start` installs the
addon into the lab client, `probe` types the request and `/reload` (SavedVariables are written on reload), then a
Python reader extracts the answer for the request id from `WTF/Account/<ACCOUNT>/SavedVariables/CoaProbe.lua`.

**Tech Stack:** WoW 3.3.5 Lua 5.1 addon API, `lua5.1` (tests), Python 3 stdlib (`json`, `re`, `unittest`), bash.

**Spec:** `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md` (component 3, "Addon CoaProbe") and
`docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md` (Q3 and "Milestone 2 API check").

## Global Constraints

- The user's client (`~/CoaServer/client/ascension-live`) and prefix (`~/Games/umu/coa-client`) are never
  modified; the addon is installed only into the lab client. Run `coa-client-lab` only through its test script
  (fakes, `COA_*` overrides), except in the real-run task.
- Never stop processes with `pkill -f <pattern>`. Stop by PID.
- Verified client facts to rely on (API check): `UnitAura(unit, i)` returns 11 values, 11th = spell id;
  `GetSpellInfo(id)` returns name, rank, icon, cost, isFunnel, powerType, castTime, minRange, maxRange;
  `IsSpellKnown`, `GetSpellName(i, "spell")`, `GetSpellLink(i, "spell")` exist, the link looks like
  `|cff71d5ff|Hspell:6603|h[Auto Attack]|h|r`; `GameTooltip:SetHyperlink("spell:<id>")` and `("item:<id>")` fill
  `GameTooltipTextLeft<i>`.
- Not verified (the real-run task checks them): `UnitAura`'s third `filter` argument; the escaping WoW uses when it
  writes a string containing `"` or `\` into SavedVariables.
- Typed text reaches Lua with `|` doubled: no request may contain `|`; Lua code uses `string.char(124)` if needed.
- An addon folder added while the client runs is not loaded by `/reload`: install before `start` launches the client.
- UI error capture is out of scope (a `seterrorhandler` wrapper did not see errors).
- `.toc` files use CRLF (the proven spike addon did); `.lua` files use LF.
- Repository text is English; `README.md` and `README.fr.md` stay in sync. Bash style as `scripts/coa-slot`
  (4-space indent, `set -euo pipefail`); Lua and Python 4-space indent.
- Conventional Commits; no session links or `Claude-Session` trailers.

## File Structure

| Path | Role |
|---|---|
| `addons/CoaProbe/CoaProbe.toc` | addon manifest, SavedVariable `CoaProbeDB` |
| `addons/CoaProbe/Json.lua` | `CoaProbe.Json.encode(value)` |
| `addons/CoaProbe/Commands.lua` | `CoaProbe.Commands.run(api, line)` and the command handlers |
| `addons/CoaProbe/CoaProbe.lua` | `/coaprobe` slash command, answer storage |
| `addons/CoaProbe/tests/run.lua` | `lua5.1` tests with stub API |
| `.gitattributes` | CRLF for `*.toc` |
| `scripts/coa-probe-read.py` | extract one answer from `CoaProbe.lua` SavedVariables |
| `scripts/tests/test_coa_probe_read.py` | `unittest` tests for the reader |
| `scripts/coa-client-lab` | install addon on `start`, record account on `login`, `probe` command |
| `scripts/tests/coa-client-lab.test.sh` | probe tests with fakes |

---

### Task 1: JSON encoder and Lua test runner

**Files:**
- Create: `addons/CoaProbe/Json.lua`
- Create: `addons/CoaProbe/tests/run.lua`

**Interfaces:**
- Produces: global table `CoaProbe`; `CoaProbe.Json.encode(value) -> string` (nil/NaN/inf -> `null`, integers
  without decimals, other numbers `%.14g`, arrays for tables whose keys are exactly `1..#t` (empty table -> `[]`),
  objects with sorted keys otherwise); test helpers `check(name, got, want)` and `contains(name, text, part)`
  in `run.lua`, and the marker lines `-- COMMANDS TESTS (Task 2)` and `-- ADDON TESTS (Task 3)`.

- [ ] **Step 1: Write the test runner with the JSON tests**

`addons/CoaProbe/tests/run.lua`:
```lua
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

-- COMMANDS TESTS (Task 2)

-- ADDON TESTS (Task 3)

print(string.format("\n%d passed, %d failure(s)", passed, failures))
os.exit(failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to see it fail**

Run: `lua5.1 addons/CoaProbe/tests/run.lua`
Expected: error `cannot open addons/CoaProbe/Json.lua`, exit non-zero.

- [ ] **Step 3: Write the encoder**

`addons/CoaProbe/Json.lua`:
```lua
-- JSON encoding for CoaProbe answers (Lua 5.1, no WoW API).
CoaProbe = CoaProbe or {}
local Json = {}
CoaProbe.Json = Json

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    local escaped = s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. escaped .. '"'
end

local function isArray(t)
    local count = 0
    for key in pairs(t) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
            return false
        end
        count = count + 1
    end
    return count == #t
end

function Json.encode(value)
    local kind = type(value)
    if kind == "nil" then
        return "null"
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        if math.floor(value) == value then
            return string.format("%d", value)
        end
        return string.format("%.14g", value)
    elseif kind == "string" then
        return encodeString(value)
    elseif kind == "table" then
        local parts = {}
        if isArray(value) then
            for i = 1, #value do
                parts[i] = Json.encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for i, key in ipairs(keys) do
            parts[i] = encodeString(tostring(key)) .. ":" .. Json.encode(value[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("cannot encode a " .. kind)
end
```

- [ ] **Step 4: Run to see it pass**

Run: `lua5.1 addons/CoaProbe/tests/run.lua`
Expected: all `ok`, `15 passed, 0 failure(s)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/CoaProbe/Json.lua addons/CoaProbe/tests/run.lua
git commit -m "feat(coaprobe): JSON encoder with lua5.1 tests"
```

---

### Task 2: Probe commands

**Files:**
- Create: `addons/CoaProbe/Commands.lua`
- Modify: `addons/CoaProbe/tests/run.lua` (replace the `-- COMMANDS TESTS (Task 2)` line)

**Interfaces:**
- Consumes: `check`, `contains`, `root` from Task 1's runner.
- Produces: `CoaProbe.Commands.run(api, line) -> answer table` with keys `req`, `command`, `time`, and either
  `result` or `error`; handlers `ping`, `spell <id>`, `item <id>`, `auras [unit]`, `spellbook`, `known <id>` in
  `CoaProbe.Commands.handlers`; `api` is `_G` in the client and a stub in tests. Test helper `makeApi()`.

- [ ] **Step 1: Write the failing tests**

Replace `-- COMMANDS TESTS (Task 2)` with:
```lua
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
```

- [ ] **Step 2: Run to see the new tests fail**

Run: `lua5.1 addons/CoaProbe/tests/run.lua`
Expected: error `cannot open addons/CoaProbe/Commands.lua`, exit non-zero.

- [ ] **Step 3: Write the commands**

`addons/CoaProbe/Commands.lua`:
```lua
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
```

- [ ] **Step 4: Run to see all pass**

Run: `lua5.1 addons/CoaProbe/tests/run.lua`
Expected: `0 failure(s)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add addons/CoaProbe/Commands.lua addons/CoaProbe/tests/run.lua
git commit -m "feat(coaprobe): spell, item, auras, spellbook and known commands"
```

---

### Task 3: Addon wiring and manifest

**Files:**
- Create: `addons/CoaProbe/CoaProbe.lua`
- Create: `addons/CoaProbe/CoaProbe.toc`
- Create: `.gitattributes`
- Modify: `addons/CoaProbe/tests/run.lua` (replace the `-- ADDON TESTS (Task 3)` line)

**Interfaces:**
- Consumes: `CoaProbe.Commands.run`, `CoaProbe.Json.encode`, `makeApi`.
- Produces: slash command `/coaprobe` (`SlashCmdList.COAPROBE`); `CoaProbe.handle(api, line)`; `CoaProbeDB`
  is an array of JSON strings, at most 50, oldest removed first; chat line `COAPROBE <req> ok` or
  `COAPROBE <req> error: <message>`.

- [ ] **Step 1: Write the failing tests**

Replace `-- ADDON TESTS (Task 3)` with:
```lua
SlashCmdList = {}
local printed = {}
print_original = print
print = function(text) printed[#printed + 1] = text end
dofile(root .. "/CoaProbe.lua")
print = print_original

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
print = function(text) printed[#printed + 1] = text end
CoaProbe.handle(stub, "s2 dance")
print = print_original
check("error line", printed[1], "COAPROBE s2 error: unknown command dance")
```

- [ ] **Step 2: Run to see the new tests fail**

Run: `lua5.1 addons/CoaProbe/tests/run.lua`
Expected: error `cannot open addons/CoaProbe/CoaProbe.lua`, exit non-zero.

- [ ] **Step 3: Write the addon file, manifest and attributes**

`addons/CoaProbe/CoaProbe.lua`:
```lua
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
```

`addons/CoaProbe/CoaProbe.toc` (write with CRLF line endings, for example with
`printf '## Interface: 30300\r\n## Title: CoaProbe\r\n## Notes: Answers coa-client-lab probe requests\r\n## SavedVariables: CoaProbeDB\r\nJson.lua\r\nCommands.lua\r\nCoaProbe.lua\r\n' > addons/CoaProbe/CoaProbe.toc`):
```
## Interface: 30300
## Title: CoaProbe
## Notes: Answers coa-client-lab probe requests
## SavedVariables: CoaProbeDB
Json.lua
Commands.lua
CoaProbe.lua
```

`.gitattributes`:
```
*.toc text eol=crlf
```

- [ ] **Step 4: Run to see all pass**

Run: `lua5.1 addons/CoaProbe/tests/run.lua && file addons/CoaProbe/CoaProbe.toc`
Expected: `0 failure(s)`; `file` reports `with CRLF line terminators`.

- [ ] **Step 5: Commit**

```bash
git add .gitattributes addons/CoaProbe/CoaProbe.lua addons/CoaProbe/CoaProbe.toc addons/CoaProbe/tests/run.lua
git commit -m "feat(coaprobe): /coaprobe slash command storing answers in SavedVariables"
```

---

### Task 4: SavedVariables reader

**Files:**
- Create: `scripts/coa-probe-read.py`
- Create: `scripts/tests/test_coa_probe_read.py`

**Interfaces:**
- Produces: `scripts/coa-probe-read.py SAVEDVARIABLES_FILE REQ` — prints the newest answer whose `req` equals REQ
  as indented JSON and exits 0; exits 1 silently when the file or the answer is missing (the caller polls);
  exits 2 on wrong usage. Functions `lua_unescape(text)`, `find_answer(raw_bytes, req)`.

- [ ] **Step 1: Write the failing tests**

`scripts/tests/test_coa_probe_read.py`:
```python
"""Tests for scripts/coa-probe-read.py. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'"""
import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "coa-probe-read.py"
spec = importlib.util.spec_from_file_location("coa_probe_read", SCRIPT)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

SAMPLE = (
    b'\nCoaProbeDB = {\n'
    rb'	"{\"command\":\"ping\",\"req\":\"r1\",\"result\":{\"pong\":true}}", -- [1]' b'\n'
    rb'	"{\"command\":\"item\",\"req\":\"r2\",\"result\":{\"text\":\"a\\nb\"}}", -- [2]' b'\n'
    rb'	"{\"command\":\"ping\",\"req\":\"r1\",\"result\":{\"pong\":false}}", -- [3]' b'\n'
    rb'	"{\"req\":\"r3\",\"result\":{\"name\":\"Fr\195\168re\"}}", -- [4]' b'\n'
    b'}\n'
)


class LuaUnescapeTest(unittest.TestCase):
    def test_simple_escapes(self):
        self.assertEqual(reader.lua_unescape(r'a\"b\\c\nd'), 'a"b\\c\nd')

    def test_decimal_escape(self):
        self.assertEqual(reader.lua_unescape(r'\65\066'), "AB")


class FindAnswerTest(unittest.TestCase):
    def test_newest_answer_wins(self):
        self.assertEqual(reader.find_answer(SAMPLE, "r1")["result"], {"pong": False})

    def test_json_escape_inside_lua_string(self):
        self.assertEqual(reader.find_answer(SAMPLE, "r2")["result"]["text"], "a\nb")

    def test_utf8_from_decimal_escapes(self):
        self.assertEqual(reader.find_answer(SAMPLE, "r3")["result"]["name"], "Frère")

    def test_missing_request(self):
        self.assertIsNone(reader.find_answer(SAMPLE, "nope"))

    def test_ignores_non_json_strings(self):
        self.assertIsNone(reader.find_answer(b'X = {\n\t"not json", -- [1]\n}\n', "r1"))


class MainTest(unittest.TestCase):
    def test_prints_answer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "CoaProbe.lua"
            path.write_bytes(SAMPLE)
            out = io.StringIO()
            with redirect_stdout(out):
                code = reader.main(["coa-probe-read.py", str(path), "r2"])
        self.assertEqual(code, 0)
        self.assertIn('"req": "r2"', out.getvalue())

    def test_missing_file(self):
        self.assertEqual(reader.main(["coa-probe-read.py", "/nonexistent/CoaProbe.lua", "r1"]), 1)

    def test_usage(self):
        self.assertEqual(reader.main(["coa-probe-read.py"]), 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to see them fail**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
Expected: error loading `coa-probe-read.py` (file not found).

- [ ] **Step 3: Write the reader**

`scripts/coa-probe-read.py`:
```python
#!/usr/bin/env python3
"""Print the CoaProbe answer for a request id, read from the addon's SavedVariables file.

Usage: coa-probe-read.py SAVEDVARIABLES_FILE REQ
Exit 0 with the answer as JSON, 1 when the file or the answer is not there yet, 2 on wrong usage.
"""
import json
import re
import sys
from pathlib import Path

LUA_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"', re.S)
LUA_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


def lua_unescape(text):
    """Decode a Lua string body. Works on latin-1 text so that decimal escapes map to single bytes."""
    out = []
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\" or i + 1 == len(text):
            out.append(char)
            i += 1
            continue
        nxt = text[i + 1]
        digits = re.match(r"\d{1,3}", text[i + 1:])
        if digits:
            out.append(chr(int(digits.group(0))))
            i += 1 + len(digits.group(0))
        else:
            out.append(LUA_ESCAPES.get(nxt, nxt))
            i += 2
    return "".join(out)


def find_answer(raw_bytes, req):
    text = raw_bytes.decode("latin-1")
    for match in reversed(list(LUA_STRING.finditer(text))):
        body = lua_unescape(match.group(1)).encode("latin-1")
        try:
            answer = json.loads(body.decode("utf-8"))
        except ValueError:
            continue
        if isinstance(answer, dict) and answer.get("req") == req:
            return answer
    return None


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        return 1
    answer = find_answer(path.read_bytes(), argv[2])
    if answer is None:
        return 1
    print(json.dumps(answer, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```
`chmod +x scripts/coa-probe-read.py`. `UnicodeDecodeError` is a subclass of `ValueError`, so a non-UTF-8 body is
skipped too.

- [ ] **Step 4: Run to see them pass**

Run: `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
Expected: `Ran 10 tests`, `OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/coa-probe-read.py scripts/tests/test_coa_probe_read.py
git commit -m "feat(coaprobe): read probe answers from SavedVariables"
```

---

### Task 5: `coa-client-lab probe`

**Files:**
- Modify: `scripts/coa-client-lab`
- Modify: `scripts/tests/coa-client-lab.test.sh`

**Interfaces:**
- Consumes: `scripts/coa-probe-read.py` (Task 4), `addons/CoaProbe/` (Tasks 1-3), existing `require_running`,
  `cmd_chat`, `SLEEP`, `STATE_DIR`, `LAB_CLIENT`, `cmd_stop`.
- Produces: `start` copies `addons/CoaProbe` (without `tests/`) to `$LAB_CLIENT/Interface/AddOns/CoaProbe` before
  launching; `login` writes `$STATE_DIR/account`; `stop` removes it; `coa-client-lab probe COMMAND [ARGS...]`
  prints the answer JSON (exit 0) or dies after `COA_LAB_PROBE_TIMEOUT` seconds (default 30); after an answer it
  waits `COA_LAB_RELOAD_WAIT` seconds (default 10) through `$SLEEP` so the reloaded UI accepts input.

- [ ] **Step 1: Write the failing tests**

In `make_fakes`, inside the fake `xdotool` script, add after the `printf ... >> "$FAKE_LOG"` line (the heredoc is
quoted, so no escaping changes):
```bash
if [[ "$1" == type && "${*: -1}" == /reload && "${FAKE_PROBE_SILENT:-}" != 1 ]]; then
    req=$(grep -o '/coaprobe [^ ]*' "$FAKE_LOG" | tail -1 | cut -d' ' -f2)
    dir="$COA_LAB_ROOT/ascension-lab/WTF/Account/LABSPIKE/SavedVariables"
    mkdir -p "$dir"
    printf 'CoaProbeDB = {\n\t"{\\"command\\":\\"ping\\",\\"req\\":\\"%s\\",\\"result\\":{\\"pong\\":true}}", -- [1]\n}\n' \
        "$req" > "$dir/CoaProbe.lua"
fi
```
Add a new block just before the final `printf '\n%s failure(s)\n' "$FAILURES"` line:
```bash
# PROBE TESTS (Milestone 2)
run_lab start 3
assert_file "addon installed" "$COA_LAB_ROOT/ascension-lab/Interface/AddOns/CoaProbe/CoaProbe.toc"
assert_absent "addon tests not installed" "$COA_LAB_ROOT/ascension-lab/Interface/AddOns/CoaProbe/tests"
run_lab login labspike secretpw
assert_eq "account recorded" "$(cat "$COA_LAB_ROOT/state/account")" "labspike"

: > "$FAKE_LOG"
run_lab probe ping
assert_eq "probe exits 0" "$?" "0"
assert_contains "probe types the request" "$FAKE_LOG" "type --window 4242 --delay 40 /coaprobe p"
assert_contains "probe reloads" "$FAKE_LOG" "type --window 4242 --delay 40 /reload"
assert_contains "probe prints the answer" "$WORK/out" '"pong": true'

if run_lab probe 'spell 1|2'; then fail "probe refuses a pipe"; else pass "probe refuses a pipe"; fi
assert_contains "pipe message" "$WORK/out" "cannot contain |"

if FAKE_PROBE_SILENT=1 COA_LAB_PROBE_TIMEOUT=1 run_lab probe ping; then
    fail "probe times out without an answer"
else
    pass "probe times out without an answer"
fi
assert_contains "probe timeout message" "$WORK/out" "no CoaProbe answer"

run_lab stop
assert_absent "account cleared by stop" "$COA_LAB_ROOT/state/account"
```

- [ ] **Step 2: Run to see the new tests fail**

Run: `scripts/tests/coa-client-lab.test.sh`
Expected: earlier tests `ok`; the probe block reports FAIL lines (addon not installed, unknown command `probe`).

- [ ] **Step 3: Implement**

In `scripts/coa-client-lab`:

1. After `SLEEP=...`, add:
```bash
PROBE_TIMEOUT="${COA_LAB_PROBE_TIMEOUT:-30}"
RELOAD_WAIT="${COA_LAB_RELOAD_WAIT:-10}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ADDON_SRC="$SCRIPT_DIR/../addons/CoaProbe"
PROBE_READER="$SCRIPT_DIR/coa-probe-read.py"
```
2. In `cmd_start`, right after `rm -rf "$LAB_CLIENT/Cache"`, add:
```bash
    # The client only loads addon folders present at launch.
    rm -rf "$LAB_CLIENT/Interface/AddOns/CoaProbe"
    cp -r "$ADDON_SRC" "$LAB_CLIENT/Interface/AddOns/CoaProbe"
    rm -rf "$LAB_CLIENT/Interface/AddOns/CoaProbe/tests"
```
3. In `cmd_login`, right after `require_running`, add `echo "$1" > "$STATE_DIR/account"`.
4. In `cmd_stop`, add `"$STATE_DIR/account"` to the `rm -f` list of state files.
5. Add after `cmd_screenshot`:
```bash
# The addon answers in SavedVariables, which the client writes on /reload (spike findings Q3).
cmd_probe() {
    [[ $# -ge 1 ]] || die "usage: coa-client-lab probe COMMAND [ARGS...]"
    [[ "$*" != *'|'* ]] || die "probe arguments cannot contain | (the chat edit box doubles it)"
    require_running
    local account file req waited
    account=$(cat "$STATE_DIR/account" 2>/dev/null) || die "no login recorded: coa-client-lab login ACCOUNT PASSWORD"
    file="$LAB_CLIENT/WTF/Account/${account^^}/SavedVariables/CoaProbe.lua"
    req="p$(date +%s%N)"
    cmd_chat "/coaprobe $req $*"
    "$SLEEP" 1
    cmd_chat "/reload"
    for ((waited = 0; waited < PROBE_TIMEOUT; waited++)); do
        if python3 "$PROBE_READER" "$file" "$req"; then
            "$SLEEP" "$RELOAD_WAIT"
            return 0
        fi
        sleep 1
    done
    die "no CoaProbe answer for $req after ${PROBE_TIMEOUT}s, see $file"
}
```
6. In `usage`, add under Running: `  probe COMMAND [ARGS...]  ask the CoaProbe addon (ping, spell ID, item ID, auras [UNIT], spellbook, known ID); prints JSON`.
7. In `main`, add `probe) cmd_probe "$@" ;;`.

- [ ] **Step 4: Run to see all pass**

Run: `bash -n scripts/coa-client-lab && scripts/tests/coa-client-lab.test.sh`
Expected: `0 failure(s)`; no fake process left (`ps -eo pid,args | grep -F 'Ascension.exe' | grep -v grep` shows no
test process).

- [ ] **Step 5: Commit**

```bash
git add scripts/coa-client-lab scripts/tests/coa-client-lab.test.sh
git commit -m "feat(client-lab): install CoaProbe and add the probe command"
```

---

### Task 6: Real run and documentation

**Files:**
- Modify: `README.md`, `README.fr.md` (section "Client lab for agents" / "Client de labo pour les agents")
- Modify: `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md` (Milestone 2 line)
- Modify: `docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md` (append real-run facts)

- [ ] **Step 1: Server and client**

```bash
coa-slot list
coa-slot claim <free N> "coaprobe milestone 2 real run"
git -C ~/Projects/azerothcore-wotlk-coa fetch -q origin
coa-slot deploy <N> origin/main
coa-client-lab preflight <N>
```
Expected: `RESULT: PASS` (a FAIL stops the task). Create the account and character if missing:
```bash
set -a; . ~/CoaServer/slots/s<N>/ghost.env; set +a
cd ~/CoaServer/client-lab-spike/mkaccount && go run . labspike labspike && go test -run TestMakeLabCharacter -count=1 .
```

- [ ] **Step 2: Probe every command**

```bash
coa-client-lab start <N>
coa-client-lab login labspike labspike
coa-client-lab probe ping
coa-client-lab probe spell 501281
coa-client-lab probe item 6948
coa-client-lab chat ".aura 1243"
coa-client-lab probe auras
coa-client-lab probe spellbook
coa-client-lab probe known 78
```
Expected: each prints JSON with the matching `req` and a `result`. Check: `spell` name `Fel Fireball`, cost 35,
castTime 2000; `item` first tooltip line `Hearthstone`; `auras` lists `PvE Mode` (spellId 9931032) and the 1243
aura, which verifies `UnitAura`'s filter argument (if `auras` is empty or errors, record it and switch the handler
to calling `UnitAura(unit, i)` without a filter and reporting all auras with `harmful` omitted, with its test
updated); `spellbook` first entry `Auto Attack` id 6603.

- [ ] **Step 3: Check the SavedVariables format and the reload wait**

`cat ~/CoaServer/client-lab/ascension-lab/WTF/Account/LABSPIKE/SavedVariables/CoaProbe.lua | head -5` and confirm the
escaping of `"` and `\` matches what `scripts/tests/test_coa_probe_read.py` assumes (`\"` and `\\`). If it differs,
add a test with the real line and fix `lua_unescape`.
Right after a `probe`, run `coa-client-lab chat "/say after-probe"` and a screenshot: the line must be in the chat.
If it is missing, raise `RELOAD_WAIT`'s default and retry, and record the value that works.

- [ ] **Step 4: Stop and release**

```bash
coa-client-lab stop
coa-slot release <N>
```
Expected: `lab client stopped`, no WARN (or confirm with the user), no lab process left.

- [ ] **Step 5: Document**

In `README.md`, in "Client lab for agents", add after the `coa-client-lab screenshot` line of the code block:
```bash
coa-client-lab probe spell 501281          # ask the CoaProbe addon; prints JSON (ping, spell, item, auras, spellbook, known)
```
and after the paragraph that follows the code block, add:
```markdown
`start` installs the CoaProbe addon ([`addons/CoaProbe`](addons/CoaProbe)) into the lab client. A probe types
`/coaprobe`, then `/reload` so the client writes the answer to its SavedVariables, which
[`scripts/coa-probe-read.py`](scripts/coa-probe-read.py) reads; each probe takes a reload (about <measured> seconds).
Tests: `lua5.1 addons/CoaProbe/tests/run.lua` and `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
(`scripts/tests/coa-client-lab.test.sh` needs `python3`).
```
In `README.fr.md`, the same in French:
```bash
coa-client-lab probe spell 501281             # interroge l'addon CoaProbe ; affiche du JSON (ping, spell, item, auras, spellbook, known)
```
```markdown
`start` installe l'addon CoaProbe ([`addons/CoaProbe`](addons/CoaProbe)) dans le client de labo. Un probe tape
`/coaprobe`, puis `/reload` pour que le client écrive la réponse dans ses SavedVariables, que
[`scripts/coa-probe-read.py`](scripts/coa-probe-read.py) lit ; chaque probe coûte un rechargement (environ
<mesuré> secondes). Tests : `lua5.1 addons/CoaProbe/tests/run.lua` et
`python3 -m unittest discover -s scripts/tests -p 'test_*.py'` (`scripts/tests/coa-client-lab.test.sh` a besoin
de `python3`).
```
Replace `<measured>` / `<mesuré>` with the time observed in Step 2. Document what actually worked if a step
needed a change.

In the design spec, replace the line starting with `2. CoaProbe: tooltip, auras, known spells, Lua errors.` by:
```markdown
2. **CoaProbe**: done 2026-09-17 (`addons/CoaProbe`, `coa-client-lab probe`; commands ping, spell, item, auras,
   spellbook, known). UI error capture is not included: a `seterrorhandler` wrapper did not see errors.
```
Append the real-run facts (filter argument result, SavedVariables escaping, reload wait) to the spike findings
under a heading `## Milestone 2 real run`.

- [ ] **Step 6: Run all tests and commit**

```bash
lua5.1 addons/CoaProbe/tests/run.lua
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
scripts/tests/coa-client-lab.test.sh
git add README.md README.fr.md docs/superpowers/specs/
git commit -m "docs(coaprobe): document the probe command and real-run results"
```
Expected: all three suites green.
