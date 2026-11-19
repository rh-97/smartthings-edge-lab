#!/usr/bin/env python3
"""Virtual LAN devices for the smartthings-edge-lab Edge driver.

Runs one or more software-only devices (switch, dimmer, contact, motion,
temperature) on this machine. Each device:

  * answers SSDP M-SEARCH requests so the hub's driver can discover it,
  * optionally advertises itself over mDNS/Bonjour (_stlab._tcp),
  * serves a small JSON HTTP API (/info, /state, /command, /subscribe, ...),
  * pushes every state change to the hubs that subscribed to it.

A dashboard (default http://<this-machine>:8800) lets you flip sensors and
switches from any browser, including your phone's.

Standard library only: no pip install needed. See docs/PROTOCOL.md.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
SEARCH_TARGET = "urn:smartthings-edge-lab:device:VirtualDevice:1"
MDNS_SERVICE = "_stlab._tcp"
MANUFACTURER = "smartthings-edge-lab"
API_VERSION = 1
MAX_SUBSCRIBERS = 5

# What each device type can do. "state" is the initial state; "simulate" lists
# the attributes the dashboard may set directly (sensors have no commands).
TYPES: dict[str, dict] = {
    "switch": {
        "label": "Switch",
        "capabilities": ["switch", "refresh"],
        "state": {"switch": "off"},
        "simulate": {},
    },
    "dimmer": {
        "label": "Dimmer",
        "capabilities": ["switch", "switchLevel", "refresh"],
        "state": {"switch": "off", "level": 50},
        "simulate": {},
    },
    "contact": {
        "label": "Contact Sensor",
        "capabilities": ["contactSensor", "refresh"],
        "state": {"contact": "closed"},
        "simulate": {"contact": ["open", "closed"]},
    },
    "motion": {
        "label": "Motion Sensor",
        "capabilities": ["motionSensor", "refresh"],
        "state": {"motion": "inactive"},
        "simulate": {"motion": ["active", "inactive"]},
    },
    "temperature": {
        "label": "Temperature Sensor",
        "capabilities": ["temperatureMeasurement", "relativeHumidityMeasurement", "refresh"],
        "state": {"temperature": 22.0, "humidity": 45},
        "simulate": {"temperature": "number", "humidity": "number"},
    },
}


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def local_ip_for(peer: str = "8.8.8.8") -> str:
    """The address of the interface this machine uses to reach `peer`.

    Connecting a UDP socket sends no packets; it only picks a route.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((peer, 9))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class VirtualDevice:
    def __init__(self, record: dict, port: int, fleet: "Fleet") -> None:
        self.id: str = record["id"]
        self.type: str = record["type"]
        self.name: str = record["name"]
        self.state: dict = dict(record["state"])
        self.port = port
        self.fleet = fleet
        self.lock = threading.Lock()
        self.subscribers: dict[str, dict] = {}  # url -> {"expires": ts, "failures": n}
        self.motion_timer: threading.Timer | None = None

    # ---- description -------------------------------------------------
    def info(self, host_ip: str) -> dict:
        spec = TYPES[self.type]
        return {
            "api": API_VERSION,
            "id": self.id,
            "name": self.name,
            "type": self.type,
            "manufacturer": MANUFACTURER,
            "model": f"virtual-{self.type}",
            "firmware": "1.0.0",
            "capabilities": spec["capabilities"],
            "baseUrl": f"http://{host_ip}:{self.port}",
        }

    def snapshot(self) -> dict:
        with self.lock:
            return dict(self.state)

    # ---- behaviour ---------------------------------------------------
    def apply_command(self, capability: str, command: str, args: dict) -> dict:
        """Run a SmartThings-style command. Raises ValueError if unsupported."""
        caps = TYPES[self.type]["capabilities"]
        if capability not in caps:
            raise ValueError(f"{self.type} does not support capability '{capability}'")
        if capability == "refresh":
            return self.snapshot()
        if capability == "switch" and command in ("on", "off"):
            return self.set_state({"switch": command}, source="command")
        if capability == "switchLevel" and command == "setLevel":
            level = args.get("level")
            if not isinstance(level, (int, float)) or not 0 <= level <= 100:
                raise ValueError("setLevel needs args.level between 0 and 100")
            changes = {"level": int(level)}
            # Like most real dimmers: setting a level above 0 turns the light on.
            changes["switch"] = "on" if level > 0 else "off"
            return self.set_state(changes, source="command")
        raise ValueError(f"unsupported command {capability}.{command}")

    def simulate(self, changes: dict) -> dict:
        """Set sensor attributes directly (what a real sensor would 'feel')."""
        allowed = TYPES[self.type]["simulate"]
        clean = {}
        for key, value in changes.items():
            rule = allowed.get(key)
            if rule is None:
                raise ValueError(f"'{key}' cannot be simulated on a {self.type}")
            if rule == "number":
                if not isinstance(value, (int, float)):
                    raise ValueError(f"'{key}' must be a number")
                clean[key] = round(float(value), 1) if key == "temperature" else int(value)
            elif value not in rule:
                raise ValueError(f"'{key}' must be one of {rule}")
            else:
                clean[key] = value
        state = self.set_state(clean, source="simulate")
        if self.type == "motion" and clean.get("motion") == "active":
            self._schedule_motion_reset()
        return state

    def _schedule_motion_reset(self) -> None:
        timeout = self.fleet.motion_timeout
        if timeout <= 0:
            return
        if self.motion_timer:
            self.motion_timer.cancel()
        self.motion_timer = threading.Timer(
            timeout, lambda: self.set_state({"motion": "inactive"}, source="timeout")
        )
        self.motion_timer.daemon = True
        self.motion_timer.start()

    def set_state(self, changes: dict, source: str) -> dict:
        with self.lock:
            changed = {k: v for k, v in changes.items() if self.state.get(k) != v}
            self.state.update(changes)
            state = dict(self.state)
        if changed:
            log(f"[{self.name}] {source}: {json.dumps(changed)}")
            self.fleet.save()
            self.push(state)
        return state

    # ---- subscriptions -----------------------------------------------
    def subscribe(self, url: str, ttl: int) -> int:
        if not isinstance(url, str) or not url.startswith("http://"):
            raise ValueError("subscribe needs an http:// url")
        ttl = max(60, min(int(ttl or 900), 3600))
        with self.lock:
            self._expire_locked()
            if url not in self.subscribers and len(self.subscribers) >= MAX_SUBSCRIBERS:
                raise ValueError("too many subscribers")
            is_new = url not in self.subscribers
            self.subscribers[url] = {"expires": time.time() + ttl, "failures": 0}
        if is_new:
            log(f"[{self.name}] subscriber added: {url} (ttl {ttl}s)")
        return ttl

    def unsubscribe(self, url: str) -> None:
        with self.lock:
            if self.subscribers.pop(url, None):
                log(f"[{self.name}] subscriber removed: {url}")

    def _expire_locked(self) -> None:
        now = time.time()
        for url in [u for u, s in self.subscribers.items() if s["expires"] < now]:
            del self.subscribers[url]
            log(f"[{self.name}] subscription expired: {url}")

    def push(self, state: dict) -> None:
        with self.lock:
            self._expire_locked()
            targets = list(self.subscribers)
        body = json.dumps({"id": self.id, "state": state}).encode()
        for url in targets:
            threading.Thread(target=self._push_one, args=(url, body), daemon=True).start()

    def _push_one(self, url: str, body: bytes) -> None:
        req = Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urlopen(req, timeout=3) as resp:
                resp.read()
            with self.lock:
                if url in self.subscribers:
                    self.subscribers[url]["failures"] = 0
        except Exception as exc:  # noqa: BLE001 - any failure counts
            with self.lock:
                sub = self.subscribers.get(url)
                if sub is None:
                    return
                sub["failures"] += 1
                if sub["failures"] >= 3:
                    del self.subscribers[url]
                    log(f"[{self.name}] dropped subscriber after 3 failed pushes: {url}")
                    return
            log(f"[{self.name}] push to {url} failed: {exc}")


