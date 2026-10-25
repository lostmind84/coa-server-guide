-- Lua error capture through the addon's own error handler: keeps the last MAX errors in memory and passes every
-- error on to the handler that was installed before (the default one shows the error frame).
CoaProbe = CoaProbe or {}
local Errors = {}
CoaProbe.Errors = Errors

Errors.MAX = 50
Errors.entries = {}
Errors.total = 0

function Errors.install(api)
    local previous = api.geterrorhandler()
    local function handler(message, ...)
        Errors.total = Errors.total + 1
        Errors.entries[#Errors.entries + 1] = { time = api.time(), message = tostring(message) }
        while #Errors.entries > Errors.MAX do
            table.remove(Errors.entries, 1)
        end
        if previous then
            return previous(message, ...)
        end
    end
    Errors.handler = handler
    api.seterrorhandler(handler)
    return handler
end

function Errors.current(api)
    return Errors.handler ~= nil and api.geterrorhandler() == Errors.handler
end
