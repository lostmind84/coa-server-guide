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
