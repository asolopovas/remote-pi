#!/bin/sh
# Failure is visible in the systemd unit/journal, not sent to an invented contact.
set -eu
umask 077
cd /opt/remote-pi-relay
attempts=3
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 2 ;;
    --wait-for-deployment) [ "$#" -eq 1 ] || exit 2; attempts=15 ;;
    *) exit 2 ;;
esac
minimum=${REMOTEPI_MIN_CERT_SECONDS:-172800}
cert=acme-production/config/live/173.208.50.216/fullchain.pem
openssl x509 -in "$cert" -noout -checkend "$minimum" >/dev/null || {
    echo 'ERROR: relay certificate expires within the configured safety window.' >&2
    exit 1
}
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT HUP INT TERM
openssl x509 -in "$cert" -outform DER -out "$state/expected.der"
check_served() {
    # Explicit trust, IP verification, TLS1.3 and bounded network operations.
    curl --fail --silent --max-time 5 --connect-timeout 3 --tlsv1.3 --tls-max 1.3 \
        https://173.208.50.216/health > "$state/health" || return 1
    grep -qx OK "$state/health" || return 1
    timeout 5s openssl s_client -connect 173.208.50.216:443 -tls1_3 \
        -verify_ip 173.208.50.216 -verify_return_error </dev/null \
        > "$state/chain.pem" 2>/dev/null || return 1
    openssl x509 -in "$state/chain.pem" -outform DER -out "$state/served.der" \
        2>/dev/null || return 1
    openssl x509 -in "$state/chain.pem" -noout -checkend "$minimum" \
        >/dev/null 2>&1 || return 1
    # DER equality identifies the intended certificate, not merely its expiry.
    cmp -s "$state/expected.der" "$state/served.der"
}
while [ "$attempts" -gt 0 ]; do
    if check_served; then
        printf '%s\n' 'Relay trusted HTTPS, exact production certificate and expiry checks passed.'
        exit 0
    fi
    attempts=$((attempts - 1))
    [ "$attempts" -eq 0 ] || sleep 2
done
echo 'ERROR: trusted relay health/exact production certificate verification failed.' >&2
exit 1
