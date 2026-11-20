# Changes

Dated notes on significant fixes, in the order they happened. The commit log has
the diff; this file keeps the *why* and what a hub actually did.

## 2026-11-19 — "Scan for nearby devices" found nothing on a real hub

### What the hub logged

```
05:47:57.11 DEBUG ssdp: ee583166-… at http://192.0.2.10:8801 (from 192.0.2.10)
05:47:57.15 DEBUG ssdp: 4b8d95c3-… at http://192.0.2.10:8805 (from 192.0.2.10)
05:47:59.46 ERROR discovery thread encountered error:
            [string "discovery.lua"]:86: attempt to call a nil value (method 'match')
```

All five devices answered SSDP. No device was ever created.

### Root cause

`discovery.lua` assumed one shape for the mDNS TXT records that `st.mdns` hands
back:

```lua
for _, entry in ipairs((event.txt or {}).text or {}) do
  id = id or entry:match("^id=(.+)$")   -- line 86: entry was a table, not a string
end
```

On this hub firmware a TXT entry is a **table**, not an `"id=…"` string, so
`entry:match` didn't exist and the call raised.

The location mattered more than the type. That loop lives in `mdns_search()`,
which `search_all()` calls **before** it returns anything:

```lua
for id, base in pairs(M.search_all()) do   -- raises here, inside the argument
  … driver:try_create_device(…)            -- never reached
end
```

So the five SSDP answers were already collected and got thrown away with the
exception. One optional protocol failing took the mandatory one down with it, and
the hub's discovery thread died — which is why the app showed nothing at all.

The path had no test coverage: the hub-less harness has no `st.mdns`, so
`pcall(require, "st.mdns")` always failed and `mdns_search` returned early before
parsing anything.

### The fix

| File | Change |
|---|---|
| `driver/src/discovery.lua` | `txt_value()` accepts every TXT shape: flat map (`{id="…"}`), list of `"id=…"` strings, list of `{key=,value=}` tables, with or without the `.text` wrapper. Per-event `pcall`, `pcall` around `mdns.discover`, `pcall` around the mDNS side inside `search_all`, and `pcall` around each round in `handler`. New `describe()` logs `mdns: response shape {…}` once so the next hub's real structure is readable from logcat. Plus `socket.sleep(1)` per round so a fast-returning search can't spin the loop. |
| `driver/tests/mocks/st/mdns.lua` | New mock for `st.mdns`. `_G.MDNS_MOCK` picks the reply: service events, an error return, or a raise. |
| `driver/tests/run_harness.lua` | Section 0: the three TXT shapes must parse; malformed `host_info`, an IPv6 address and an event without `id=` must be skipped; a raising or erroring `discover` must yield `{}` without an error. |
| `docs/PROTOCOL.md` | §1 mDNS states the driver assumes nothing about the record shape, and that SSDP is the reliable path. |
| `docs/GUIDE.md` | §11: two new rows — "logcat shows `ssdp:` answers but no devices", and "devices appear with an IP the hub is not on". |
| `README.md`, `AGENTS.md` | Status: first real-hub contact recorded, then verified after this fix. |

The principle taken from it: an optional discovery protocol must never be able to
cost the mandatory one its results.

### Testing

| Check | Result |
|---|---|
| `luac -p` on the changed Lua | clean |
| Real `discovery.lua` mDNS parser under host Lua 5.5 with stubbed `st.mdns`, `log`, `cosock`, `http_client` | 9/9: three TXT shapes parse, a string port is coerced, malformed + IPv6 + id-less events are skipped, a raising `discover` yields `{}`, an error return is logged, an empty list is fine |
| Devices on the host: `py_compile`, `probe.py discover` and `command` | clean, 5 devices, `switch on` → `{"switch": "on"}` |
| `scripts/test-driver.sh`, `scripts/test-devices.sh` | Not runnable on the network used for the hub test (see environment notes below). Run afterwards on another machine before merging: 19/19 driver checks, 5/5 device checks. Both also run in CI on `main`. |
| On the hub | Verified 2026-11-19 by the project owner with this build: the scan found and created the devices, commands worked, and all five device types delivered state changes live — so `push_server.lua` works on a hub, and the hub's random push port is reachable from the LAN. The success logcat was not kept, so the exact `mdns: response shape {…}` content is still unknown — capture it next time and add it here. |

### Environment problems found on the way (not code bugs)

Each of these looked like a driver bug for a minute, so they're written down.

1. **Some networks block Docker's downloads.** On a restricted network,
   `docker pull` and package downloads inside containers can fail (timeouts, or
   `SSL: certificate verify failed`), so the test images can't be built there.
   Run the tests on another network, or let CI run them. If you must test on
   such a network, see the last-resort host setup in AGENTS.md.
2. **A second network interface breaks discovery.** With one adapter on the hub's
   subnet and another as the default route, everything worked — the devices answer
   each SSDP request with the address of the interface facing the requester. When
   the first adapter later moved to a different subnet, `logcat` failed with
   `Connection to <hub-ip>:9495 timed out`, `arp` had no entry for the hub and
   `route -n get` pointed at the default gateway: the laptop had simply left the
   hub's network.
   Nothing in the driver was wrong. Use `--advertise-ip` to pin the advertised
   address when a machine has several interfaces, and check
   `route -n get <hub-ip> | grep -E 'interface|gateway'` before blaming the hub.
3. **`Request to API failed with status undefined`** from
   `smartthings edge:drivers:package … --install` meant *no credentials in that
   shell*: no token in the environment and no CLI config directory anywhere. The
   CLI sat at `- Logging In`, and a request sent without a token gets no HTTP
   status — hence `undefined` rather than `401`. CLI 3.0.x has **no `login`
   command**; export a fresh personal access token
   (`export SMARTTHINGS_TOKEN=…`, valid 24 h) and confirm with
   `smartthings locations`. `edge:drivers:logcat` needs none of it because it
   talks to the hub directly — that asymmetry (cloud commands fail, logcat works)
   is the fingerprint of a missing token.
4. **`-I, --install` is a real flag** on `edge:drivers:package`: it implies
   `--assign` and prompts for channel and hub. With the hub id known the whole
   chain is one command,
   `smartthings edge:drivers:package driver --hub <hub-id>`.

### Verified on a real hub with this build

- Discovery finds the devices and `try_create_device` is accepted.
- Commands from the app reach the device and the reported state comes back.
- Pushes: every device type updated the app live, so the hub's push port chosen
  at `bind(*, 0)` is reachable from the LAN and the `init` re-subscribe works.

### Still unverified on a real hub

- Which TXT shape the hub firmware actually returns.
- Relocation: a device that changes IP or port while installed.
- Offline detection and `removed` cleanup with real devices.
- The temperature profile's missing `categories`, the hard-coded `unit = "C"` in
  `events.lua`, and the absence of a test that keeps the protocol constants equal
  across `config.lua`, `virtual_device.py`, `probe.py` and `PROTOCOL.md`.
