# Daemon operations and recovery

[Project index](../../README.md#project-map) · [Host extension guide](../README.md)

Use the [source CLI](../README.md#source-cli) and [supervisor setup](../README.md#optional-daemon-supervisor) for installation and registration; `remote-pi` below denotes that source invocation. This guide owns service diagnostics/recovery, not generic extension configuration or [phone-managed launches](../../SECURE-LAUNCH.md).

## Inspect before changing anything

```sh
remote-pi daemons
remote-pi daemon status
# Linux:
systemctl --user status remote-pi-supervisord
journalctl --user -u remote-pi-supervisord -n 50
# macOS:
launchctl list | grep remotepi
tail -n 50 ~/.pi/remote/supervisord.log
```

Logs may contain project paths or provider diagnostics. Redact sensitive content before sharing them; do not publish whole configuration, pairing or credential files.

## Service cannot start

- **Supervisor script missing:** build/install this checkout using the [extension guide](../README.md#build-and-install-this-source). The public npm package is a different distribution.
- **Pi missing from service PATH:** the installer captures the environment at installation. Verify the intended Pi binary locally, then refresh this user's service configuration at an idle-safe maintenance boundary.
- **Moved package path:** the unit/plist may still reference an old `dist/bin/supervisord.js`. Inspect that exact path before reinstalling the service.
- **Linux user bus/login lifetime:** check the user's systemd session. If background operation after logout is intentional, arrange user lingering through the host administrator; it is not required for every machine.
- **Permission/socket error:** identify the exact path, owner and live process using it. Do not delete locks, sockets or identity storage based only on an error message.

Only after verifying the service is stopped and you own its processes, a foreground `pi-supervisord` run can isolate environment problems. Do not start a competing supervisor alongside the service.

## A daemon stays crashed

Read its stderr in the supervisor log and confirm its registered cwd still exists and is allowed. Provider/model setup belongs to the ordinary local Pi session; fix that locally, not by inventing credentials or relaxing filesystem permissions.

The registry at `~/.pi/remote/daemons.json` stores cwd and optional name. The [supervisor](../src/daemon/supervisor.ts) injects daemon configuration through `REMOTE_PI_DIRECT_CONFIG`, including relay auto-start and registry-owned names. A directory config file is not the daemon's sole authority; see [configuration precedence](../README.md#relay-and-local-configuration).

Do not manually launch another agent in the same cwd to diagnose a lock unless you first establish who owns the current process. A name/path match is not authority to stop it.

## Send says “daemon not running”

Use `remote-pi daemon status` and logs to distinguish an unstarted daemon from one that exhausted its restart budget. `daemon start` starts registered stopped agents; `daemon restart` affects the entire registered fleet. Schedule either intentionally—never restart active work as a routine troubleshooting step.

A status snapshot just after spawn is not readiness proof. Recheck actual startup errors before resending prompts; an uncertain send may already have been delivered.

## Phone cannot find a running daemon

Pair interactively using the [mobile connection workflow](../../app/README.md#connect-and-use); daemons do not display a pairing QR. Pairing is machine-wide. Verify the effective relay URL using the [extension configuration guide](../README.md#relay-and-local-configuration), and match the phone's setting. Relay reachability/TLS and current room discovery are separate from process liveness.

## Registry repair and uninstall

The [registry implementation](../src/daemon/registry.ts) owns the accepted shape. Before any manual repair, confirm the supervisor is stopped, privately back up the registry, preserve optional names and validate the proposed JSON. Prefer supported register/remove commands over hand editing.

`remote-pi uninstall` removes the service while retaining its registry. Follow the source setup guide to reinstall intentionally; do not uninstall/reinstall the unrelated upstream npm package as a repair for this checkout.

**Never delete `~/.pi/remote` as a supervisor repair.** It also holds identities, pairing, launcher/PIN configuration and other sessions' state. An intentional identity reset is a separate, explicitly authorized operation with recovery consequences; [secret-handling rules](../../SECURITY.md#secrets-and-local-state) apply.