def json_handler(fleet: "Fleet", device: VirtualDevice | None):
    """Build a request handler. device=None means the dashboard server."""

    class Handler(BaseHTTPRequestHandler):
        server_version = "st-edge-lab/1.0"

        def log_message(self, fmt, *args):  # quiet by default
            if fleet.verbose:
                log(f"http {self.address_string()} {fmt % args}")

        # -- helpers --
        def send_json(self, status: int, payload) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def read_json(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if length == 0:
                return {}
            if length > 64 * 1024:
                raise ValueError("body too large")
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise ValueError("body must be a JSON object")
            return data

        def host_ip(self) -> str:
            return fleet.advertise_ip or local_ip_for(self.client_address[0])

        # -- routing --
        def do_GET(self):
            if device is None:
                return self.dashboard_get()
            if self.path == "/info":
                return self.send_json(200, device.info(self.host_ip()))
            if self.path == "/state":
                return self.send_json(200, device.snapshot())
            self.send_json(404, {"error": "not found"})

        def do_POST(self):
            try:
                body = self.read_json()
            except (ValueError, json.JSONDecodeError) as exc:
                return self.send_json(400, {"error": str(exc)})
            if device is None:
                return self.dashboard_post(body)
            try:
                if self.path == "/command":
                    state = device.apply_command(
                        str(body.get("capability")), str(body.get("command")), body.get("args") or {}
                    )
                    return self.send_json(200, {"state": state})
                if self.path == "/simulate":
                    return self.send_json(200, {"state": device.simulate(body)})
                if self.path == "/subscribe":
                    ttl = device.subscribe(body.get("url"), body.get("ttl", 900))
                    return self.send_json(200, {"ttl": ttl, "state": device.snapshot()})
                if self.path == "/unsubscribe":
                    device.unsubscribe(body.get("url"))
                    return self.send_json(200, {})
            except ValueError as exc:
                return self.send_json(400, {"error": str(exc)})
            self.send_json(404, {"error": "not found"})

        # -- dashboard --
        def dashboard_get(self):
            if self.path in ("/", "/index.html"):
                body = DASHBOARD_HTML.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/api/devices":
                ip = self.host_ip()
                return self.send_json(
                    200,
                    [
                        {**d.info(ip), "state": d.snapshot(), "subscribers": len(d.subscribers),
                         "simulate": TYPES[d.type]["simulate"]}
                        for d in fleet.devices
                    ],
                )
            self.send_json(404, {"error": "not found"})

        def dashboard_post(self, body: dict):
            # /api/devices/<id>/command or /api/devices/<id>/simulate
            parts = self.path.strip("/").split("/")
            if len(parts) != 4 or parts[:2] != ["api", "devices"]:
                return self.send_json(404, {"error": "not found"})
            target = next((d for d in fleet.devices if d.id == parts[2]), None)
            if target is None:
                return self.send_json(404, {"error": "unknown device"})
            try:
                if parts[3] == "command":
                    state = target.apply_command(
                        str(body.get("capability")), str(body.get("command")), body.get("args") or {}
                    )
                elif parts[3] == "simulate":
                    state = target.simulate(body)
                else:
                    return self.send_json(404, {"error": "not found"})
            except ValueError as exc:
                return self.send_json(400, {"error": str(exc)})
            self.send_json(200, {"state": state})

    return Handler


class Fleet:
    """All virtual devices in this process, their persistence and servers."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.state_file = args.state_file
        self.advertise_ip = args.advertise_ip
        self.verbose = args.verbose
        self.motion_timeout = args.motion_timeout
        self.save_lock = threading.Lock()
        self.devices: list[VirtualDevice] = []
        self.servers: list[ThreadingHTTPServer] = []
        self.mdns_procs: list[subprocess.Popen] = []

        saved = self._load()
        counts: dict[str, int] = {}
        for index, dtype in enumerate(args.devices):
            counts[dtype] = counts.get(dtype, 0) + 1
            key = f"{dtype}-{counts[dtype]}"
            record = saved.get(key) or {
                "id": str(uuid.uuid4()),
                "type": dtype,
                "name": f"{args.name_prefix} {TYPES[dtype]['label']}"
                + (f" {counts[dtype]}" if counts[dtype] > 1 else ""),
                "state": dict(TYPES[dtype]["state"]),
            }
            record["key"] = key
            self.devices.append(VirtualDevice(record, args.base_port + 1 + index, self))
        self.save()

    def _load(self) -> dict:
        try:
            with open(self.state_file, encoding="utf-8") as fh:
                return {r["key"]: r for r in json.load(fh)}
        except (OSError, ValueError, KeyError, TypeError):
            return {}

    def save(self) -> None:
        records = [
            {"key": f"{d.type}-{i}", "id": d.id, "type": d.type, "name": d.name, "state": d.snapshot()}
            for i, d in self._numbered()
        ]
        with self.save_lock:
            tmp = self.state_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(records, fh, indent=2)
            os.replace(tmp, self.state_file)

    def _numbered(self):
        counts: dict[str, int] = {}
        for d in self.devices:
            counts[d.type] = counts.get(d.type, 0) + 1
            yield counts[d.type], d

    # ---- servers -----------------------------------------------------
    def serve(self, bind: str, dashboard_port: int) -> None:
        def start(port: int, handler) -> None:
            srv = ThreadingHTTPServer((bind, port), handler)
            srv.daemon_threads = True
            self.servers.append(srv)
            threading.Thread(target=srv.serve_forever, daemon=True).start()

        start(dashboard_port, json_handler(self, None))
        for d in self.devices:
            start(d.port, json_handler(self, d))

    def start_mdns(self) -> str | None:
        """Advertise each device with the OS's own Bonjour/Avahi tool, if present."""
        if shutil.which("dns-sd"):  # macOS (built in)
            make = lambda d: ["dns-sd", "-R", d.name, MDNS_SERVICE, "local", str(d.port),
                              f"id={d.id}", f"type={d.type}"]
            tool = "dns-sd"
        elif shutil.which("avahi-publish"):  # Linux with avahi-utils
            make = lambda d: ["avahi-publish", "-s", d.name, MDNS_SERVICE, str(d.port),
                              f"id={d.id}", f"type={d.type}"]
            tool = "avahi-publish"
        else:
            return None
        for d in self.devices:
            self.mdns_procs.append(
                subprocess.Popen(make(d), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            )
        return tool

    def start_temperature_drift(self, period: float) -> None:
        def loop():
            while True:
                time.sleep(period)
                for d in self.devices:
                    if d.type == "temperature":
                        s = d.snapshot()
                        d.set_state(
                            {
                                "temperature": round(s["temperature"] + random.uniform(-0.3, 0.3), 1),
                                "humidity": max(0, min(100, s["humidity"] + random.choice((-1, 0, 0, 1)))),
                            },
                            source="drift",
                        )

        threading.Thread(target=loop, daemon=True).start()

    def stop(self) -> None:
        for p in self.mdns_procs:
            p.terminate()
        for s in self.servers:
            s.shutdown()


def ssdp_responder(fleet: Fleet, stop: threading.Event) -> None:
    """Answer M-SEARCH requests for our search target (or ssdp:all)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        try:  # lets other SSDP software on this machine keep working
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
    sock.bind(("", SSDP_PORT))
    mreq = struct.pack("4s4s", socket.inet_aton(SSDP_ADDR), socket.inet_aton("0.0.0.0"))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)

    while not stop.is_set():
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        text = data.decode("utf-8", "replace")
        if not text.startswith("M-SEARCH"):
            continue
        headers = {}
        for line in text.split("\r\n")[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        st = headers.get("st", "")
        if st not in (SEARCH_TARGET, "ssdp:all"):
            continue
        ip = fleet.advertise_ip or local_ip_for(addr[0])
        if fleet.verbose:
            log(f"ssdp: M-SEARCH from {addr[0]}:{addr[1]} (ST {st})")
        for d in fleet.devices:
            response = "\r\n".join(
                [
                    "HTTP/1.1 200 OK",
                    "CACHE-CONTROL: max-age=1800",
                    "EXT:",
                    f"LOCATION: http://{ip}:{d.port}/info",
                    "SERVER: Python/3 UPnP/1.1 st-edge-lab/1.0",
                    f"ST: {SEARCH_TARGET}",
                    f"USN: uuid:{d.id}::{SEARCH_TARGET}",
                    "",
                    "",
                ]
            )
            sock.sendto(response.encode(), addr)
    sock.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--devices", default="switch,dimmer,contact,motion,temperature",
                   help="comma-separated device types to run; repeat a type for several "
                        f"(choices: {', '.join(TYPES)})")
    p.add_argument("--base-port", type=int, default=8800,
                   help="dashboard port; devices use the following ports (default 8800)")
    p.add_argument("--bind", default="0.0.0.0", help="address to listen on (default all interfaces)")
    p.add_argument("--advertise-ip", help="IP to put in discovery answers (default: auto-detect)")
    p.add_argument("--name-prefix", default="Lab", help='device name prefix (default "Lab")')
    p.add_argument("--state-file", default="virtual-devices.json",
                   help="where device ids and state are kept between runs")
    p.add_argument("--no-ssdp", action="store_true", help="do not answer SSDP searches")
    p.add_argument("--no-mdns", action="store_true", help="do not advertise over mDNS/Bonjour")
    p.add_argument("--drift", type=float, default=30,
                   help="seconds between temperature/humidity changes, 0 to disable (default 30)")
    p.add_argument("--motion-timeout", type=float, default=30,
                   help="seconds before motion returns to inactive, 0 to disable (default 30)")
    p.add_argument("-v", "--verbose", action="store_true", help="log every HTTP request and search")
    args = p.parse_args(argv)
    args.devices = [t.strip() for t in args.devices.split(",") if t.strip()]
    unknown = [t for t in args.devices if t not in TYPES]
    if unknown or not args.devices:
        p.error(f"unknown device type(s): {', '.join(unknown) or '(none given)'}")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    fleet = Fleet(args)
    try:
        fleet.serve(args.bind, args.base_port)
    except OSError as exc:
        print(f"Could not open a port ({exc}). Try --base-port with another value.", file=sys.stderr)
        return 1

    stop = threading.Event()
    if not args.no_ssdp:
        try:
            threading.Thread(target=ssdp_responder, args=(fleet, stop), daemon=True).start()
        except OSError as exc:
            log(f"SSDP disabled: {exc}")
    mdns_tool = None if args.no_mdns else fleet.start_mdns()
    if args.drift > 0:
        fleet.start_temperature_drift(args.drift)

    ip = args.advertise_ip or local_ip_for()
    log(f"Dashboard: http://{ip}:{args.base_port}  (open it on your phone too)")
    for d in fleet.devices:
        log(f"  {d.name:<28} http://{ip}:{d.port}  id={d.id}")
    log(f"Discovery: SSDP {'off' if args.no_ssdp else 'on'}, "
        f"mDNS {mdns_tool or 'off (no dns-sd/avahi-publish found)' if not args.no_mdns else 'off'}")
    log("Press Ctrl+C to stop.")

    done = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: done.set())
    signal.signal(signal.SIGTERM, lambda *_: done.set())
    done.wait()
    stop.set()
    fleet.stop()
    log("Stopped.")
    return 0


DASHBOARD_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Edge Lab Devices</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#16181d;--muted:#6b7280;--line:#e5e7eb;--accent:#2563eb;--on:#16a34a}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#181b21;--text:#e8eaed;--muted:#9aa0a6;--line:#2a2e36;--accent:#60a5fa;--on:#4ade80}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.4 system-ui,-apple-system,sans-serif}
main{max-width:720px;margin:0 auto;padding:16px}h1{font-size:20px;margin:4px 0 2px}p.sub{color:var(--muted);margin:0 0 16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:12px}
.row{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
.name{font-weight:600}.meta{color:var(--muted);font-size:12px;word-break:break-all}
.val{font-variant-numeric:tabular-nums;font-size:18px}.val.on{color:var(--on)}
button{font:inherit;border:1px solid var(--line);background:var(--bg);color:var(--text);border-radius:8px;padding:8px 14px;cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.controls{display:flex;gap:8px;align-items:center;margin-top:10px;flex-wrap:wrap}
input[type=range]{flex:1;min-width:140px}input[type=number]{width:90px;font:inherit;padding:6px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--text)}
.err{color:#dc2626;font-size:13px}
</style></head><body><main>
<h1>Edge Lab virtual devices</h1>
<p class="sub">Changes here are pushed to every hub subscribed to the device.</p>
<div id="list"></div><div id="err" class="err"></div>
</main><script>
const list=document.getElementById('list'),err=document.getElementById('err');
let busy=false;
async function post(id,kind,body){busy=true;try{const r=await fetch(`/api/devices/${id}/${kind}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const j=await r.json();err.textContent=r.ok?'':j.error}catch(e){err.textContent=String(e)}busy=false;load()}
function describe(s){return Object.entries(s).map(([k,v])=>`${k}: ${v}${k==='temperature'?' °C':k==='humidity'||k==='level'?' %':''}`).join(' · ')}
function controls(d){const s=d.state,id=d.id;let h='';
 if('switch' in s)h+=`<button class="${s.switch==='on'?'primary':''}" onclick="post('${id}','command',{capability:'switch',command:'${s.switch==='on'?'off':'on'}'})">Turn ${s.switch==='on'?'off':'on'}</button>`;
 if('level' in s)h+=`<input type="range" min="0" max="100" value="${s.level}" onchange="post('${id}','command',{capability:'switchLevel',command:'setLevel',args:{level:+this.value}})">`;
 if('contact' in s)h+=`<button class="primary" onclick="post('${id}','simulate',{contact:'${s.contact==='open'?'closed':'open'}'})">${s.contact==='open'?'Close':'Open'}</button>`;
 if('motion' in s)h+=`<button class="primary" onclick="post('${id}','simulate',{motion:'${s.motion==='active'?'inactive':'active'}'})">${s.motion==='active'?'Clear motion':'Trigger motion'}</button>`;
 if('temperature' in s)h+=`<input type="number" step="0.5" value="${s.temperature}" onchange="post('${id}','simulate',{temperature:+this.value})"> °C <input type="number" step="1" value="${s.humidity}" onchange="post('${id}','simulate',{humidity:+this.value})"> %`;
 return h}
async function load(){if(busy||document.activeElement?.tagName==='INPUT')return;try{const r=await fetch('/api/devices');const ds=await r.json();
 list.innerHTML=ds.map(d=>{const on=d.state.switch==='on'||d.state.contact==='open'||d.state.motion==='active';
 return `<div class="card"><div class="row"><div><div class="name">${d.name}</div><div class="meta">${d.type} · ${d.baseUrl} · ${d.subscribers} hub subscription(s)</div></div><div class="val ${on?'on':''}">${describe(d.state)}</div></div><div class="controls">${controls(d)}</div></div>`}).join('')}catch(e){err.textContent='Lost connection to the device process.'}}
load();setInterval(load,1500);
</script></body></html>
"""

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
