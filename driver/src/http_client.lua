-- Minimal JSON-over-HTTP client for talking to devices on the LAN.
--
-- socket.http is blocking; cosock.asyncify makes it cooperate with the
-- hub's single-threaded scheduler so one slow device can't freeze the rest.
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "dkjson"
local config = require "config"

local M = {}

local function create_socket()
  local sock = cosock.socket.tcp()
  sock:settimeout(config.HTTP_TIMEOUT)
  return sock
end

--- Send a request and decode the JSON reply.
-- @return table on success, or nil and an error message
function M.request(method, url, body)
  local payload = body and json.encode(body) or nil
  local chunks = {}
  local headers = {}
  if payload then
    headers["content-type"] = "application/json"
    headers["content-length"] = tostring(#payload)
  end

  local ok, code = http.request({
    url = url,
    method = method,
    headers = headers,
    source = payload and ltn12.source.string(payload) or nil,
    sink = ltn12.sink.table(chunks),
    create = create_socket,
  })
  if not ok then
    return nil, code and tostring(code) or ("could not reach " .. url)
  end

  local raw = table.concat(chunks)
  local decoded, _, err = json.decode(raw ~= "" and raw or "{}")
  if code ~= 200 then
    local reason = type(decoded) == "table" and decoded.error or raw
    return nil, string.format("HTTP %s: %s", tostring(code), tostring(reason))
  end
  if err or type(decoded) ~= "table" then
    return nil, "invalid JSON from device: " .. tostring(err)
  end
  return decoded
end

function M.get(url)
  return M.request("GET", url)
end

function M.post(url, body)
  return M.request("POST", url, body or {})
end

--- "http://192.168.1.20:8801/info" -> "http://192.168.1.20:8801"
function M.base_of(url)
  return url and url:match("^(https?://[^/]+)")
end

--- "http://192.168.1.20:8801" -> "192.168.1.20"
function M.host_of(url)
  return url and url:match("^https?://([^:/]+)")
end

return M
