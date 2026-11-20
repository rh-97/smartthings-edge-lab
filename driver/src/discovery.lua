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

--- Render a value compactly, so a hub structure we did not expect can still be
-- read from logcat instead of just crashing on it.
local function describe(value, depth)
  if type(value) ~= "table" then
    return type(value) .. "(" .. tostring(value):sub(1, 40) .. ")"
  end
  if (depth or 0) > 1 then return "table" end
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = tostring(key) .. "=" .. describe(item, (depth or 0) + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

--- Read one TXT value out of an mDNS event.
-- The shape st.mdns hands over depends on the hub firmware: a flat map
-- (`{ id = "..." }`), a list of `"id=..."` strings, or a list of
-- `{ key =, value = }` tables, sometimes nested under `.text`. Accept any of
-- them: guessing wrong should cost an address, not the whole discovery run.
-- @return value string, or nil
local function txt_value(event, key)
  local pattern = "^" .. key .. "=(.+)$"

  local function look(container)
    if type(container) ~= "table" then return nil end
    if type(container[key]) == "string" then return container[key] end
    for _, entry in pairs(container) do
      if type(entry) == "string" then
        local value = entry:match(pattern)
        if value then return value end
      elseif type(entry) == "table" then
        local name = entry.key or entry.name or entry[1]
        local value = entry.value
        if value == nil and type(name) == "string" then value = entry[2] end
        if name == key and value ~= nil then
          return tostring(value)
        elseif type(name) == "string" then
          local nested = name:match(pattern) -- the whole pair in one field
          if nested then return nested end
        end
      end
    end
    return nil
  end

  local txt = type(event) == "table" and event.txt or nil
  return look(txt) or look(type(txt) == "table" and txt.text or nil)
end

--- One mDNS event -> device id and base URL, or nil when it is unusable.
local function event_to_base(event)
  local host = type(event) == "table" and event.host_info or nil
  if type(host) ~= "table" then return nil end
  local address = host.address or host.ip
  local port = tonumber(host.port)
  -- Answers repeat once per network interface; keep IPv4 only.
  if type(address) ~= "string" or not address:match("^%d+%.%d+%.%d+%.%d+$") or not port then
    return nil
  end
  local id = txt_value(event, "id")
  if not id then return nil end
  return id, string.format("http://%s:%d", address, port)
end

local logged_shape = false

--- mDNS/Bonjour search for _stlab._tcp. Returns {} on hubs without st.mdns.
-- Never raises: whatever the hub does with the reply, discovery goes on.
-- @return { [device id] = base_url }
function M.mdns_search()
  local found = {}
  local has_mdns, mdns = pcall(require, "st.mdns")
  if not has_mdns then return found end

  local called, response, err = pcall(mdns.discover, config.MDNS_SERVICE, config.MDNS_DOMAIN)
  if not called then
    log.warn("mdns: discover raised: " .. tostring(response))
    return found
  end
  if not response then
    log.debug("mdns: " .. tostring(err))
    return found
  end
  if not logged_shape then
    logged_shape = true
    log.debug("mdns: response shape " .. describe(response))
  end

  for index, event in ipairs(response.found or {}) do
    local ok, id, base = pcall(event_to_base, event)
    if not ok then
      log.warn(string.format("mdns: event %d could not be parsed: %s", index, tostring(id)))
    elseif id then
      found[id] = found[id] or base
      log.debug(string.format("mdns: %s at %s", id, base))
    else
      log.debug(string.format("mdns: event %d unusable: %s", index, describe(event)))
    end
  end
  return found
end

--- Everything visible right now, from both protocols. SSDP results count even
-- when the mDNS side fails outright.
function M.search_all()
  local found = M.ssdp_search()
  local ok, mdns_found = pcall(M.mdns_search)
  if not ok then
    log.warn("mdns: search failed, continuing with SSDP only: " .. tostring(mdns_found))
    mdns_found = {}
  end
  for id, base in pairs(mdns_found) do
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

--- One scan round: create what is new, keep the address of what is known.
local function scan_round(driver, requested)
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

--- Called by the hub when the user taps "Scan for nearby devices".
-- Keeps searching until the hub says stop (should_continue() == false). One bad
-- round must never end the scan: that is how SSDP answers got thrown away when
-- the mDNS reply turned out to look different than expected.
function M.handler(driver, _opts, should_continue)
  log.info("discovery: started")
  local requested = {}
  while should_continue() do
    local ok, err = pcall(scan_round, driver, requested)
    if not ok then
      log.warn("discovery: round failed: " .. tostring(err))
    end
    socket.sleep(1) -- without this the loop spins when a search returns fast
  end
  log.info("discovery: stopped")
end

return M
