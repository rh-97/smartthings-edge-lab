# Building a SmartThings Edge LAN driver, step by step

This guide walks through the whole project: what each piece does, how to run the virtual devices, how to check the driver without a hub, and how to put it on a real hub and see the devices in the SmartThings app.

- [1. The big picture](#1-the-big-picture)
- [2. What you need](#2-what-you-need)
- [3. Run the virtual devices](#3-run-the-virtual-devices)
- [4. Test the driver without a hub](#4-test-the-driver-without-a-hub)
- [5. Set up the SmartThings CLI](#5-set-up-the-smartthings-cli)
- [6. Put the driver on your hub](#6-put-the-driver-on-your-hub)
- [7. Add the devices in the SmartThings app](#7-add-the-devices-in-the-smartthings-app)
- [8. Things to try](#8-things-to-try)
- [9. Using your phone](#9-using-your-phone)
- [10. A tour of the driver code](#10-a-tour-of-the-driver-code)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Where to take it next](#12-where-to-take-it-next)

---

## 1. The big picture

```
 ┌───────────────────┐        ┌─────────────────────────────────────────┐
 │  SmartThings app  │◄──────►│  SmartThings cloud                      │
 └───────────────────┘        └─────────────────┬───────────────────────┘
                                                │  (SmartThings handles this)
 ┌──────────────────────────────────────────────▼──────────────────────────┐
 │  Hub                                                                    │
 │   Edge runtime (Samsung's firmware, untouched)                          │
 │     └── YOUR DRIVER  driver/src/*.lua                                   │
 │           • discovery: SSDP / mDNS search  →  try_create_device         │
 │           • commands from the app          →  POST /command             │
 │           • push server   ◄── POST /push ──┐                            │
 └──────────────────────────────┬─────────────┼────────────────────────────┘
                                │ your LAN    │
                 HTTP + SSDP    │             │  (docs/PROTOCOL.md: you design this)
 ┌──────────────────────────────▼─────────────┴────────────────────────────┐
 │  Your laptop: virtual-device/virtual_device.py                          │
 │     Lab Switch :8801   Lab Dimmer :8802   Lab Contact :8803   ...       │
 │     Dashboard  :8800   ◄── open it in your phone's browser too          │
 └─────────────────────────────────────────────────────────────────────────┘
```

There are two programs and one protocol:

| Piece | Runs on | Language | Job |
|---|---|---|---|
| **Driver** (`driver/`) | the hub, inside Edge | Lua 5.3 | Finds devices, creates them in SmartThings, turns app commands into HTTP calls and device updates into SmartThings events |
| **Virtual devices** (`virtual-device/`) | your laptop (or Android phone) | Python, standard library only | Pretend to be real hardware: answer discovery, keep state, accept commands, push changes |
| **Protocol** (`docs/PROTOCOL.md`) | | JSON over HTTP, plus SSDP/mDNS | The contract between them |

The driver never talks to the SmartThings cloud API directly. It uses the Edge framework's functions (`emit_event`, `try_create_device`, and so on), and the hub syncs with the cloud. That's why this costs nothing: Edge drivers, the CLI's Edge commands and running devices on a hub are free.

### Words you'll see

- **Capability**: a standard SmartThings feature with attributes and commands, such as `switch` (attribute `switch`: on/off; commands `on`, `off`) or `contactSensor` (attribute `contact`: open/closed). The app draws the UI from these, and routines use them. You don't design UI.
- **Profile** (`driver/profiles/*.yml`): which capabilities a device type has. The driver picks one when it creates a device.
- **device_network_id**: your driver's identifier for a device. Here it's the device's UUID, so it survives IP changes.
- **Channel**: your personal "store" for drivers. You upload the driver to it, enroll your hub in it, then install from it.
- **cosock**: the hub's cooperative networking library. Edge runs one OS thread with many coroutines, so every socket call must go through cosock, or one slow device would freeze the others.

## 2. What you need

| For | You need |
|---|---|
| Virtual devices | Your Mac's built-in `python3` (comes with Xcode's command-line tools). Nothing to install. |
| Hub-less driver tests | Docker |
| Real hub | A SmartThings hub (Station, Aeotec hub, or a Samsung TV/fridge with one built in) on the **same network** as your laptop, plus your SmartThings account |
| CLI | Docker, and a personal access token (section 5) |

**Python environment:** the project uses no Python packages, so plain `python3` is enough and nothing is installed. If dependencies are ever added, they will live in a project-local `.venv/` managed by [uv](https://docs.astral.sh/uv/) (`uv run virtual-device/virtual_device.py`), never in your global Python. AGENTS.md (rule 11) has the details.

**Linux vs macOS for the virtual devices:** the hub finds devices with multicast network traffic (SSDP, mDNS).
- **Linux:** Docker can put a container directly on your network (`--network host`), so the devices run fully isolated in Docker with `scripts/run-devices.sh`.
- **macOS:** Docker containers run inside a hidden Linux VM that multicast from your real network never reaches. Run the script with the Mac's own `python3` instead. It uses only Python's standard library and installs nothing, so that's safe.

Everything else (CLI, tests) runs in Docker on both.

## 3. Run the virtual devices

**On Linux** (recommended: everything stays in Docker):

```bash
cd smartthings-edge-lab
scripts/run-devices.sh
```

All arguments go through to `virtual_device.py`, for example `scripts/run-devices.sh --devices switch,contact -v`. Device ids and state are kept in `.data/`. Stop with Ctrl+C, or `docker stop stlab-devices`.

If the machine has a firewall (`ufw`, `firewalld`), allow the hub in:

```bash
sudo ufw allow 1900/udp && sudo ufw allow 8800:8805/tcp      # Ubuntu/Debian with ufw
# firewalld: sudo firewall-cmd --add-port=1900/udp --add-port=8800-8805/tcp
```

In Docker, devices are found over SSDP only, without Bonjour. That's all the driver needs.

**On macOS:**

```bash
cd smartthings-edge-lab
python3 virtual-device/virtual_device.py
```

macOS may ask whether Python can accept incoming connections, or whether Terminal can find devices on your local network. Allow both, or the hub can't reach the devices.

Either way, you'll see something like:

```
10:02:11 Dashboard: http://192.168.0.224:8800  (open it on your phone too)
10:02:11   Lab Switch                   http://192.168.0.224:8801  id=9a64756d-...
10:02:11   Lab Dimmer                   http://192.168.0.224:8802  id=73bc9ceb-...
10:02:11   Lab Contact Sensor           http://192.168.0.224:8803  id=ec5a34e2-...
10:02:11   Lab Motion Sensor            http://192.168.0.224:8804  id=43d7be01-...
10:02:11   Lab Temperature Sensor       http://192.168.0.224:8805  id=18dd17b9-...
10:02:11 Discovery: SSDP on, mDNS dns-sd
```

Open the dashboard URL. Every device has controls: turn the switch on, drag the dimmer, open the door, trigger motion, change the temperature.

Useful options (`--help` for all):

```bash
python3 virtual-device/virtual_device.py --devices switch,switch,contact   # pick types, repeat for more
python3 virtual-device/virtual_device.py --base-port 9000                  # if 8800-8805 are taken
python3 virtual-device/virtual_device.py --name-prefix Desk                # "Desk Switch", ...
python3 virtual-device/virtual_device.py -v                                # log every request
```

The options work the same with `scripts/run-devices.sh` on Linux.

Device ids and states are saved in `virtual-devices.json` (in `.data/` with `run-devices.sh`), so the same devices come back after a restart. Delete the file to start fresh. SmartThings will then see them as new devices.

### Check them without a hub

`probe.py` does what the driver does, from your laptop. Run it in a second terminal:

```bash
python3 virtual-device/probe.py discover                          # SSDP search + /info + /state
python3 virtual-device/probe.py command "lab switch" switch on
python3 virtual-device/probe.py command dimmer switchLevel setLevel 30
python3 virtual-device/probe.py watch                             # subscribe and print every push
```

With `watch` running, flip things on the dashboard and watch the pushes arrive. That's exactly what the hub will receive.

## 4. Test the driver without a hub

```bash
scripts/test-driver.sh
```

This builds a small Docker image with Lua 5.3, LuaSocket, cosock and dkjson (the same libraries the hub uses), starts the virtual devices inside it, and runs **the real driver code** against them. Only the `st.*` framework is faked (`driver/tests/mocks/`). It checks discovery, device creation, commands, push events, relocation after an address change, offline detection and removal:

```
PASS discovery created 5 devices (got 5)
PASS switch.on -> switch event 'on'
PASS push delivered contact 'open'
PASS refresh relocated a moved device
...
13 passed, 0 failed
```

Run it after every driver change. It's much faster than reinstalling on the hub.

## 5. Set up the SmartThings CLI

`scripts/st` runs the official CLI (`@smartthings/cli`) in Docker. Its Edge commands are free.

1. Create a personal access token at <https://account.smartthings.com/tokens>. For a quick start, tick all scopes. New tokens expire after 24 hours, so make a new one when it stops working.
2. Put it in your shell. Don't commit it.

   ```bash
   export SMARTTHINGS_TOKEN=paste-token-here
   ```

3. Check it works:

   ```bash
   scripts/st locations
   scripts/st devices --type=HUB      # note your hub's device id
   ```

The first run downloads the CLI, so it's slow. Later runs reuse the Docker volume.

**Already have the CLI installed on your machine?** A host-installed `smartthings` (3.0.x) works the same: leave `scripts/st ` off every command in this guide, and export `SMARTTHINGS_TOKEN` the same way. Version 3.0.x has **no `login` command**, so an exported token is the only way to give it credentials (§11 shows the error a missing token produces). The Docker wrapper is still the recommended route, since it installs nothing. Use a host install only on a network where Docker can't download images.

## 6. Put the driver on your hub

### Before you start

- **Account:** the hub must be in a SmartThings location your account controls, as owner or invited member. You can only install drivers from your channel on hubs you control. If you borrow a hub (for example at work), get permission and add it to a location on your personal account, or have its owner invite you.
- **Network:** the hub and the laptop running `virtual_device.py` must be on the same network and subnet, with device-to-device traffic allowed. Office and guest Wi-Fi often isolate clients or block multicast. A travel router or phone hotspot that both join avoids this. Some hubs need Ethernet, so a travel router with a LAN port is the safest choice.
- **Laptop:** company-managed laptops may block incoming connections. Check with `probe.py discover` from a second machine if you can.
- **Token:** create it the same day (it lasts 24 hours).

You can do the upload and channel steps (1–2 below) at home. Only enroll and install need the hub.

### Steps

Run these from the project root. Commands without arguments prompt you to choose from a list.

```bash
# 1. Package the driver folder and upload it to your account.
#    Note the "Driver Id" and "Version" it prints.
scripts/st edge:drivers:package driver

# 2. Create your channel (once). Note the channel id.
scripts/st edge:channels:create

# 3. Put the uploaded driver version in the channel.
scripts/st edge:channels:assign

# 4. Enroll your hub in the channel (once).
scripts/st edge:channels:enroll

# 5. Install the driver on the hub.
scripts/st edge:drivers:install
```

After a code change, one command uploads, assigns and installs the new version:

```bash
scripts/st edge:drivers:package driver --install     # prompts for channel and hub
```

The hub picks up the new version within a minute or two. To check that the package builds without uploading anything: `scripts/st edge:drivers:package driver --build-only build/driver.zip`.

### Watch the driver's logs live

```bash
scripts/st edge:drivers:logcat --hub-address=<hub-ip> -a
```

Find the hub's IP in your router's device list. The first time, the CLI asks you to trust the hub's certificate. Leave this running while you work: every `log.info` in the driver shows up here, including `push: listening on port ...` when the driver starts.

## 7. Add the devices in the SmartThings app

1. Keep `virtual_device.py` running.
2. In the SmartThings app: **+ → Add device → Scan for nearby devices**.
3. The hub runs every installed driver's discovery handler. In logcat you'll see `discovery: creating "Lab Switch" (switch) at http://...`.
4. Your five devices appear in the app. Give it a few seconds each.

This is the onboarding flow, from the hub's side: discovery handler → `try_create_device` → `added` lifecycle → subscribe + first refresh.

## 8. Things to try

- **App → device:** tap Lab Switch in the app. The dashboard flips within a second and the device log says `command: {"switch": "on"}`.
- **Device → app:** open the door on the dashboard (or your phone). The app shows "Open" without refreshing: that's the push path.
- **A local automation:** in the app, create a routine: *If Lab Contact Sensor opens → turn on Lab Dimmer at 40%*. Open the door on the dashboard and watch the dimmer turn on. Both devices are on the same hub, so the routine can run entirely on the hub without the cloud.
- **Offline handling:** stop `virtual_device.py`. Within about a minute (the poll interval) the devices show as offline in the app. Start it again and they come back.
- **Address change:** restart the script with `--base-port 9100`. The ids stay the same, so the driver's `relocate()` finds the devices at their new ports on the next failed call.

## 9. Using your phone

| Option | How | Notes |
|---|---|---|
| **Phone as remote control** (easiest) | Open the dashboard URL (`http://<laptop-ip>:8800`) in your phone's browser | The devices run on the laptop; the phone is the "physical world" flipping sensors |
| **Android phone as the device** | Install [Termux](https://termux.dev), `pkg install python`, copy `virtual_device.py` over, run it | Same script, real separate hardware on your Wi-Fi |
| **iPhone as the device** | A small SwiftUI app that serves the same HTTP API and advertises `_stlab._tcp` over Bonjour | Python on iOS can't receive SSDP multicast, and Apple restricts multicast for apps without a special entitlement. Bonjour advertising is allowed with only the Local Network permission, and the driver also searches mDNS. A good next project for an iOS developer. |

## 10. A tour of the driver code

```
driver/
├── config.yml              package name, key, permissions (lan + discovery)
├── profiles/*.yml          one profile per device type: its capabilities
└── src/
    ├── init.lua            the Driver: lifecycle + capability handlers, wiring
    ├── discovery.lua       SSDP and mDNS search, try_create_device
    ├── http_client.lua     JSON over HTTP with cosock (non-blocking)
    ├── push_server.lua     small HTTP server that receives device pushes
    ├── events.lua          device JSON -> SmartThings capability events
    └── config.lua          constants (search target, intervals, profiles)
```

### The Driver template (`init.lua`)

```lua
local driver = Driver("smartthings-edge-lab", {
  discovery = discovery.handler,                      -- "Scan nearby" pressed
  lifecycle_handlers = { added = ..., init = ..., removed = ... },
  capability_handlers = {
    [caps.switch.ID] = {
      [caps.switch.commands.on.NAME]  = send_command, -- user tapped On
      [caps.switch.commands.off.NAME] = send_command,
    },
    ...
  },
})
driver:run()                                          -- hand control to Edge
```

Every handler gets `(driver, device, command)`. `command.capability`, `command.command` and `command.args` map directly onto the device's `POST /command` body.

### Lifecycle

| Event | When | What this driver does |
|---|---|---|
| `added` | right after `try_create_device` succeeds | Save the device URL (`set_field(..., {persist = true})`), subscribe for pushes, first refresh |
| `init` | every time the driver starts, for every existing device | Subscribe again (the push port changed), schedule polling |
| `removed` | user deleted the device | Unsubscribe, cancel timers |

### Talking to the outside world

- **Commands:** `http_client.lua` wraps `socket.http` with `cosock.asyncify`, so the request waits without blocking other devices.
- **Updates:** two paths. Pushes arrive at `push_server.lua` and become events right away. A poll every 60 s (`device.thread:call_on_schedule`) is the safety net and the health check (`device:online()` / `device:offline()`).
- **Events:** `events.lua` is the only file that knows both the device's JSON and SmartThings' capability names, for example `caps.contactSensor.contact.open()`. To support a new kind of device, you start here.

### Edge rules this code follows

- Only `bind(*, 0)` is allowed: the OS picks the port. Hence the re-subscribe in `init`.
- Use cosock sockets everywhere. A blocking call would stall the whole driver.
- Identify devices by something stable (`device_network_id` = the UUID), never by IP.

## 11. Troubleshooting

| Symptom | Check |
|---|---|
| `probe.py discover` finds nothing | Is `virtual_device.py` running? Did you allow Python's incoming connections in the macOS prompt? Is a VPN on? |
| The hub finds nothing, but probe does | The machine and hub must be on the same network and subnet. Guest Wi-Fi and "AP/client isolation" block device-to-device traffic. On macOS, check System Settings → Privacy & Security → Local Network for your terminal app. On Linux, check the firewall (§3). Run probe from a *second* machine: probe on the same machine succeeds even when the firewall blocks everyone else. |
| Logcat shows `ssdp:` answers from your devices but no devices appear | The scan died after SSDP. Look for `discovery thread encountered error` or `discovery: round failed` right after those lines: one bad mDNS reply used to throw away every SSDP answer. Since 2026-11-19 a bad round is logged and the scan continues, and `mdns: response shape ...` shows what the hub actually sent. |
| Devices appear in logcat as `http://<ip>:8801` with an IP the hub is not on | The laptop picked the wrong network interface for the address it advertises (VPN, or Wi-Fi plus another adapter). Start it with `python3 virtual-device/virtual_device.py --advertise-ip <the-ip-on-the-hub's-subnet>`; `ifconfig` shows which is which. |
| `run-devices.sh` says it needs Linux | On macOS, use `python3 virtual-device/virtual_device.py` (§2 explains why). |
| A cloud command says `Request to API failed with status undefined`, or sits at `- Logging In` | No token in this shell. 3.0.x has no `login` command: `export SMARTTHINGS_TOKEN=…` with a token made today, then check with `smartthings locations`. `edge:drivers:logcat` working at the same time is normal — it connects to the hub, not to the cloud. |
| `logcat`: `Connection to <hub-ip>:9495 timed out` | The laptop is not on the hub's network. Check `route -n get <hub-ip>`: it must name an interface, not send you to the default gateway. Two Wi-Fi/VPN adapters on a laptop make this easy to hit. |
| `run-devices.sh`: port 1900 or 8800 already in use | Another SSDP/DLNA service (e.g. minidlna) is usually fine, since the script shares port 1900. For 8800–8805, pass `--base-port 9000`. |
| Devices created but never update from the dashboard | Look for `subscriber added` in the device log. If it's missing, the driver couldn't reach the device. If pushes fail, the laptop can't reach the hub's push port (firewall). The 60 s poll still keeps things roughly in sync. |
| Nothing in logcat | Is the driver installed (`scripts/st edge:drivers:installed`)? Is the hub IP right? |
| CLI says unauthorized | The token has expired (24 h). Make a new one. |
| `Could not open a port` | Something else uses 8800–8805. Use `--base-port`. |

## 12. Where to take it next

Ordered roughly by effort:

1. **Add a device type**, for example a `lock` or `button`. Add it to `TYPES` in `virtual_device.py`, add a profile in `driver/profiles/`, map it in `config.lua` `PROFILES`, translate its state in `events.lua`, add handlers for its commands in `init.lua`, and extend the test harness.
2. **Device settings in the app:** add `preferences` to a profile (for example the poll interval) and handle the `infoChanged` lifecycle event.
3. **Health and resilience:** exponential back-off when a device is offline, and remembering the last state across hub reboots.
4. **iPhone virtual device:** a SwiftUI app speaking `docs/PROTOCOL.md`, advertised over Bonjour. It shows your iOS skills and the driver's mDNS path.
5. **Real hardware:** ESP32 firmware that implements the same protocol. The driver doesn't change at all, which is the point of having a protocol.
6. **Official unit tests:** SmartThings publishes its Edge Lua libraries and a test framework alongside the [SmartThingsEdgeDrivers](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers) repo. They could replace the mocks in `driver/tests/mocks/`.

## References

- [LAN Edge driver development guide](https://developer.smartthings.com/docs/devices/hub-connected/lan)
- [Driver components and structure](https://developer.smartthings.com/docs/devices/hub-connected/driver-components-and-structure)
- [mDNS service discovery (`st.mdns`)](https://developer.smartthings.com/docs/edge-device-drivers/mdns.html)
- [SmartThings sample drivers](https://github.com/SmartThingsDevelopers/SampleDrivers) (see `lightbulb-lan-esp8266`)
- [SmartThings CLI](https://developer.smartthings.com/docs/sdks/cli/introduction)
