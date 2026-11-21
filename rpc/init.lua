local computer = package.loaded.computer  -- require("computer") ก็ได้ผลลัพธ์เดียวกัน
local modem = require("component").modem
local event = require("event")
local io = require("event")
local serialization = require("serialization")
local rpc = {}

-- ================= TRANSPORT (แบ่งแพ็กเก็ตอัตโนมัติ + เข้ากันได้กับเวอร์ชั่นเก่า) =================
-- OpenComputers จำกัดขนาดแพ็กเก็ตของโมเด็มไว้ที่ maxPacketSize() (ปกติ 8192 byte)
--
-- แนวคิดสำคัญเพื่อให้ backward compatible กับ rpc.lua เวอร์ชั่นเก่า (ที่ไม่มีการแบ่ง chunk):
--   * ถ้าข้อมูลที่จะส่งมีขนาดไม่เกิน CHUNK_SIZE -> ส่งด้วย modem.send/broadcast(target, port, ...)
--     แบบเดิมทุกประการ ไม่มีการห่อ/ใส่ marker ใดๆ เพิ่ม -> รูปแบบ packet เหมือนเวอร์ชั่นเก่า 100%
--     ทำให้คุยกับคอมพิวเตอร์ที่ยังรันโค้ดเก่าได้ตามปกติ (ฝั่งรับเก่าก็อ่าน tbl[6..] ได้ตรงๆ)
--   * ถ้าข้อมูลเกินขนาด -> จำเป็นต้องแบ่งเป็นหลายแพ็กเก็ต ซึ่งเวอร์ชั่นเก่าส่งไม่ได้อยู่แล้ว (เกิน limit)
--     กรณีนี้จะห่อด้วย marker "C" (chunk) เป็นโปรโตคอลใหม่ ซึ่งต้องใช้ rpc.lua เวอร์ชั่นใหม่ทั้งสองฝั่ง
--     ถือว่าไม่ถดถอยจากของเดิม เพราะของเดิมก็ส่งข้อความขนาดนี้ไม่ได้อยู่แล้ว
--
-- ฝั่งรับ (tryParseEvent) จะเช็ค marker "C" ก่อน ถ้าไม่ตรงรูปแบบ chunk ก็จะถือว่าเป็นข้อมูลแบบเก่า
-- (raw data ที่ tb[6..]) ทันที ไม่ต้อง unserialize อะไรเลย เหมือนโค้ดต้นฉบับ

local MAX_PACKET = (modem.maxPacketSize and modem.maxPacketSize()) or 8192
local HEADER_MARGIN = 128 -- กันไว้สำหรับ marker/msgId/index/total ที่ส่งแนบไปกับแต่ละ chunk
local CHUNK_SIZE = math.max(MAX_PACKET - HEADER_MARGIN, 512)

local chunkCounter = 0
local function nextMsgId()
  chunkCounter = (chunkCounter + 1) % 1000000
  return string.format("%d-%d", math.floor(computer.uptime() * 1000), chunkCounter)
end

