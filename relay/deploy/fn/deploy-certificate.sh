#!/bin/sh
# Called on the host after successful issuance; never install staging material.
set -eu
umask 027
cd /opt/remote-pi-relay
# shellcheck source=/dev/null
. ./.env
proxy_gid=$((CONTAINER_GID_OFFSET + 101))
cert=acme-production/config/live/173.208.50.216
openssl x509 -in "$cert/fullchain.pem" -noout -checkip 173.208.50.216 >/dev/null
openssl x509 -in "$cert/fullchain.pem" -noout -checkend 172800 >/dev/null
# Immutable generation and atomic directory link keep key/certificate paired.
generation=$(openssl x509 -in "$cert/fullchain.pem" -outform DER | sha256sum | cut -d ' ' -f1)
install -d -m 750 -o root -g "$proxy_gid" "tls/$generation"
install -m 640 -o root -g "$proxy_gid" "$cert/fullchain.pem" "tls/$generation/fullchain.pem"
install -m 640 -o root -g "$proxy_gid" "$cert/privkey.pem" "tls/$generation/privkey.pem"
previous=$(readlink tls/current || true)
ln -s "$generation" tls/current.new
mv -Tf tls/current.new tls/current
if ! ./reload-proxy.sh; then
    if [ -n "$previous" ]; then
        ln -s "$previous" tls/current.new
        mv -Tf tls/current.new tls/current
    fi
    exit 1
fi
printf '%s\n' 'Production TLS configuration validated and reloaded.'
