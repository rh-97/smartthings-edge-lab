-- Stand-in for st.capabilities: just enough to build and inspect events.
local function attribute(cap, name, values)
  local attr = setmetatable({ NAME = name }, {
    __call = function(_, v)
      if type(v) == "table" then
        return { capability = cap, attribute = name, value = v.value, unit = v.unit }
      end
      return { capability = cap, attribute = name, value = v }
    end,
  })
  for _, value in ipairs(values or {}) do
    attr[value] = function() return { capability = cap, attribute = name, value = value } end
  end
  return attr
end

local function capability(id, attrs, commands)
  local cap = { ID = id, commands = {} }
  for name, values in pairs(attrs) do cap[name] = attribute(id, name, values) end
  for _, c in ipairs(commands or {}) do cap.commands[c] = { NAME = c } end
  return cap
end

return {
  switch = capability("switch", { switch = { "on", "off" } }, { "on", "off" }),
  switchLevel = capability("switchLevel", { level = {} }, { "setLevel" }),
  contactSensor = capability("contactSensor", { contact = { "open", "closed" } }),
  motionSensor = capability("motionSensor", { motion = { "active", "inactive" } }),
  temperatureMeasurement = capability("temperatureMeasurement", { temperature = {} }),
  relativeHumidityMeasurement = capability("relativeHumidityMeasurement", { humidity = {} }),
  refresh = capability("refresh", {}, { "refresh" }),
}
