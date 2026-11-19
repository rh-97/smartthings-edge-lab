-- Stand-in for st.driver. Devices are plain tables that record what the
-- driver does to them, so the harness can assert on it.
local cosock = require "cosock"

local PROFILE_CAPS = {
  ["stlab-switch.v1"] = { "switch", "refresh" },
  ["stlab-dimmer.v1"] = { "switch", "switchLevel", "refresh" },
  ["stlab-contact.v1"] = { "contactSensor", "refresh" },
  ["stlab-motion.v1"] = { "motionSensor", "refresh" },
  ["stlab-temperature.v1"] = { "temperatureMeasurement", "relativeHumidityMeasurement", "refresh" },
}

local function new_device(meta)
  local caps = {}
  for _, c in ipairs(PROFILE_CAPS[meta.profile] or {}) do caps[c] = true end
  local device = {
    label = meta.label, device_network_id = meta.device_network_id, profile = meta.profile,
    fields = {}, events = {}, status = "unknown", caps = caps,
    thread = { timers = {} },
  }
  function device:get_field(k) return self.fields[k] end
  function device:set_field(k, v) self.fields[k] = v end
  function device:emit_event(e) table.insert(self.events, e) end
  function device:online() self.status = "online" end
  function device:offline() self.status = "offline" end
  function device:supports_capability_by_id(id) return self.caps[id] == true end
  function device:last(attribute)
    for i = #self.events, 1, -1 do
      if self.events[i].attribute == attribute then return self.events[i].value end
    end
  end
  function device.thread:call_on_schedule(period, fn, name)
    local t = { period = period, fn = fn, name = name }
    self.timers[t] = true
    return t
  end
  function device.thread:cancel_timer(t) self.timers[t] = nil end
  return device
end

return function(name, template)
  local driver = { NAME = name, template = template, devices = {}, environment_info = {} }
  function driver:get_devices() return self.devices end
  function driver:try_create_device(meta)
    local device = new_device(meta)
    table.insert(self.devices, device)
    cosock.spawn(function() template.lifecycle_handlers.added(self, device) end, "added")
  end
  function driver:run()
    _G.HARNESS_DRIVER = self
    cosock.spawn(_G.HARNESS_SCENARIO, "scenario")
    cosock.run()
  end
  return driver
end
