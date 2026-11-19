# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Copilot, Cursor, ...) working in this repository. Humans: start with [README.md](README.md) and [docs/GUIDE.md](docs/GUIDE.md); this file is the short, rule-focused version.

## What this project is

A **real, installable SmartThings Edge LAN driver** (Lua, runs on a SmartThings hub) plus **software devices** (Python, run on a laptop or phone) that the driver discovers and controls over the local network. After installation, the devices appear in the real SmartThings app.

| Path | Role | Runs on |
|---|---|---|
| `driver/` | The Edge driver package uploaded with the SmartThings CLI. Only `config.yml`, `profiles/` and `src/` are packaged. | Hub (Lua 5.3, Edge runtime) |
| `driver/tests/` | Hub-less harness: real driver code + real cosock/LuaSocket, with `st.*` mocked | Docker |
| `virtual-device/virtual_device.py` | Software devices + web dashboard. Python **standard library only**. | Laptop / Android (Termux) |
| `virtual-device/probe.py` | Stand-in for the hub, for testing devices without one. Not used in production. | Laptop |
| `docs/PROTOCOL.md` | The driver ⇄ device contract. **Source of truth.** | |
| `docs/GUIDE.md` | Step-by-step guide for humans: concepts, install on a hub, troubleshooting | |
| `scripts/` | `st` (SmartThings CLI in Docker), `run-devices.sh` (devices in Docker, Linux), `test-driver.sh`, `test-devices.sh` | Host shell |

## Commands

```bash
scripts/test-devices.sh                 # virtual devices end to end (Docker)
scripts/test-driver.sh                  # driver vs virtual devices, no hub (Docker)
scripts/st edge:drivers:package driver --build-only build/driver.zip   # package builds? (no token needed)
scripts/run-devices.sh                  # run the devices for real on Linux (Docker, host network)
python3 virtual-device/virtual_device.py   # run the devices for real on macOS (host python3, see rule 7)
```

Run **both test scripts** after any change. Both must pass. CI (`.github/workflows/ci.yml`) runs them, the package build, and a Linux job that starts `run-devices.sh` and discovers the devices from outside the container.

## Rules

1. **Protocol changes touch four places at once:** `docs/PROTOCOL.md`, `driver/src/config.lua` (search target, mDNS service), `virtual-device/virtual_device.py` and `virtual-device/probe.py`. Keep the constants identical.
2. **Driver networking must go through cosock** (`cosock.socket`, `cosock.asyncify "socket.http"`). Plain blocking LuaSocket calls freeze every device on the hub.
3. **Edge only allows binding port 0.** Never hard-code a listening port in the driver. That's why the driver re-subscribes on every `init`.
4. **`device_network_id` is the device's UUID**, never an IP or URL. Addresses live in the persisted field `base_url` and may change.
5. **Use only Lua modules available on the hub:** `st.*`, `cosock`, `socket`, `ltn12`, `dkjson`, `log`. Don't add third-party Lua libraries to `driver/src/` without vendoring them and noting why.
6. **Virtual devices stay standard-library Python** (3.9+), so they run on any Mac, Linux box or Termux with nothing installed. If a Python dependency ever becomes unavoidable, see rule 11.
7. **Tooling runs in Docker**: CLI, Lua tests, Python tests, and on **Linux** the virtual devices too (`scripts/run-devices.sh`, which uses `--network host` so SSDP multicast reaches the container). The one exception is running the devices on **macOS**: Docker there runs in a VM that LAN multicast never reaches, so use the host's `python3 virtual-device/virtual_device.py`. `run-devices.sh` refuses to run on non-Linux hosts on purpose.
8. **Stay free and public:** use only Edge, the CLI's Edge commands, and public documentation. Don't call the paid SmartThings cloud API (OAuth API Access apps). Don't add anything from Samsung-internal sources.
9. **Never commit secrets.** The CLI reads `SMARTTHINGS_TOKEN` from the environment; keep it there. `virtual-devices.json` (local device ids and state) is git-ignored.
10. **Profiles are append-only once published:** SmartThings rejects a package update that removes a profile name. To change one, add a new `name` (e.g. `stlab-switch.v2`).
11. **Python packages go only into a project-local virtual environment managed by [uv](https://docs.astral.sh/uv/). Never install into the global or system Python.**
    - Never run `pip install`, `pip3 install`, `sudo pip`, `pip install --user` or `python3 -m pip install` against the host interpreter, and never `brew install` Python packages.
    - Declare dependencies in a `pyproject.toml` at the repo root with `uv add <package>`. uv creates `.venv/` in the project and writes `uv.lock`; commit both `pyproject.toml` and `uv.lock`, never `.venv/`.
    - Run Python on the host with `uv run <script>` (e.g. `uv run virtual-device/virtual_device.py`), which uses `.venv/` automatically. Don't activate or depend on any other environment.
    - Pin the interpreter with `uv python pin 3.12` (writes `.python-version`) so every machine uses the same version.
    - Inside Docker containers, already isolated, plain `python3` is fine, but install packages with `uv sync --frozen` from the same lock file so container and host match.
    - Today the project has **no** Python dependencies and no `pyproject.toml`. Prefer keeping it that way. Add one only when a dependency is truly needed, and update README.md, docs/GUIDE.md (§3) and this file in the same change.
    - If `uv` isn't installed, stop and ask the user. Don't fall back to pip or a global install.

## Adding a device type (checklist)

1. `virtual_device.py`: add an entry to `TYPES` (capabilities, initial state, what the dashboard may simulate). Handle its commands in `VirtualDevice.apply_command`, and add dashboard controls in `DASHBOARD_HTML` → `controls()`.
2. `driver/profiles/stlab-<type>.yml`: a new profile.
3. `driver/src/config.lua`: map the type in `PROFILES`.
4. `driver/src/events.lua`: translate its state into capability events.
5. `driver/src/init.lua`: add `capability_handlers` for its commands and its capability to `supported_capabilities`.
6. `driver/tests/mocks/st/capabilities.lua` and `mocks/st/driver.lua` (`PROFILE_CAPS`): mock the new capability. Then add a check in `driver/tests/run_harness.lua`.
7. `docs/PROTOCOL.md`: add a row to the types table.
8. Run both test scripts.

## Verification status

- Virtual devices, probe and hub-less driver tests: verified (Docker, CI).
- Package build with the official CLI (`@smartthings/cli` 3.0.1): verified.
- **On a real hub: not yet verified.** If you get hub logs (`scripts/st edge:drivers:logcat --hub-address=<ip> -a`), the most likely places for fixes are `discovery.lua` (SSDP/mDNS details) and `push_server.lua` (hub IP and port, cosock server). Update the "Status" section of README.md when verified.

## Style

- Lua: 2-space indent, `local` everything, one module per file returning a table, log with `log.info/warn/debug`.
- Python: PEP 8, type hints, no dependencies.
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
