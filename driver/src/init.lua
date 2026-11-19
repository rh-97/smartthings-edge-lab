-- smartthings-edge-lab: a LAN Edge driver for software-only virtual devices.
--
-- Flow:
--   discovery  -> SSDP/mDNS search, GET /info, try_create_device
--   added      -> remember the device's URL, subscribe for pushes, refresh
--   init       -> (every driver start) subscribe again, schedule polling
--   commands   -> POST /command, emit the state the device reports back
--   pushes     -> device POSTs /push to us, we emit events
local Driver = require "st.driver"
local caps = require "st.capabilities"
local log = require "log"

local config = require "config"
local client = require "http_client"
local discovery = require "discovery"
local events = require "events"
local push_server = require "push_server"

---------------------------------------------------------------------------
-- Talking to one device
---------------------------------------------------------------------------

--- Look the device up again on the LAN (its IP or port may have changed).
local function relocate(device)
  local base = discovery.search_all()[device.device_network_id]
  if base then
    device:set_field(config.FIELD_BASE_URL, base, { persist = true })
  end
  return base
end

--- Call the device; on failure, try to find it again once before giving up.
-- Also keeps SmartThings' online/offline status honest.
local function call(device, method, path, body)
  local base = device:get_field(config.FIELD_BASE_URL)
  local result, err
  if base then
    result, err = client.request(method, base .. path, body)
  end
  if not result then
    local new_base = relocate(device)
    if new_base and new_base ~= base then
      result, err = client.request(method, new_base .. path, body)
    end
  end

  if result then
    device:online()
  else
    log.warn(string.format("%s: %s %s failed: %s", device.label, method, path, tostring(err)))
    device:offline()
  end
  return result, err
end

local function refresh(device)
  local state = call(device, "GET", "/state")
  if state then events.emit_state(device, state) end
end

local function subscribe(driver, device)
  local base = device:get_field(config.FIELD_BASE_URL)
  if not base or not push_server.port then return end
  local hub_ip = push_server.hub_ip(driver, client.host_of(base))
  local result = call(device, "POST", "/subscribe", {
    url = string.format("http://%s:%d/push", hub_ip, push_server.port),
    ttl = config.SUBSCRIBE_TTL,
  })
  if result and result.state then events.emit_state(device, result.state) end
end

local function find_device(driver, network_id)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == network_id then return device end
  end
end

---------------------------------------------------------------------------
-- Capability command handlers
---------------------------------------------------------------------------

local function send_command(_driver, device, command)
  local result = call(device, "POST", "/command", {
    capability = command.capability,
    command = command.command,
    args = command.args or {},
  })
  -- Emit what the device says it did, not what we asked for.
  if result and result.state then events.emit_state(device, result.state) end
end

local function handle_refresh(_driver, device, _command)
  refresh(device)
end

---------------------------------------------------------------------------
-- Lifecycle handlers
---------------------------------------------------------------------------

local function schedule(driver, device)
  if device:get_field(config.FIELD_SCHEDULED) then return end
  device:set_field(config.FIELD_SCHEDULED, true) -- not persisted: reset on restart
  device.thread:call_on_schedule(config.POLL_INTERVAL, function() refresh(device) end, "poll")
  device.thread:call_on_schedule(config.RESUBSCRIBE_INTERVAL, function() subscribe(driver, device) end,
    "resubscribe")
end

local function device_added(driver, device)
  local base = discovery.pending[device.device_network_id]
  discovery.pending[device.device_network_id] = nil
  if base then
    device:set_field(config.FIELD_BASE_URL, base, { persist = true })
  end
  log.info(string.format("%s: added (%s)", device.label, tostring(base)))
  subscribe(driver, device)
  refresh(device)
  schedule(driver, device)
end

local function device_init(driver, device)
  log.info(string.format("%s: init", device.label))
  subscribe(driver, device) -- push server port is new after every driver start
  schedule(driver, device)
end

local function device_removed(driver, device)
  local base = device:get_field(config.FIELD_BASE_URL)
  if base and push_server.port then
    local hub_ip = push_server.hub_ip(driver, client.host_of(base))
    client.post(base .. "/unsubscribe", {
      url = string.format("http://%s:%d/push", hub_ip, push_server.port),
    })
  end
  for timer in pairs(device.thread.timers) do
    device.thread:cancel_timer(timer)
  end
  log.info(string.format("%s: removed", device.label))
end

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------

local driver = Driver("smartthings-edge-lab", {
  discovery = discovery.handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    removed = device_removed,
  },
  supported_capabilities = {
    caps.switch,
    caps.switchLevel,
    caps.contactSensor,
    caps.motionSensor,
    caps.temperatureMeasurement,
    caps.relativeHumidityMeasurement,
    caps.refresh,
  },
  capability_handlers = {
    [caps.switch.ID] = {
      [caps.switch.commands.on.NAME] = send_command,
      [caps.switch.commands.off.NAME] = send_command,
    },
    [caps.switchLevel.ID] = {
      [caps.switchLevel.commands.setLevel.NAME] = send_command,
    },
    [caps.refresh.ID] = {
      [caps.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

push_server.start(function(network_id, state)
  local device = find_device(driver, network_id)
  if device then
    device:online()
    events.emit_state(device, state)
  else
    log.debug("push: from unknown device " .. tostring(network_id))
  end
end)

log.info("smartthings-edge-lab driver starting")
driver:run()
