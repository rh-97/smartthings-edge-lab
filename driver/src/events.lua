-- Translate device state JSON into SmartThings capability events.
-- This is the one place that knows both vocabularies.
local caps = require "st.capabilities"

local M = {}

local function emit_if_supported(device, capability, event)
  if device:supports_capability_by_id(capability.ID) then
    device:emit_event(event)
  end
end

function M.emit_state(device, s)
  if s.switch ~= nil then
    emit_if_supported(device, caps.switch,
      s.switch == "on" and caps.switch.switch.on() or caps.switch.switch.off())
  end
  if type(s.level) == "number" then
    emit_if_supported(device, caps.switchLevel, caps.switchLevel.level(math.floor(s.level + 0.5)))
  end
  if s.contact ~= nil then
    emit_if_supported(device, caps.contactSensor,
      s.contact == "open" and caps.contactSensor.contact.open() or caps.contactSensor.contact.closed())
  end
  if s.motion ~= nil then
    emit_if_supported(device, caps.motionSensor,
      s.motion == "active" and caps.motionSensor.motion.active() or caps.motionSensor.motion.inactive())
  end
  if type(s.temperature) == "number" then
    emit_if_supported(device, caps.temperatureMeasurement,
      caps.temperatureMeasurement.temperature({ value = s.temperature, unit = "C" }))
  end
  if type(s.humidity) == "number" then
    emit_if_supported(device, caps.relativeHumidityMeasurement,
      caps.relativeHumidityMeasurement.humidity(math.floor(s.humidity + 0.5)))
  end
end

return M
