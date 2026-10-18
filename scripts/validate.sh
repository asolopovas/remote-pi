#!/usr/bin/env bash
# Local checks only. Heavy modes must be invoked under the machine lease.
set -euo pipefail
unset CDPATH
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s {tooling|launch|all}\n' "$0" >&2; }
[[ $# == 1 ]] || { usage; exit 2; }
case "$1" in tooling|launch|all) mode=$1 ;; *) usage; exit 2 ;; esac
need() { command -v "$1" >/dev/null || fail "missing prerequisite: $1"; }
need python3
need git

# Resolve cache locations before isolating HOME. Never inherit config files from
# these directories: only the named cache subtrees are shared below.
original_home=${HOME:?HOME must be set}
cargo_cache=${CARGO_HOME:-$original_home/.cargo}
gradle_cache=${GRADLE_USER_HOME:-$original_home/.gradle}
pub_cache=${PUB_CACHE:-$original_home/.pub-cache}
rustup_home=${RUSTUP_HOME:-$original_home/.rustup}
# Relative cache overrides are relative to the caller, not temporary HOME or a
# component's cwd. Symlink targets must remain absolute after we change cwd.
for variable in cargo_cache gradle_cache pub_cache rustup_home; do
  [[ ${!variable} = /* ]] || printf -v "$variable" '%s/%s' "$PWD" "${!variable}"
done
if [[ $mode != tooling ]]; then
  need node
  need flutter
  need cargo
  [[ ${PNPM_NATIVE:-} = /* && -f $PNPM_NATIVE && -x $PNPM_NATIVE ]] || fail 'set PNPM_NATIVE to an existing absolute offline native pnpm executable (not a downloading shim)'
  [[ -x /bin/bwrap ]] || fail 'missing prerequisite: /bin/bwrap (Linux bubblewrap)'
  [[ -d $ROOT/pi-extension/node_modules ]] || fail 'missing installed extension dependencies; see pi-extension/README.md'
  [[ -f $ROOT/pi-extension/build/managed-runtime/manifest.json ]] || fail 'missing prepared managed runtime; see pi-extension/docs/secure-launcher.md'
  [[ -f $ROOT/app/.dart_tool/package_config.json ]] || fail 'missing resolved Flutter dependencies; see app/README.md'
fi
if [[ $mode == all ]]; then
  need cargo
  [[ -x $ROOT/app/android/gradlew ]] || fail 'missing local Android Gradle wrapper'
  [[ -d $gradle_cache/caches && -d $gradle_cache/wrapper/dists ]] || fail 'missing cached Gradle dependencies/distribution for native speech tests'
  # A wrapper without its distribution may download even with --offline.
  compgen -G "$gradle_cache/wrapper/dists/gradle-8.14-all/*/gradle-8.14/bin/gradle" >/dev/null || fail 'missing cached Gradle 8.14 all distribution'
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/remote-pi-validation-XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/home/agent" "$work/home/remote" "$work/home/.config" "$work/home/.cache"
export HOME="$work/home" USERPROFILE="$work/home" REMOTE_PI_HOME="$work/home/remote" PI_CODING_AGENT_DIR="$work/home/agent"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
# Same worker/legacy-child markers as validate-managed-model.sh, before imports.
while IFS= read -r key; do unset "$key"; done < <(env | cut -d= -f1 | grep -E '^(DSA_|REMOTE_PI_.*CHILD|PI_(SUBAGENTS?|WORKER|SESSION|PARENT|AGENT)(_|$)|PI_ASYNC_NATIVE_RUNNER$|PI_CODING_AGENT_SESSION_DIR$|REMOTE_PI_DIRECT_CONFIG$|REMOTE_PI_DAEMON$)' || true)
unset REMOTE_PI_RELAY NODE_OPTIONS
export RUSTUP_AUTO_INSTALL=0
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export PUB_CACHE="$HOME/.pub-cache" CARGO_HOME="$HOME/.cargo" GRADLE_USER_HOME="$HOME/.gradle" RUSTUP_HOME="$rustup_home"
mkdir -p "$PUB_CACHE" "$CARGO_HOME" "$GRADLE_USER_HOME/init.d"
share_cache() { [[ ! -d $1 ]] || ln -s -- "$1" "$2"; }
for part in hosted hosted-hashes git; do share_cache "$pub_cache/$part" "$PUB_CACHE/$part"; done
for part in registry git; do share_cache "$cargo_cache/$part" "$CARGO_HOME/$part"; done
if [[ $mode == all ]]; then
  share_cache "$gradle_cache/caches" "$GRADLE_USER_HOME/caches"
  mkdir -p "$GRADLE_USER_HOME/wrapper"
  share_cache "$gradle_cache/wrapper/dists" "$GRADLE_USER_HOME/wrapper/dists"
  # The existing speech harness uses HOME/.gradle/caches and --offline. Keep
  # other Gradle invocations offline too, without reading user init/credentials.
  printf '%s\n' 'gradle.startParameter.offline = true' > "$GRADLE_USER_HOME/init.d/offline.gradle"
  export GRADLE_OPTS='-Dorg.gradle.daemon=false'
fi
if [[ $mode != tooling ]]; then
  node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22 || a===22 && b>=19 ? 0 : 1)' || fail 'Node 22.19+ required'
fi
run() { local directory=$1; shift; printf '\n==> %s: ' "${directory#"$ROOT"/}"; printf '%q ' "$@"; printf '\n'; (cd -- "$directory" && "$@"); }
tooling() {
  run "$ROOT" python3 scripts/test-dev-workflow.py
  run "$ROOT" python3 scripts/test-deploy-android.py
  run "$ROOT" python3 scripts/test-installers.py
  run "$ROOT" python3 scripts/test-docker-publishers.py
  run "$ROOT" python3 scripts/check-docs.py --self-test
  run "$ROOT" python3 scripts/check-docs.py
}
pnpm_run() { run "$ROOT/pi-extension" "$PNPM_NATIVE" --config.verify-deps-before-run=false "$@"; }
if [[ $mode == tooling ]]; then
  tooling
else
  [[ $mode != all ]] || tooling
  if [[ $mode == all ]]; then
    run "$ROOT/relay" cargo fmt --check
    run "$ROOT/relay" cargo clippy --offline --locked -- -D warnings
    run "$ROOT/relay" cargo test --offline --locked
  fi
  # The fixture is executed natively below: neither output-dir nor cross-target
  # environment overrides may select a different (or stale) executable.
  unset CARGO_BUILD_TARGET
  export REMOTE_PI_TEST_RELAY_BINARY="$ROOT/relay/target/debug/examples/launch_fixture"
  run "$ROOT/relay" cargo build --offline --locked --example launch_fixture --target-dir "$ROOT/relay/target"
  pnpm_run typecheck
  pnpm_run build
  if [[ $mode == all ]]; then
    pnpm_run exec vitest run --maxWorkers=1
  else
    # Real runtime + staged-release integration is included, not mocked away.
    pnpm_run exec vitest run src/session/launch_ src/session/secure_launcher.integration.test.ts src/session/managed_ src/session/session_control src/protocol/launcher_contract.test.ts src/protocol/session_control.test.ts --maxWorkers=1
  fi
  run "$ROOT/pi-extension" python3 scripts/test-launcher-pin-tty.py
  if [[ $mode == all ]]; then
    run "$ROOT/app" bash test/native/speech_to_text/run.sh
    run "$ROOT/app" flutter analyze --no-pub
    run "$ROOT/app" flutter test --no-pub --concurrency=1 test test_acceptance/local_secure_launch_test.dart
  else
    run "$ROOT/app" flutter test --no-pub --concurrency=1 test_acceptance/local_secure_launch_test.dart test/agents/fresh_launcher_handoff_test.dart test/agents/fresh_launcher_page_test.dart test/agents/fresh_launcher_repository_test.dart test/agents/launcher_recovery_page_test.dart test/agents/launcher_recovery_repository_test.dart test/agents/secure_launch_ingress_test.dart test/agents/session_control_repository_test.dart test/transport/launcher_probe_test.dart test/transport/session_control_ingress_test.dart test/protocol/launcher_protocol_test.dart test/protocol/session_control_protocol_test.dart test/ui/home/launch_machine_group_test.dart test/ui/home/launch_machine_key_test.dart
  fi
fi
printf '\nPASS: %s checks completed (no deploy/install performed).\n' "$mode"
