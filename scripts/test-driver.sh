#!/usr/bin/env bash
# Runs the driver's networking code against the virtual devices, in Docker.
# No hub and no SmartThings account needed.
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t stlab-driver-test driver/tests >/dev/null
docker run --rm -v "$PWD":/lab:ro -w /lab/driver stlab-driver-test sh -c '
  python3 ../virtual-device/virtual_device.py --state-file /tmp/vd.json --drift 0 > /tmp/vd.log 2>&1 &
  sleep 1.5
  lua5.3 tests/run_harness.lua; code=$?
  [ "${VERBOSE:-}" ] && cat /tmp/vd.log
  exit $code'
