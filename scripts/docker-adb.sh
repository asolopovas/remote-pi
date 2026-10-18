#!/usr/bin/env bash
set -euo pipefail

IMAGE="${FLUTTER_DOCKER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Share Docker caches from the primary worktree, not each linked worktree.
MAIN_ROOT="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree / { sub(/^worktree /, ""); print; exit }')"
MAIN_ROOT="${MAIN_ROOT:-$ROOT}"
ADB_CACHE="$MAIN_ROOT/dockercache/adb"
mkdir -p "$ADB_CACHE"

# Uses adb from the Flutter Docker image. --network host makes wireless adb
# behave like host adb, and /root/.android is cached so pair keys survive.
#
# USB adb: requires USB debugging enabled on device. Container runs privileged
# and mounts /dev/bus/usb so host platform-tools are not needed.
#
# Wireless adb note: adb connect state lives in the adb server process. This
# script starts a fresh container/server per run, so pass ADB_CONNECT each time:
#   ADB_CONNECT=192.168.1.50:45678 scripts/docker-adb.sh devices
#   ADB_CONNECT=192.168.1.50:45678 scripts/docker-adb.sh install -r app.apk

tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args=(-it)
fi

network_args=()
if [[ -n "${ADB_CONNECT:-}" ]]; then
  network_args=(--network host)
fi

docker run --rm "${tty_args[@]}" \
  "${network_args[@]}" \
  --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -v /tmp:/tmp \
  -v "$ADB_CACHE":/root/.android \
  -v "$ROOT":/work \
  -w /work \
  -e ADB_CONNECT="${ADB_CONNECT:-}" \
  "$IMAGE" \
  bash -lc 'adb kill-server >/dev/null 2>&1 || true; if [[ -n "$ADB_CONNECT" ]]; then adb connect "$ADB_CONNECT" >&2; fi; adb "$@"' -- "$@"
