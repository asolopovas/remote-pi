#!/usr/bin/env bash
# Run through `pi-durable-subagents hold machine -- ...`.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/managed-runtime ] || node scripts/prepare-managed-runtime.mjs
root=$(mktemp -d /tmp/remote-pi-host-validation-XXXXXX)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/agent" "$root/remote"
export HOME="$root" USERPROFILE="$root" REMOTE_PI_HOME="$root/remote" PI_CODING_AGENT_DIR="$root/agent"
while IFS= read -r key; do unset "$key"; done < <(env | cut -d= -f1 | grep -E '^(DSA_|REMOTE_PI_.*CHILD|PI_(SUBAGENTS?|WORKER|SESSION|PARENT|AGENT)(_|$)|PI_ASYNC_NATIVE_RUNNER$|PI_CODING_AGENT_SESSION_DIR$|REMOTE_PI_DIRECT_CONFIG$|REMOTE_PI_DAEMON$)' || true)
pnpm=${PNPM_NATIVE:?Set PNPM_NATIVE to the existing offline native pnpm executable}
# Offline native runner: do not let a shell shim resolve to Bun.
"$pnpm" --config.verify-deps-before-run=false typecheck
"$pnpm" --config.verify-deps-before-run=false build
"$pnpm" --config.verify-deps-before-run=false exec vitest run "$@" --maxWorkers=1
