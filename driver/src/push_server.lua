-- A tiny HTTP server on the hub that devices POST state changes to.
--
-- Edge only lets a driver bind port 0 (the OS picks a free port), so the port
-- can change every time the driver restarts. That's why the driver
-- re-subscribes on every start: the subscription carries the current URL.
local cosock = require "cosock"
local socket = cosock.socket
local json = require "dkjson"
local log = require "log"

local M = { port = nil }

local MAX_BODY = 16 * 1024

local function respond(client, status, text)
  text = text or ""
  client:send(table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: text/plain",
    "Content-Length: " .. #text,
    "Connection: close",
    "",
    text,
  }, "\r\n"))
end

local function read_request(client)
  client:settimeout(5)
  local line, err = client:receive("*l")
  if not line then return nil, err end
  local method, path = line:match("^(%u+)%s+(%S+)")

  local headers = {}
  while true do
    local header = client:receive("*l")
    if not header or header == "" then break end
    local key, value = header:match("^([^:]+):%s*(.*)$")
    if key then headers[key:lower()] = value end
  end

  local length = tonumber(headers["content-length"] or "0") or 0
  if length > MAX_BODY then return nil, "body too large" end
  local body = length > 0 and client:receive(length) or ""
  return { method = method, path = path, body = body or "" }
end

local function handle(client, on_push)
  local req, err = read_request(client)
  if not req then
    log.debug("push: bad request: " .. tostring(err))
  elseif req.method == "POST" and req.path == "/push" then
    local msg = json.decode(req.body)
    if type(msg) == "table" and type(msg.id) == "string" and type(msg.state) == "table" then
      on_push(msg.id, msg.state)
      respond(client, "200 OK", "ok")
    else
      respond(client, "400 Bad Request", "expected {id, state}")
    end
  else
    respond(client, "404 Not Found")
  end
  client:close()
end

--- Start listening. on_push(device_network_id, state) runs for every push.
function M.start(on_push)
  local server = assert(socket.tcp())
  assert(server:bind("*", 0))
  assert(server:listen(16))
  local _, port = server:getsockname()
  M.port = port
  log.info("push: listening on port " .. tostring(port))

  cosock.spawn(function()
    while true do
      local client, err = server:accept()
      if client then
        cosock.spawn(function() handle(client, on_push) end, "push-client")
      else
        log.warn("push: accept failed: " .. tostring(err))
      end
    end
  end, "push-server")
end

--- The hub's address as seen from a device at `peer_ip`.
function M.hub_ip(driver, peer_ip)
  local env_ip = driver.environment_info and driver.environment_info.hub_ipv4
  if env_ip then return env_ip end
  -- Fallback: "connecting" a UDP socket picks the right interface, sends nothing.
  local udp = socket.udp()
  udp:setpeername(peer_ip, 9)
  local ip = udp:getsockname()
  udp:close()
  return ip
end

return M
