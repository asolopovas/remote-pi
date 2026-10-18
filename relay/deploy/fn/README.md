# fn: trusted IP-only Remote Pi Relay

[Project index](../../../README.md#project-map) · [Relay guide](../../README.md)

Dedicated deployment: `/opt/remote-pi-relay` on SSH alias `fn`.
Client endpoint: **`wss://173.208.50.216`**. Health: `https://173.208.50.216/health`.
This deployment worker changed no client pairing, identity, or existing relay URL.
Other clients/verifiers began publishing membership during acceptance; their state
was preserved. Client activation status belongs to the coordinating session.

Only nginx publishes IPv4 ports 80 and 443. HTTP serves strictly ACME challenges
(other paths return 404); TLS is **1.3 only**. The non-root Relay has no published
port and only an internal backend network. Both services use read-only roots,
dropped capabilities, no-new-privileges, bounded logs and resource limits.
`/data` is the external named volume `remote-pi-relay-data`, not deleted by
`docker compose down`. nginx's only writable filesystem is a bounded `/tmp`.
Access logging is off; Relay logging is error-only to avoid client metadata logs.
HTTP handshake/membership requests and active connections have per-IP nginx limits.

TLS is essential: this protocol does **not** provide E2E encryption. The operator,
Docker daemon and other workloads on the host remain in the trust boundary.
Do not add Basic Auth/mTLS, use `-k`, expose port 3000, or install staging certs.

## Provenance (deployed 2026-10-14 UTC)

Locked local Relay **0.3.1** was built instead of assuming the upstream image
contains the local fork's protocol changes. Source revision:
`ff65bf0b245bec752d280fd3c195cde92e552578` (`readable-android-fonts`).
`source.sha256` covers every input Rust source, migration, Cargo manifest and lock.
Build command, from the root of the staged relay source:

```sh
docker build --build-arg SOURCE_REVISION=ff65bf0b245bec752d280fd3c195cde92e552578 \
  -f deploy/fn/Dockerfile -t remote-pi-relay:ff65bf0 .
```

`--locked` is used; build/runtime base images and nginx/Certbot are digest-pinned.
The local image has **no registry manifest digest** (no upload was performed).
Compose pins its immutable image configuration ID with `pull_policy: never`:

| Artifact | Deployed identifier |
|---|---|
| Relay image ID | `sha256:e4d6c951eb1e43d0fee7d083b622edd3516fe7d8c8bad600a2314ca961c5cc3b` |
| Relay executable SHA-256 | `9e2a7d4403c7aec32162d92541682693f1fc60af710e845ec2a3e8a9b3187607` |
| Cargo.lock SHA-256 | `2f8c74677e7de95686c2122a6c5477bd7e295aab3858002046e6c71cf03eb2df` |
| nginx 1.28.3 image digest | `sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236` |
| Certbot 5.4.0 image digest | `sha256:c23159d30afdd9c97960578aa4654f5901de6cae394958f894074dedd55e599d` |
| Rust 1.94.0 builder digest | `sha256:a86cada82e36ebd7a9bffed7548792c55a952fdb20718eea9278a936bcb76e62` |
| Debian bookworm-slim digest | `sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587` |
| Saved Relay image tar SHA-256 | `f92560ae5711fd3361c753f79a0a857625a56d426d5797f3f94c671cf2d279d3` |

The build installed curl/libcurl `7.88.1-10+deb12u15` and ca-certificates
`20250419~deb12u1`. Future builds may get newer Debian packages and different image
IDs; retain the saved image for byte-exact rollback. Do not silently reuse a tag.
The initial `.env`, Compose and nginx configuration are also retained in the
root-only `rollback-ff65bf0/` directory on fn.

## Certificates and bootstrap

Official guidance:
- [Let's Encrypt IP certificates / Certbot 5.4 webroot](https://letsencrypt.org/2026/03/11/shorter-certs-certbot.html)
- [Certbot renewal/deploy hooks](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates)
- [nginx WebSocket forwarding](https://nginx.org/en/docs/http/websocket.html)
- [nginx TLS protocols](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_protocols)

The reviewed ACME terms are [Subscriber Agreement 1.8, 2026-07-06](https://letsencrypt.org/documents/LE-SA-v1.8-July-06-2026.pdf).
Registration used supported Certbot 5.4 `--email ""`, not an invented contact.
Maintain control of the IP and keys; revoke on loss of control/compromise.
Certificate identifiers are public through certificate transparency.

Separate `acme-staging/{config,work}` and
`acme-production/{config,work}` prevent staging replacement. Certbot debug logs
remain only in the ephemeral container's `/tmp`, not persistent logs or reports.
Bootstrap uses
`nginx-bootstrap.conf` (HTTP ACME only, no TLS or relay forwarding). Initial issuance:

```sh
# Run as root, from /opt/remote-pi-relay, after provisioning directories/container.
./certbot.sh acme-staging certonly --staging --non-interactive --agree-tos \
  --email "" --preferred-profile shortlived --webroot \
  --webroot-path /var/www/acme --ip-address 173.208.50.216 \
  --cert-name 173.208.50.216
./certbot.sh acme-production certonly --non-interactive --agree-tos \
  --email "" --preferred-profile shortlived --webroot \
  --webroot-path /var/www/acme --ip-address 173.208.50.216 \
  --cert-name 173.208.50.216 --deploy-hook 'touch /var/lib/letsencrypt/deploy-required'
# Install nginx.conf into nginx/nginx.conf; deploy copies the cert before nginx -t.
./deploy-certificate.sh
./check.sh --wait-for-deployment
```

The host has Docker user-namespace remapping: container UID/GID 0 maps to host
100000. Writable ACME directories/webroot belong to host `100000:100000`, the
700 data volume to `110001:110001` (container 10001), and copied key files to
`root:100101` with mode 640 (container nginx group 101). TLS generation directories
are 750; parent `tls` is 711. Do not disable userns or loosen key permissions.
Check `/proc/self/uid_map` and `/proc/self/gid_map` before provisioning on a different
host. Root-owned `.env` contains only `RELAY_IMAGE`, `CONTAINER_UID_OFFSET=100000`,
and `CONTAINER_GID_OFFSET=100000`. nginx mounts only copied production TLS material,
**not** ACME account state. No Docker socket is mounted into any container.

Initial production certificate: Let's Encrypt **YE1**, IP SAN **173.208.50.216**,
valid **2026-10-14 00:01:49 UTC → 2026-10-20 16:01:48 UTC**. These dates change
on real renewal. The public chain was validated using ordinary system trust.

## Renewal and expiry checks

Host systemd timers are enabled/persistent:
- `remote-pi-relay-renew.timer`: every six hours, up to 15 minutes jitter.
- `remote-pi-relay-check.timer`: hourly, up to five minutes jitter.

Certbot also randomizes renew checks. The renewal wrapper locks concurrent runs;
its saved deploy hook creates a marker **only on successful issuance**. Pending
state survives any deployment/post-check failure. The wrapper checks ACME issuance
**first**, so an aging pending certificate rejected by the 48-hour safety window
cannot block its replacement. It then retries pending deployment even when ACME
fails or no new issuance is needed, explicitly retaining failures and the marker
until deployment/verification succeeds. Any ACME, deployment or final-check
failure returns nonzero; a valid pending cert can still be installed after an ACME
failure. The host installs an atomic TLS
generation link, waits for relay readiness, validates/reloads nginx, then checks
trusted HTTPS, **disk and served expiry ≥48 hours**, and **DER equality of the
served leaf certificate to the exact intended production certificate**. Only then
is the marker cleared. Certbot exit zero without new or pending state does not
trigger a reload. Checks use three bounded attempts normally, or fifteen with
`--wait-for-deployment` (two-second pauses, five-second network limits), allowing
graceful nginx reload/readiness races without an unlimited loop.

```sh
ssh fn 'cd /opt/remote-pi-relay; sudo ./renew.sh --dry-run --run-deploy-hooks --no-random-sleep-on-renew'
ssh fn 'sudo systemctl start remote-pi-relay-check.service; sudo systemctl list-timers remote-pi-relay-*'
ssh fn 'sudo journalctl -u remote-pi-relay-renew.service -u remote-pi-relay-check.service --since today'
```

Dry-run uses staging validation but the host deploy script reads **production only**.
Failures return nonzero and are visible as failed systemd units/journal entries.
There is **no off-host/email/pager notification destination configured**; an
operator must watch these units or enroll them in existing monitoring. No contact
or external monitoring credentials were invented. Short-lived certificates require
prompt response. Do not revoke/discard a working certificate during investigation.

## Backup, isolated restore and rollback

```sh
ssh fn 'cd /opt/remote-pi-relay; sudo ./backup.sh'
```

Uses SQLite's online backup API plus integrity check; backups are root-only under
`backups/`. No live database file copying. Backups contain signed membership
metadata, never traffic. Keep encrypted off-host copies using the operator's
existing backup mechanism (not configured here). `verify.py` exercises a backup
restored into a temporary volume and restricted, network-none Relay container,
checks `/health` and the signed `/mesh` row, then removes the temporary volume,
container and synthetic snapshot. The production synthetic Owner row is deleted
with a parameterized exact hash, even on probe failure.

Rollback without changing membership (from `/opt/remote-pi-relay`, as root):
1. Run `./backup.sh`. Preserve `.env`, compose and nginx config before each upgrade.
2. `docker load -i images/relay-ff65bf0.tar` if the previous local image was pruned;
   verify the tar checksum above and the loaded immutable image ID.
3. Set `.env` `RELAY_IMAGE` to the previous recorded ID; leave offsets intact.
4. Run **`./upgrade-relay.sh` for both upgrades and rollback**. It recreates only
   relay if needed, waits for its health, validates/reloads nginx, and verifies
   trusted health plus the exact production certificate with bounded retries.
   nginx resolves the static `relay` upstream on reload: never recreate relay and
   omit this reload, since its Docker address may change. The isolated address-change
   fixture below tests that failure and recovery without touching production.
   Retain the **current valid production certificate**; do not roll back expired TLS.
5. If a database restore is required, stop **only relay**, preserve the current DB
   and any journal as a recovery set, copy a verified consistent backup into the
   data volume, restore `110001:110001` ownership/600 permissions, remove any stale
   journal from the restored target, and start relay. Then run `./reload-proxy.sh`
   and `./check.sh --wait-for-deployment`. Never overwrite a live DB.

To take this dedicated endpoint offline: disable its two timers and
`docker compose down` **without** removing its external volume or ACME state.
No host reboot, firewall flush, unrelated container/service stop, or SSH changes.

## Validation

From `relay/`:

```sh
cargo test --locked
cargo clippy --locked -- -D warnings
cargo fmt --check
shellcheck deploy/fn/*.sh
for script in deploy/fn/*.sh; do sh -n "$script"; done
yamllint deploy/fn/compose.yaml
RELAY_IMAGE=sha256:e4d6c951eb1e43d0fee7d083b622edd3516fe7d8c8bad600a2314ca961c5cc3b \
  docker compose -f deploy/fn/compose.yaml config -q
python3 -m unittest discover -s deploy/fn -p 'test_*.py' -v
# Requires Python cryptography + websockets (tested 41.0.7 / 10.4), PyYAML for unit tests.
# Only during an authorized maintenance window: this restarts the live relay/proxy.
python3 deploy/fn/verify.py --ssh-host fn
# Isolated address-change regression; no production restart, ports or data mounts.
ssh fn 'cd /opt/remote-pi-relay; sudo ./verify-upstream-recreation.sh'
```

The probe validates trusted TLS/IP SAN, WSS, Ed25519 auth, invalid auth and
membership rejection, outer and authorized Pi routing, unauthorized route denial,
mesh POST/GET/version/since behavior, heartbeat, restart/reconnect/persistence,
and isolated backup/restore. Keys exist only in process memory; payloads are not
reported. Its HTTP helper uses an explicitly trusted TLS1.3 urllib opener with
environment proxies disabled, redirects refused (including downgrade), preserved
403/409/304 statuses and socket timeouts. Invalid JSON errors include context, not
payload or decoder exception details. Offline tests cover these properties,
issuance → failed deployment → no-new-issuance retry, aging-pending replacement
through ACME, retained markers after failed deploy/post-check, non-masked ACME and
final-check failures, and rejection of an old but still-unexpired served certificate.
Independently test rejected TLS1.0/1.1/1.2 with OpenSSL (use
`-cipher 'ALL:@SECLEVEL=0'` for old versions so the client sends a handshake),
HTTP 404s on `/`, `/health`, `/mesh/*`, ACME-only challenge retrieval, and external
port 3000 timeout/refusal. fn has global IPv6 but neither container publishes any
IPv6 port; the executor has no IPv6 route, so an external IPv6 probe remains an
independent-network check, not a claimed successful test.
