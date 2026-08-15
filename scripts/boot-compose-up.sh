#!/bin/sh
# Reconcile every deployed compose stack after a reboot or a UGOS update.
#
# Why this exists: Docker's `restart: always` is not enough. A UGOS update on
# 5 Aug 2026 left every container *running* but with its published ports never
# established — Pi-hole reported healthy (its healthcheck digs 127.0.0.1 from
# inside the container, so it passes even when nothing outside can reach it)
# while nothing was listening on 10.10.0.10:53. DNS was down for the whole house
# and the NAS looked fine from `docker ps`.
#
# `docker compose up -d` reconciles each container against its compose file and
# re-establishes the port bindings, which is the part a restart misses.
#
# Deliberately NOT using --remove-orphans: containers from the other compose
# files in the same directory look like orphans to each individual file, and it
# would delete them.

LOG=/volume1/docker/boot-compose-up.log

# Keep the log bounded without needing logrotate.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

exec >> "$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') boot bring-up ==="

# Cron fires @reboot before Docker is necessarily accepting connections.
i=0
while ! docker info >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "docker never became ready after 5 minutes — giving up"
        exit 1
    fi
    sleep 5
done
echo "docker ready after $((i * 5))s"

# Order matters across files: DNS (pihole/dnscrypt) and Traefik come up first so
# everything after them can resolve names and be routed.
STACKS="
/volume1/docker/arr-stack/docker-compose.arr-stack.yml
/volume1/docker/arr-stack/docker-compose.traefik.yml
/volume1/docker/arr-stack/docker-compose.utilities.yml
/volume1/docker/arr-stack/docker-compose.tailscale.yml
/volume1/docker/arr-stack/docker-compose.cloudflared.yml
/volume1/docker/frigate/docker-compose.frigate.yml
/volume1/docker/immich/docker-compose.yml
/volume1/docker/therapy-stack/docker-compose.nas.yml
"

failed=""
for f in $STACKS; do
    [ -f "$f" ] || { echo "--- SKIP (missing): $f"; continue; }
    echo "--- $f"
    # One stack failing must not stop the rest — DNS matters more than Immich.
    if ! (cd "$(dirname "$f")" && docker compose -f "$(basename "$f")" up -d 2>&1); then
        echo "FAILED: $f"
        failed="$failed $f"
    fi
done

if [ -n "$failed" ]; then
    echo "=== finished WITH FAILURES:$failed"
else
    echo "=== finished clean $(date '+%H:%M:%S')"
fi
