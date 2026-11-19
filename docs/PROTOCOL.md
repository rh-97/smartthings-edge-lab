# Device protocol

The contract between the Edge driver (on the hub) and a device on the LAN. I designed it for this project; SmartThings doesn't define it. Any device that follows it can be added through the driver: the Python virtual devices, an ESP32 firmware, or an iPhone app.

All bodies are JSON. Every device has a stable `id` (a UUID), which the driver uses as the SmartThings `device_network_id`. IPs and ports may change; the id must not.

## 1. Discovery

### SSDP (required)

The driver multicasts to `239.255.255.250:1900`:

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 2
ST: urn:smartthings-edge-lab:device:VirtualDevice:1
```

Each device answers by unicast to the sender:

```
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
EXT:
LOCATION: http://<device-ip>:<port>/info
SERVER: <anything>
ST: urn:smartthings-edge-lab:device:VirtualDevice:1
USN: uuid:<id>::urn:smartthings-edge-lab:device:VirtualDevice:1
```

The device must also answer `ST: ssdp:all`. The base URL is `LOCATION` without `/info`.

### mDNS / Bonjour (optional)

Service type `_stlab._tcp`, domain `local`, with TXT records `id=<id>` and `type=<type>`. The driver uses it when the hub provides `st.mdns`. A phone app can be found this way without sending multicast traffic itself.

## 2. HTTP API (on the device)

| Method | Path | Body | Reply |
|---|---|---|---|
| GET | `/info` | | `{api, id, name, type, manufacturer, model, firmware, capabilities[], baseUrl}` |
| GET | `/state` | | state object (see below) |
| POST | `/command` | `{capability, command, args}` | `{state}`, the state *after* the command |
| POST | `/subscribe` | `{url, ttl}` | `{ttl, state}`; ttl is clamped to 60–3600 s |
| POST | `/unsubscribe` | `{url}` | `{}` |
| POST | `/simulate` | attributes to set, e.g. `{"contact":"open"}` | `{state}`. Testing only. |

Errors use status 400 or 404 with `{"error": "..."}`.

### Types and state

| `type` | Capabilities | State | Commands |
|---|---|---|---|
| `switch` | switch, refresh | `{"switch":"on"\|"off"}` | `switch.on`, `switch.off` |
| `dimmer` | switch, switchLevel, refresh | `{"switch":..., "level":0-100}` | as switch, plus `switchLevel.setLevel {level}` (level > 0 turns it on) |
| `contact` | contactSensor, refresh | `{"contact":"open"\|"closed"}` | none (sensor) |
| `motion` | motionSensor, refresh | `{"motion":"active"\|"inactive"}` | none (sensor) |
| `temperature` | temperatureMeasurement, relativeHumidityMeasurement, refresh | `{"temperature":°C, "humidity":%}` | none (sensor) |

`refresh.refresh` is accepted by every type and returns the current state.

## 3. Push (device → hub)

After `/subscribe`, the device POSTs every state change to the subscriber's `url`:

```json
{ "id": "<device id>", "state": { "contact": "open" } }
```

The hub replies `200`. A device drops a subscriber after 3 failed pushes or when its ttl runs out. The driver renews every 5 minutes, and again after each restart, because Edge assigns the hub's listening port at random on every start.

## 4. Security

None. This is a LAN demo. Anyone on your network can control the virtual devices. Don't run them on networks you don't trust.
