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
    local maxKey = 0
    for key in pairs(t) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
            return false
        end
        count = count + 1
        if key > maxKey then
            maxKey = key
        end
    end
    return count == maxKey
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
