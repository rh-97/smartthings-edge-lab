#!/usr/bin/env bash
# End-to-end check of the virtual devices, in Docker: start them, then use
# probe.py (the stand-in hub) to discover, command and watch pushes.
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD/virtual-device":/app:ro -w /tmp python:3.12-slim sh -ec '
  PYTHONPYCACHEPREFIX=/tmp/pyc python3 -m py_compile /app/virtual_device.py /app/probe.py
  python3 /app/virtual_device.py --drift 0 --state-file /tmp/vd.json > /tmp/vd.log 2>&1 &
  sleep 1.5
  fail() { echo "FAIL $1"; cat /tmp/vd.log; exit 1; }

  out=$(python3 /app/probe.py discover)
  echo "$out"
  [ "$(echo "$out" | grep -c "id=")" -eq 5 ] || fail "expected 5 devices from discovery"
  echo "PASS discovery found 5 devices"

  (timeout 6 python3 /app/probe.py watch > /tmp/watch.log 2>&1 &)
  sleep 2
  python3 /app/probe.py command "lab switch" switch on | grep -q "\"switch\": \"on\"" || fail "switch on"
  echo "PASS switch.on"
  python3 /app/probe.py command dimmer switchLevel setLevel 30 | grep -q "\"level\": 30" || fail "setLevel"
  echo "PASS switchLevel.setLevel"
  if python3 /app/probe.py command contact switch on 2>/dev/null; then fail "sensor accepted a switch command"; fi
  echo "PASS sensor rejects unsupported command"
  sleep 2
  grep -q "push from Lab Switch" /tmp/watch.log || fail "no push received"
  echo "PASS push received"
'
