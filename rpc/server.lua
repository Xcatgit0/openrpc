local component = require("component")
local event = require("event")

local modem = component.modem

local M = {}

function M.run(port, api)
  modem.open(port)

  while true do
    local _, _, from, p, _, id, funcName, args =
      event.pull("modem_message")

    if p == port then
      local f = api[funcName]

      if not f then
        modem.send(from, port, id, false, "no such function")
      else
        local ok, result = pcall(f, table.unpack(args or {}))
        modem.send(from, port, id, ok, result)
      end
    end
  end
end

return M