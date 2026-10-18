#!/bin/sh
# Static nginx upstream DNS must be refreshed after a relay address change.
set -eu
cd /opt/remote-pi-relay
attempts=15
while ! timeout 5s docker compose exec -T relay \
    curl -fsS --max-time 2 http://127.0.0.1:3000/health 2>/dev/null | grep -qx OK; do
    attempts=$((attempts - 1))
    if [ "$attempts" -eq 0 ]; then
        echo 'ERROR: relay was not ready for nginx reload.' >&2
        exit 1
    fi
    sleep 2
done
timeout 10s docker compose exec -T proxy nginx -t
timeout 10s docker compose exec -T proxy nginx -s reload
