#!/usr/bin/env python3
"""A stand-in for the hub: test virtual (or real) devices without SmartThings.

It does what the Edge driver does, from your laptop:

  probe.py discover                      SSDP search, then GET /info for each answer
  probe.py watch                         subscribe to every device and print pushes
  probe.py command <id-or-name> switch on
  probe.py command <id-or-name> switchLevel setLevel 30
  probe.py command <id-or-name> refresh refresh

Standard library only.
"""

from __future__ import annotations

import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
SEARCH_TARGET = "urn:smartthings-edge-lab:device:VirtualDevice:1"


def http(method: str, url: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=5) as resp:
        return json.loads(resp.read() or b"{}")


def ssdp_search(window: float = 3.0) -> dict[str, str]:
    """Return {device id: base url} for every device that answers."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.bind(("", 0))
    msg = "\r\n".join(
        ["M-SEARCH * HTTP/1.1", f"HOST: {SSDP_ADDR}:{SSDP_PORT}", 'MAN: "ssdp:discover"', "MX: 2",
         f"ST: {SEARCH_TARGET}", "", ""]
    )
    sock.sendto(msg.encode(), (SSDP_ADDR, SSDP_PORT))
    found: dict[str, str] = {}
    deadline = time.time() + window
    while (remaining := deadline - time.time()) > 0:
        sock.settimeout(remaining)
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            break
        headers = {}
        for line in data.decode("utf-8", "replace").split("\r\n")[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        usn, location = headers.get("usn", ""), headers.get("location", "")
        if headers.get("st") == SEARCH_TARGET and usn.startswith("uuid:") and location:
            device_id = usn[5:].split("::")[0]
            found[device_id] = location.rsplit("/", 1)[0]  # strip "/info"
    sock.close()
    return found


def discover() -> list[dict]:
    devices = []
    for device_id, base in ssdp_search().items():
        try:
            info = http("GET", base + "/info")
            info["state"] = http("GET", base + "/state")
            info["baseUrl"] = base
            devices.append(info)
        except OSError as exc:
            print(f"  ! {device_id} at {base}: {exc}")
    return devices


def pick(devices: list[dict], needle: str) -> dict:
    needle = needle.lower()
    matches = [d for d in devices if d["id"].startswith(needle) or needle in d["name"].lower()]
    if len(matches) != 1:
        sys.exit(f"'{needle}' matches {len(matches)} devices; use more of the id or name")
    return matches[0]


def watch(devices: list[dict]) -> None:
    class PushHandler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            msg = json.loads(body or b"{}")
            name = next((d["name"] for d in devices if d["id"] == msg.get("id")), msg.get("id"))
            print(time.strftime("%H:%M:%S"), f"push from {name}: {json.dumps(msg.get('state'))}", flush=True)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

    server = ThreadingHTTPServer(("0.0.0.0", 0), PushHandler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def subscribe_all():
        for d in devices:
            host = d["baseUrl"].split("//", 1)[1].split(":")[0]
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((host, 9))
            my_ip = s.getsockname()[0]
            s.close()
            http("POST", d["baseUrl"] + "/subscribe", {"url": f"http://{my_ip}:{port}/push", "ttl": 300})

    subscribe_all()
    print(f"Subscribed to {len(devices)} device(s); listening on port {port}. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(240)
            subscribe_all()  # renew before the 300 s ttl runs out, like the driver does
    except KeyboardInterrupt:
        pass


def main(argv: list[str]) -> None:
    if not argv or argv[0] not in ("discover", "watch", "command"):
        sys.exit(__doc__)
    devices = discover()
    if argv[0] == "discover":
        if not devices:
            print("No devices answered. Is virtual_device.py running on this network?")
        for d in devices:
            print(f"{d['name']:<28} {d['type']:<12} {d['baseUrl']:<26} {json.dumps(d['state'])}")
            print(f"{'':<28} id={d['id']}")
    elif argv[0] == "watch":
        watch(devices)
    else:
        if len(argv) < 4:
            sys.exit("usage: probe.py command <id-or-name> <capability> <command> [value]")
        d = pick(devices, argv[1])
        args = {"level": float(argv[4])} if len(argv) > 4 else {}
        try:
            result = http("POST", d["baseUrl"] + "/command",
                          {"capability": argv[2], "command": argv[3], "args": args})
        except HTTPError as exc:
            sys.exit(f"device refused: {json.loads(exc.read() or b'{}').get('error', exc)}")
        print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
