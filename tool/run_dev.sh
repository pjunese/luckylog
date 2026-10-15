#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
else
  flutter_bin="/Users/pjunese/flutter/bin/flutter"
fi

# Default to the owner's physical iPhone. Never silently fall back to a simulator.
# Override with -d / --device-id, or LUCKYLOG_DEVICE_ID on another workstation.
has_device=false
for arg in "$@"; do
  case "$arg" in
    -d|--device-id|--device-id=*|-d?*) has_device=true ;;
  esac
done
if [ "$has_device" = false ]; then
  device_id="${LUCKYLOG_DEVICE_ID:-00008140-000904901E7B001C}"
  printf '실제 iPhone에 럭키로그 DEV를 실행합니다. 기기가 연결되지 않으면 시뮬레이터로 전환하지 않습니다.\n'
  set -- -d "$device_id" "$@"
fi
exec "$flutter_bin" run --flavor dev "$@"