-- ประเมินขนาดของ varargs (คร่าวๆ) โดย serialize เพื่อเทียบกับ CHUNK_SIZE เท่านั้น
-- (ใช้ตัดสินใจว่าต้อง chunk หรือไม่ ไม่ได้ใช้ค่านี้เป็นรูปแบบที่ส่งจริงถ้าไม่เกิน)
local function chunkedSend(sendFn, ...)
  local args = table.pack(...)
  local ok, payload = pcall(serialization.serialize, args)
  local size = ok and #payload or math.huge

  if size <= CHUNK_SIZE then
    -- ส่งแบบเดิมตรงๆ ไม่มี marker เพิ่ม -> เข้ากันได้กับเวอร์ชั่นเก่า
    sendFn(...)
  else
    -- เกินขนาด ต้องแบ่งเป็นหลายแพ็กเก็ต (โปรโตคอลใหม่ ต้องใช้เวอร์ชั่นใหม่ทั้งสองฝั่ง)
    local msgId = nextMsgId()
    local total = math.ceil(#payload / CHUNK_SIZE)
    for i = 1, total do
      local chunk = payload:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
      sendFn("C", msgId, i, total, chunk)
    end
  end
end

local function sendTo(target, port, ...)
  chunkedSend(function(...) modem.send(target, port, ...) end, ...)
end

local function broadcastTo(port, ...)
  chunkedSend(function(...) modem.broadcast(port, ...) end, ...)
end

-- บัฟเฟอร์สำหรับประกอบชิ้นส่วนที่ยังมาไม่ครบ key = from:port:msgId
local chunkBuffers = {}

-- แปลง modem_message event (raw table จาก table.pack(event.pull(...))) ให้เป็น
-- from, port, data (array ของ argument เดิมที่ถูกส่งมา)
-- รองรับทั้งข้อความแบบเก่า (raw, ไม่มี marker) และแบบใหม่ (chunk, marker "C")
-- คืน nil ถ้า event นี้ไม่ใช่ modem_message ของเรา หรือยังรับ chunk ไม่ครบ
local function tryParseEvent(tbl)
  if tbl[1] ~= "modem_message" then return nil end
  local from = tbl[3]
  local port = tbl[4]
  local marker = tbl[6]

  -- ตรวจรูปแบบ chunk อย่างเข้มงวด (marker + msgId string + idx number + total number + chunk string
  -- และไม่มี field เกินมา) เพื่อลดโอกาสชนกับข้อมูลแบบเก่าที่บังเอิญมีค่าตรงกับ "C"
  if marker == "C"
      and type(tbl[7]) == "string"
      and type(tbl[8]) == "number"
      and type(tbl[9]) == "number"
      and type(tbl[10]) == "string"
      and tbl.n == 10 then
    local msgId, idx, total, chunk = tbl[7], tbl[8], tbl[9], tbl[10]
    local key = tostring(from) .. ":" .. tostring(port) .. ":" .. tostring(msgId)
    local buf = chunkBuffers[key]
    if not buf then
      buf = { total = total, received = 0, parts = {} }
      chunkBuffers[key] = buf
    end
    if not buf.parts[idx] then
      buf.parts[idx] = chunk
      buf.received = buf.received + 1
    end
    if buf.received >= buf.total then
      local full = table.concat(buf.parts, "", 1, buf.total)
      chunkBuffers[key] = nil
      local ok, packed = pcall(serialization.unserialize, full)
      if not ok or type(packed) ~= "table" then return nil end
      local data = {}
      for i = 1, (packed.n or #packed) do
        data[i] = packed[i]
      end
      return from, port, data
    end
    return nil -- ยังไม่ครบ รอ chunk ถัดไป
  end

  -- ไม่ใช่รูปแบบ chunk -> ถือเป็นข้อมูลแบบเก่า (raw) เหมือนโค้ดต้นฉบับ
  local data = {}
  for i = 6, tbl.n do
    table.insert(data, tbl[i])
  end
  return from, port, data
end

-- ================= SERVER =================
function rpc.server(portx, api, maxq, debug)
  modem.open(portx)
  local function log(...)
    if debug then print(...) end
  end
  log("INITIALIZING...")
  local freeID = {}
  local function getQID()
    for i = 1, maxq do
      if freeID[i] then
        freeID[i] = false
        return i
      end
    end
    return nil
  end
  local function freeQID(id)
    freeID[id] = true
  end
  for i = 1, maxq do
    freeID[i] = true
  end
  log("QUEUE INITIIALIZED")
  log("LISTENING FOR REQUEST")
  local function logreq(data, from, port)
    log(string.format("[ %.2f ] REQ FROM %s PORT %d DATA: %s",
      computer.uptime(), string.sub(from, 1, 5) .. "...", port, table.concat(data, ",")))
  end
  while true do
    local tbl = table.pack(event.pull("modem_message"))
    local from, port, data = tryParseEvent(tbl)
    if data then
      logreq(data, from, port)
      -- ขอ QID
      if data[1] == "getQID" then
        sendTo(from, port, getQID())
      else
        local qid = tonumber(data[1])
        local funcName = data[2]
        if qid and funcName then
          local args = {}
          for i = 3, #data do
            table.insert(args, data[i])
          end
          if api[funcName] then
            local result = table.pack(pcall(api[funcName], table.unpack(args)))
            sendTo(from, port, true, table.unpack(result))
          else
            sendTo(from, port, false, "no such function")
          end
          freeQID(qid)
        end
      end
    end
  end
end

-- ================= CLIENT =================
local lastAddress = nil
local function getMessage(port)
  local startT = computer.uptime()
  while true do
    local tb = table.pack(event.pull(5, "modem_message"))
    if computer.uptime() > startT + 10 then return nil, "timeout" end
    local from, p, data = tryParseEvent(tb)
    if data and p == port then
      lastAddress = from
      return data
    end
    -- ถ้า data เป็น nil (event อื่น / chunk ที่ยังไม่ครบ) ให้วนรับต่อจนครบ 10 วิ
  end
end

function rpc.client(port)
  modem.open(port)
  local prox = {}
  function prox.callbase(name, ...)
    -- ขอ QID
    local res = getMessage(port)
    if not res then return nil, "timeout" end
    if not res[1] then return nil, "timeout" end
    local qid = tonumber(res[1])
    if not qid then
      error("Failed to retrieve queue id")
    end
    -- ส่งคำสั่ง
    sendTo(lastAddress, port, qid, name, ...)
    -- รับผลลัพธ์
    local result = getMessage(port)
    if not result[1] then
      error(result[2])
    end
    return table.unpack(result, 2)
  end
  function prox.call(name, ...)
    if lastAddress ~= nil then
      sendTo(lastAddress, port, "getQID")
      local result = table.pack(prox.callbase(name, ...))
      if not (result[1] == nil and result[2] == "timeout") then
        return table.unpack(result)
      end
    end
    broadcastTo(port, "getQID")
    return prox.callbase(name, ...)
  end
  function prox.wrap(localName, remoteName)
    prox[localName] = function(...)
      return prox.call(remoteName, ...)
    end
  end
  return prox
end

return rpc
