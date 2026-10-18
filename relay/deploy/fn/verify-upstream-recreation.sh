#!/bin/sh
# Isolated fn fixture: no public ports, production mounts, certs or membership.
set -eu
cd /opt/remote-pi-relay
# shellcheck source=/dev/null
. ./.env
project=remote-pi-relay-upstream-check
network=$project-network
if docker network inspect "$network" >/dev/null 2>&1 || \
    [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]; then
    echo 'ERROR: upstream fixture already exists; refusing to reuse it.' >&2
    exit 1
fi
fixture=$(mktemp -d)
chmod 755 "$fixture"
cleanup() {
    docker compose -p "$project" -f "$fixture/compose.yaml" down >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM
# Match production's named bridge isolation without changing HERMES firewall rules.
docker network create --internal --opt com.docker.network.bridge.name=rpi-up-test \
    "$network" >/dev/null
subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$network")
old_ip=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1])[10])' "$subnet")
new_ip=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1])[11])' "$subnet")
cat > "$fixture/nginx.conf" <<'NGINX'
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr crit;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path /tmp/client;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 8080;
        location /health { proxy_pass http://relay:3000; }
    }
}
NGINX
cat > "$fixture/compose.yaml" <<YAML
services:
  relay:
    image: $RELAY_IMAGE
    pull_policy: never
    user: "10001:10001"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    environment: {RUST_LOG: error}
    tmpfs: ["/data:rw,noexec,nosuid,size=8m,uid=10001,gid=10001,mode=700"]
    mem_limit: 256m
    cpus: 0.5
    pids_limit: 64
    networks:
      fixture:
        ipv4_address: \${BACKEND_IP}
  proxy:
    image: >-
      nginx:1.28-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236
    user: "101:101"
    entrypoint: [nginx]
    command: [-g, "daemon off;"]
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    tmpfs: ["/tmp:rw,noexec,nosuid,size=8m,uid=101,gid=101,mode=700"]
    volumes: ["./nginx.conf:/etc/nginx/nginx.conf:ro"]
    mem_limit: 64m
    cpus: 0.5
    pids_limit: 32
    networks: [fixture]
networks:
  fixture:
    external: true
    name: $network
YAML
# Run the exact checked-in readiness/validation/reload helper, changing only cwd.
sed "s|cd /opt/remote-pi-relay|cd $fixture|" reload-proxy.sh > "$fixture/reload-proxy.sh"
printf 'BACKEND_IP=%s\nCOMPOSE_PROJECT_NAME=%s\n' "$old_ip" "$project" > "$fixture/.env"
cd "$fixture"
docker compose up -d relay >/dev/null
actual_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(docker compose ps -q relay)")
[ "$actual_ip" = "$old_ip" ]
attempts=15
until timeout 5s docker compose exec -T relay curl -fsS --max-time 2 http://127.0.0.1:3000/health 2>/dev/null | grep -qx OK; do
    attempts=$((attempts - 1)); [ "$attempts" -gt 0 ] || exit 1
    sleep 1
done
docker compose up -d proxy >/dev/null
sh ./reload-proxy.sh
health() {
    timeout 5s docker compose exec -T proxy wget -q -T 3 -O - http://127.0.0.1:8080/health 2>/dev/null | grep -qx OK
}
attempts=15
until health; do
    attempts=$((attempts - 1)); [ "$attempts" -gt 0 ] || exit 1
    sleep 1
done
printf 'BACKEND_IP=%s\nCOMPOSE_PROJECT_NAME=%s\n' "$new_ip" "$project" > .env
docker compose up -d --no-deps --force-recreate relay >/dev/null
actual_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(docker compose ps -q relay)")
[ "$actual_ip" = "$new_ip" ] && [ "$old_ip" != "$new_ip" ]
# Wait for the new backend; nginx still has the old address until this reload.
attempts=15
until timeout 5s docker compose exec -T relay curl -fsS --max-time 2 http://127.0.0.1:3000/health 2>/dev/null | grep -qx OK; do
    attempts=$((attempts - 1)); [ "$attempts" -gt 0 ] || exit 1
    sleep 1
done
if health; then
    echo 'ERROR: expected stale static nginx upstream before reload.' >&2
    exit 1
fi
sh ./reload-proxy.sh
attempts=15
until health; do
    attempts=$((attempts - 1)); [ "$attempts" -gt 0 ] || exit 1
    sleep 1
done
printf 'PASS: isolated backend %s -> %s; stale upstream reproduced; checked readiness/reload restored routing.\n' "$old_ip" "$new_ip"
