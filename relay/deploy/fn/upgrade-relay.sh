#!/bin/sh
# Use for both upgrades and rollback after setting the pinned RELAY_IMAGE in .env.
set -eu
cd /opt/remote-pi-relay
docker compose up -d --no-deps relay
./reload-proxy.sh
./check.sh --wait-for-deployment
