#!/bin/sh
# Host wrapper: no Docker socket inside the ephemeral ACME container.
set -eu
cd /opt/remote-pi-relay
state=${1:?Use acme-staging or acme-production}
shift
case "$state" in acme-staging|acme-production) ;; *) exit 2 ;; esac
docker run --rm --name remote-pi-relay-certbot \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --memory 256m --cpus 0.5 --pids-limit 128 \
    -v "$PWD/$state/config:/etc/letsencrypt" \
    -v "$PWD/$state/work:/var/lib/letsencrypt" \
    -v "$PWD/webroot:/var/www/acme" \
    certbot/certbot:v5.4.0@sha256:c23159d30afdd9c97960578aa4654f5901de6cae394958f894074dedd55e599d \
    --logs-dir /tmp/letsencrypt "$@"
