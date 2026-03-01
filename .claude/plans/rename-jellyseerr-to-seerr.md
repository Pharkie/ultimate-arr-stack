# Plan: Rename `jellyseerr` → `seerr` (container, volume, all references)

## Context

Seerr v3 rebranded from Jellyseerr but the container name, volume name, and many references were left as `jellyseerr` for "backwards compatibility." The user wants a clean rename throughout -- the UGOS Docker manager shows the old name, docs reference the old name, etc.

## Part 1: Docker Compose Changes — DONE (646de8d)

`docker-compose.arr-stack.yml`:
- `jellyseerr-config:` → `seerr-config:` (volume definition)
- `jellyseerr:` → `seerr:` (service name)
- `container_name: jellyseerr` → `container_name: seerr`
- `jellyseerr-config:/app/config` → `seerr-config:/app/config` (volume mount)

## Part 2: NAS Volume Migration — DONE

Docker named volume `arr-stack_jellyseerr-config` → `arr-stack_seerr-config`:

1. Stop the stack
2. Create new volume and copy data:
   ```bash
   docker volume create arr-stack_seerr-config
   docker run --rm \
     -v arr-stack_jellyseerr-config:/source:ro \
     -v arr-stack_seerr-config:/dest \
     alpine sh -c "cp -a /source/. /dest/"
   ```
3. Restart stack (with updated compose file)
4. Verify Seerr works, then remove old volume:
   ```bash
   docker volume rm arr-stack_jellyseerr-config
   ```

## Part 3: Traefik Config — DONE (646de8d)

Legacy redirect routers/middleware in `traefik/dynamic/local-services.yml` and `traefik/dynamic/vpn-services.yml.example` STAY as-is (they intentionally redirect `jellyseerr.lan` → `seerr.lan`). No changes needed.

## Part 4: Pi-hole DNS — DONE (646de8d)

`pihole/02-local-dns.conf.example` — The `jellyseerr.lan` entry STAYS (needed for the redirect to work). No changes.

## Part 5: Scripts — DONE (646de8d)

- `scripts/arr-backup.sh`: Changed volume detection from `jellyseerr-config` to `seerr-config` (kept `overseerr-config` fallback)
- `scripts/lib/check-domains.sh`: Kept `jellyseerr.lan` in domain check list (for redirect validation)

## Part 6: Documentation Updates — DONE (646de8d)

- `docs/BACKUP.md` — volume table, restore example, request manager detection
- `docs/RESTORE.md` — single volume restore example
- `docs/UTILITIES.md` — Uptime Kuma monitor URL, removed "container name is still jellyseerr" note
- `docs/UPGRADING.md` — v1.7 step 9 references
- `.claude/instructions.md` — backup description
- `.gitignore` — `jellyseerr/` → `seerr/`

## Part 7: Files that DON'T change — DONE (646de8d)

- `CHANGELOG.md` — historical records, leave as-is
- `traefik/dynamic/local-services.yml` — legacy redirect routers stay
- `traefik/dynamic/vpn-services.yml.example` — legacy redirect routers stay
- `pihole/02-local-dns.conf.example` — `jellyseerr.lan` DNS entry stays for redirect
- `scripts/lib/check-domains.sh` — `jellyseerr.lan` stays in check list
- `.claude/settings.local.json` — dev-only
- `tests/e2e/stack.spec.ts` — no jellyseerr references (already uses "seerr")

## Part 8: Uptime Kuma Monitor — DONE

After rename, update Uptime Kuma monitor URL from `http://jellyseerr:5055/api/v1/status` to `http://seerr:5055/api/v1/status` in the UI.

## Verification

1. After NAS migration: `npm run test:e2e` — all tests should pass
2. Spot-check: `docker ps | grep seerr` shows container named `seerr`
3. Spot-check: `seerr.lan` loads in browser
