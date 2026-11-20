-- Hub-less integration test: runs the real driver code (with real cosock and
-- LuaSocket) against virtual_device.py, mocking only the st.* framework.
-- Run it with scripts/test-driver.sh.
package.path = "tests/mocks/?.lua;src/?.lua;" .. package.path

local cosock = require "cosock"
local client = require "http_client"
local discovery = require "discovery"

local failures, passes = 0, 0
local function check(cond, what)
  if cond then passes = passes + 1; print("PASS " .. what)
  else failures = failures + 1; print("FAIL " .. what) end
end
local function sleep(s) cosock.socket.sleep(s) end
local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

_G.HARNESS_SCENARIO = function()
  local ok, err = pcall(function()
    local driver = _G.HARNESS_DRIVER
    local t = driver.template
    local function by_profile(p)
      for _, d in ipairs(driver.devices) do if d.profile == p then return d end end
    end

    -- 0. mDNS: TXT records arrive in more than one shape (this is what a real
    -- hub's firmware did to the first version), and none of them may raise.
    _G.MDNS_MOCK = {
      found = {
        { host_info = { address = "203.0.113.5", port = 8801 },
          txt = { text = { { key = "id", value = "mdns-table" }, { key = "type", value = "switch" } } } },
        { host_info = "not a table", txt = { id = "mdns-malformed" } }, -- must not stop the rest
        { host_info = { address = "203.0.113.6", port = 8802 },
          txt = { text = { "id=mdns-string", "type=dimmer" } } },
        { host_info = { name = "phone.local.", address = "203.0.113.7", port = 8803 },
          txt = { id = "mdns-flat", type = "contact" } },
        { host_info = { address = "fe80::1", port = 8804 }, txt = { id = "mdns-ipv6" } },
        { host_info = { address = "203.0.113.8", port = 8805 }, txt = { text = { "type=switch" } } },
      },
    }
    local mdns_found = discovery.mdns_search()
    check(mdns_found["mdns-table"] == "http://203.0.113.5:8801", "mdns: {key=, value=} TXT record parsed")
    check(mdns_found["mdns-string"] == "http://203.0.113.6:8802", "mdns: \"id=...\" TXT record parsed")
    check(mdns_found["mdns-flat"] == "http://203.0.113.7:8803", "mdns: flat TXT map parsed")
    check(mdns_found["mdns-malformed"] == nil and mdns_found["mdns-ipv6"] == nil
      and count_keys(mdns_found) == 3,
      "mdns: malformed, IPv6 and id-less events skipped (got " .. count_keys(mdns_found) .. ")")

    _G.MDNS_MOCK = { raises = "simulated hub failure" }
    local raised_ok, raised = pcall(discovery.mdns_search)
    check(raised_ok and next(raised) == nil, "mdns: a raising discover yields {} and no error")
    _G.MDNS_MOCK = { error = "simulated hub error" }
    check(next(discovery.mdns_search()) == nil, "mdns: a nil response is logged, not fatal")
    _G.MDNS_MOCK = nil

    -- 1. Discovery: one search round, then stop.
    local rounds = 0
    t.discovery(driver, {}, function() rounds = rounds + 1; return rounds == 1 end)
    sleep(1.5) -- let the `added` handlers finish
    check(#driver.devices == 5, "discovery created 5 devices (got " .. #driver.devices .. ")")

    local switch = by_profile("stlab-switch.v1")
    local dimmer = by_profile("stlab-dimmer.v1")
    local contact = by_profile("stlab-contact.v1")
    local temp = by_profile("stlab-temperature.v1")
    check(switch and switch.fields.base_url ~= nil, "added stored the switch's base_url")
    check(switch and switch.status == "online", "switch is online after added")
    check(switch and switch:last("switch") == "off", "initial switch state emitted")
    check(temp and type(temp:last("temperature")) == "number", "temperature emitted")

    -- 2. Commands.
    local on = t.capability_handlers.switch.on
    on(driver, switch, { capability = "switch", command = "on", args = {} })
    check(switch:last("switch") == "on", "switch.on -> switch event 'on'")

    local set_level = t.capability_handlers.switchLevel.setLevel
    set_level(driver, dimmer, { capability = "switchLevel", command = "setLevel", args = { level = 30 } })
    check(dimmer:last("level") == 30 and dimmer:last("switch") == "on", "setLevel 30 -> level 30, switch on")

    -- 3. Push: change the sensor on the device side, expect an event without polling.
    local before = #contact.events
    local res = client.post(contact.fields.base_url .. "/simulate", { contact = "open" })
    check(res ~= nil, "simulate contact open on the device")
    sleep(1)
    check(#contact.events > before and contact:last("contact") == "open", "push delivered contact 'open'")

    -- 4. Relocation: pretend the device moved; refresh must find it again.
    local real = switch.fields.base_url
    switch.fields.base_url = "http://127.0.0.1:1"
    t.capability_handlers.refresh.refresh(driver, switch, {})
    check(switch.fields.base_url == real and switch.status == "online", "refresh relocated a moved device")

    -- 5. Offline detection: a device that's gone stays offline.
    local ghost = { label = "ghost" }
    setmetatable(ghost, { __index = switch })
    ghost.fields = { base_url = "http://127.0.0.1:1" }
    ghost.device_network_id = "not-a-real-device"
    t.capability_handlers.refresh.refresh(driver, ghost, {})
    check(ghost.status == "offline", "unreachable device is marked offline")

    -- 6. Removal unsubscribes and cancels timers.
    t.lifecycle_handlers.removed(driver, contact)
    local list = client.get("http://127.0.0.1:8800/api/devices")
    local subs
    for _, d in ipairs(list) do if d.id == contact.device_network_id then subs = d.subscribers end end
    check(subs == 0, "removed -> device has no subscribers (got " .. tostring(subs) .. ")")
    check(next(contact.thread.timers) == nil, "removed -> timers cancelled")
  end)
  if not ok then failures = failures + 1; print("ERROR " .. tostring(err)) end
  print(string.format("\n%d passed, %d failed", passes, failures))
  os.exit(failures == 0 and 0 or 1)
end

dofile("src/init.lua")
