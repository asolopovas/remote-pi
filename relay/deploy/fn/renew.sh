#!/bin/sh
set -eu
cd /opt/remote-pi-relay
exec 9>/run/lock/remote-pi-relay-acme.lock
flock -n 9 || exit 0
marker=acme-production/work/deploy-required
deploy_pending() {
    if [ -f "$marker" ]; then
        # This function is called conditionally: do not rely on errexit inside it.
        ./deploy-certificate.sh || return 1
        # Keep pending state until trusted HTTPS serves this exact production cert.
        ./check.sh --wait-for-deployment || return 1
        rm -f "$marker" || return 1
    fi
    return 0
}
status=0
# Check issuance first: an aging/rejected pending cert must never block renewal.
# Still recover valid pending deployment if ACME fails or no issuance is needed.
./certbot.sh acme-production renew --non-interactive "$@" || status=1
deploy_pending || status=1
./check.sh || status=1
exit "$status"
