-- Finding devices on the LAN (SSDP, plus mDNS where the hub supports it)
-- and turning them into SmartThings devices.
local cosock = require "cosock"
local socket = cosock.socket
local log = require "log"
local config = require "config"
local client = require "http_client"

local M = {}

-- Base URLs of devices we asked the hub to create, so the `added` lifecycle
-- handler can pick them up. Keyed by device_network_id.
M.pending = {}

local function parse_headers(packet)
  local headers = {}
  for line in packet:gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if key then
      headers[key:lower()] = value
    end
  end
  return headers
end

--- One SSDP M-SEARCH. Collects every answer that arrives within the window.
-- @return { [device id] = base_url }
function M.ssdp_search(window)
  local found = {}
  local udp, err = socket.udp()
  if not udp then
    log.error("ssdp: could not open UDP socket: " .. tostring(err))
    return found
  end
  udp:setsockname("*", 0)

  local msearch = table.concat({
    "M-SEARCH * HTTP/1.1",
    "HOST: " .. config.SSDP_ADDR .. ":" .. config.SSDP_PORT,
    'MAN: "ssdp:discover"',
    "MX: 2",
    "ST: " .. config.SEARCH_TARGET,
    "",
    "",
  }, "\r\n")
  udp:sendto(msearch, config.SSDP_ADDR, config.SSDP_PORT)

  local deadline = os.time() + (window or config.DISCOVERY_WINDOW)
  while true do
    local remaining = deadline - os.time()
    if remaining <= 0 then break end
    udp:settimeout(remaining)
    local packet, ip_or_err = udp:receivefrom()
    if not packet then break end -- "timeout": window is over

    local h = parse_headers(packet)
    local id = h.usn and h.usn:match("^uuid:([^:]+)")
    local base = client.base_of(h.location)
    if h.st == config.SEARCH_TARGET and id and base then
      found[id] = base
      log.debug(string.format("ssdp: %s at %s (from %s)", id, base, tostring(ip_or_err)))
    end
  end
  udp:close()
  return found
end

--- mDNS/Bonjour search for _stlab._tcp. Returns {} on hubs without st.mdns.
-- @return { [device id] = base_url }
function M.mdns_search()
  local found = {}
  local has_mdns, mdns = pcall(require, "st.mdns")
  if not has_mdns then return found end

  local response, err = mdns.discover(config.MDNS_SERVICE, config.MDNS_DOMAIN)
  if not response then
    log.debug("mdns: " .. tostring(err))
    return found
  end
  for _, event in ipairs(response.found or {}) do
    local host = event.host_info or {}
    -- Answers repeat once per network interface; keep IPv4 only.
    if host.address and host.address:match("^%d+%.%d+%.%d+%.%d+$") and host.port then
      local id
      for _, entry in ipairs((event.txt or {}).text or {}) do
        id = id or entry:match("^id=(.+)$")
      end
      if id then
        found[id] = string.format("http://%s:%d", host.address, host.port)
      end
    end
  end
  return found
end

--- Everything visible right now, from both protocols.
function M.search_all()
  local found = M.ssdp_search()
  for id, base in pairs(M.mdns_search()) do
    found[id] = found[id] or base
  end
  return found
end

local function known_devices(driver)
  local by_id = {}
  for _, device in ipairs(driver:get_devices()) do
    by_id[device.device_network_id] = device
  end
  return by_id
end

local function create(driver, id, base)
  local info, err = client.get(base .. "/info")
  if not info then
    log.warn(string.format("discovery: %s at %s did not answer /info: %s", id, base, err))
    return
  end
  local profile = config.PROFILES[info.type]
  if not profile or info.id ~= id then
    log.warn(string.format("discovery: skipping %s (type %s)", id, tostring(info.type)))
    return
  end

  M.pending[id] = base
  log.info(string.format("discovery: creating %q (%s) at %s", info.name, info.type, base))
  driver:try_create_device({
    type = "LAN",
    device_network_id = id,          -- stable id from the device, not its IP
    label = info.name,
    profile = profile,
    manufacturer = info.manufacturer,
    model = info.model,
    vendor_provided_label = info.name,
  })
end

--- Called by the hub when the user taps "Scan for nearby devices".
-- Keeps searching until the hub says stop (should_continue() == false).
function M.handler(driver, _opts, should_continue)
  log.info("discovery: started")
  local requested = {}
  while should_continue() do
    local known = known_devices(driver)
    for id, base in pairs(M.search_all()) do
      local device = known[id]
      if device then
        -- Already added: just keep its address current (DHCP, new port...).
        if device:get_field(config.FIELD_BASE_URL) ~= base then
          log.info(string.format("discovery: %s moved to %s", device.label, base))
          device:set_field(config.FIELD_BASE_URL, base, { persist = true })
        end
      elseif not requested[id] then
        requested[id] = true
        create(driver, id, base)
      end
    end
  end
  log.info("discovery: stopped")
end

return M
