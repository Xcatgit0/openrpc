local component = require("component")
local event = require("event")

local modem = component.modem

local M = {}

function M.createProxy(address, port)
  modem.open(port)

  local requestId = 0

  local function remoteCall(funcName, ...)
    requestId = requestId + 1
    local id = requestId

    modem.send(address, port, id, funcName, {...})

    while true do
      local _, _, from, p, _, rid, ok, result =
        event.pull("modem_message")

      if from == address and p == port and rid == id then
        return ok, result
      end
    end
  end

  local proxy = {}

  setmetatable(proxy, {
    __index = function(_, key)
      return function(...)
        local ok, result = remoteCall(key, ...)
        if not ok then
          return nil, result
        end
        return result
      end
    end
  })

  return proxy
end

return M