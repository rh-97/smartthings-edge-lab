# smartthings-edge-lab

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

A **SmartThings Edge LAN driver** you install on a real SmartThings hub, plus **software devices** that run on a laptop or phone and show up in the real SmartThings app. Together they show the full path a new device takes into SmartThings: discovery on the local network, creation on the hub, commands from the app, and live updates back. You don't need any smart-home hardware except a hub.

```
SmartThings app (phone) ⇄ SmartThings cloud ⇄ Hub ── this driver (Lua)
                                                        │  your Wi-Fi: SSDP/mDNS + HTTP
                                                        ▼
                                  laptop: virtual_device.py (switch, dimmer, sensors…)
```

Everything here is free. Edge drivers and the CLI's Edge commands don't need the paid SmartThings API plan.

## Is this a simulation?

No. Only the hardware is replaced:

| Piece | What it is |
|---|---|
| **Driver** (`driver/`) | A genuine Edge driver package. You upload it with the official SmartThings CLI, install it on your hub, and it runs there like any community driver. |
| **Virtual devices** (`virtual-device/virtual_device.py`) | Real network devices without hardware. A program on your laptop answers the hub's network search, accepts commands and pushes changes, exactly as a Wi-Fi gadget would. In the SmartThings app they look like any other device, and routines work with them. |
| **`probe.py`** | A testing tool that stands in for the hub, so you can check the devices before you have one. It does what the driver does: search the network, send a command, listen for updates. If `probe.py discover` finds your devices, the hub will too. Not used once you have a hub. |
| **Tests** (`scripts/test-*.sh`) | Automated checks that run in Docker. `test-driver.sh` runs the real driver code against the devices with only SmartThings' framework (`st.*`) faked. |

## What it does

- **Five device types:** switch, dimmer, contact sensor, motion sensor, temperature/humidity sensor.
- **Discovery:** the driver finds devices with SSDP and mDNS/Bonjour when you tap *Scan for nearby devices* in the app, then creates each one with the right profile.
- **Commands:** taps in the app become HTTP calls; the driver reports back the state the device confirms.
- **Live updates:** devices push every change to a small HTTP server inside the driver. A 60-second poll is the safety net and the online/offline check.
- **Moved devices:** devices are identified by UUID, not IP, so the driver finds them again if their address or port changes.
- **Dashboard:** a mobile-friendly page (`http://<laptop-ip>:8800`) to open the "door", trigger motion or change the temperature from your phone.

## Quick start (no hub needed)

Requirements: macOS or Linux with `python3` (3.9+), and Docker for the tests and the CLI.

```bash
# 1. Start the devices and dashboard
python3 virtual-device/virtual_device.py

# 2. In another terminal: find and control them the way the hub will
python3 virtual-device/probe.py discover
python3 virtual-device/probe.py command "lab switch" switch on
python3 virtual-device/probe.py watch          # prints every pushed change

# 3. Automated checks (Docker)
scripts/test-devices.sh
scripts/test-driver.sh
```

## Running it on a real hub

The full walkthrough is in **[docs/GUIDE.md](docs/GUIDE.md)**, sections 5–8. In short:

**Before you start**
- The hub must be in a SmartThings **location your account controls** (owner or member). Drivers install from your channel to hubs you control.
- **The hub and laptop must be on the same network**, with device-to-device traffic allowed. Guest or office Wi-Fi often blocks this; a travel router or phone hotspot shared by both is the reliable fix.
- A personal access token from <https://account.smartthings.com/tokens>, exported as `SMARTTHINGS_TOKEN`. It expires after 24 hours.

**Steps**

```bash
scripts/st edge:drivers:package driver      # upload the driver to your account
scripts/st edge:channels:create             # once: your own driver channel
scripts/st edge:channels:assign             # put the driver in the channel
scripts/st edge:channels:enroll             # once: enroll your hub in the channel
scripts/st edge:drivers:install             # install on the hub
python3 virtual-device/virtual_device.py    # start the devices
# SmartThings app: + → Add device → Scan for nearby devices
scripts/st edge:drivers:logcat --hub-address=<hub-ip> -a   # live driver logs
```

`scripts/st` runs the official SmartThings CLI in Docker, so nothing gets installed on your machine. Commands without arguments prompt you to choose from a list.

## Layout

```
driver/                 Edge driver package (config.yml, profiles/, src/ are uploaded)
  src/init.lua          Driver template: lifecycle + capability handlers
  src/discovery.lua     SSDP + mDNS search, try_create_device
  src/http_client.lua   JSON over HTTP with cosock
  src/push_server.lua   receives device pushes on the hub
  src/events.lua        device state → SmartThings capability events
  src/config.lua        constants shared with the protocol
  profiles/             one profile per device type
  tests/                hub-less harness, st.* mocks, Dockerfile
virtual-device/
  virtual_device.py     the devices + dashboard (standard-library Python)
  probe.py              stand-in hub for testing
docs/
  GUIDE.md              step-by-step guide, code tour, troubleshooting
  PROTOCOL.md           driver ⇄ device protocol
scripts/
  st                    SmartThings CLI in Docker
  test-devices.sh       virtual devices end to end
  test-driver.sh        driver vs devices, no hub
AGENTS.md               rules and checklists for AI coding agents (CLAUDE.md points here)
```

## Status

| | |
|---|---|
| Virtual devices, probe, hub-less driver tests | ✅ verified, run in CI |
| Driver package builds with `@smartthings/cli` 3.0.1 | ✅ verified, run in CI |
| Install and run on a real hub | ⏳ not yet verified |

## Contributing / extending

- Humans: see [docs/GUIDE.md § 12](docs/GUIDE.md#12-where-to-take-it-next) for ideas, and [AGENTS.md](AGENTS.md#adding-a-device-type-checklist) for the checklist when adding a device type.
- AI agents: read [AGENTS.md](AGENTS.md) first.

## Disclaimer

Personal project, built only on SmartThings' public developer documentation and tools. Not affiliated with or endorsed by Samsung or SmartThings.

## License

MIT
