-- Constants shared by the driver. Must match virtual-device/virtual_device.py
-- and docs/PROTOCOL.md.
return {
  -- Discovery
  SSDP_ADDR = "239.255.255.250",
  SSDP_PORT = 1900,
  SEARCH_TARGET = "urn:smartthings-edge-lab:device:VirtualDevice:1",
  MDNS_SERVICE = "_stlab._tcp",
  MDNS_DOMAIN = "local",
  DISCOVERY_WINDOW = 3, -- seconds to collect SSDP answers per search

  -- Talking to devices
  HTTP_TIMEOUT = 5,       -- seconds
  POLL_INTERVAL = 60,     -- seconds between /state polls (health check + safety net)
  SUBSCRIBE_TTL = 900,    -- seconds a push subscription lasts on the device
  RESUBSCRIBE_INTERVAL = 300,

  -- Device type (from GET /info) -> profile name in profiles/*.yml
  PROFILES = {
    switch = "stlab-switch.v1",
    dimmer = "stlab-dimmer.v1",
    contact = "stlab-contact.v1",
    motion = "stlab-motion.v1",
    temperature = "stlab-temperature.v1",
  },

  -- device:set_field keys
  FIELD_BASE_URL = "base_url",
  FIELD_SCHEDULED = "scheduled",
}
