#!/usr/bin/env bash
# Run the virtual devices in Docker, on a Linux machine.
#
#   scripts/run-devices.sh                         # all five devices
#   scripts/run-devices.sh --devices switch,contact -v
#
# Any arguments go to virtual_device.py (see --help).
#
# Linux only: --network host puts the container directly on your LAN, so the
# hub's SSDP search (UDP multicast) reaches it. On macOS, Docker runs inside a
# VM and multicast never arrives, so run `python3 virtual-device/virtual_device.py`
# there instead.
#
# Device ids and state are kept in .data/ (git-ignored), so the same devices
# come back after a restart.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Linux" ]; then
  echo "run-devices.sh needs Linux (Docker host networking)." >&2
  echo "On macOS, run: python3 virtual-device/virtual_device.py" >&2
  exit 1
fi

mkdir -p .data

tty_flags=-i
[ -t 0 ] && [ -t 1 ] && tty_flags=-it

exec docker run --rm $tty_flags --init \
  --name stlab-devices \
  --network host \
  --user "$(id -u):$(id -g)" \
  -v "$PWD/virtual-device":/app:ro \
  -v "$PWD/.data":/data \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -e PYTHONUNBUFFERED=1 \
  python:3.12-slim \
  python3 /app/virtual_device.py --state-file /data/virtual-devices.json "$@"
