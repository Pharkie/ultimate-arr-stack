# Claude Code Instructions

## NAS Access

SSH credentials are in `.claude/config.local.md`. Read it before running any NAS commands.

## Project Structure

Docker media stack for Ugreen NAS. Edit NAS files (like `pihole/dnsmasq.d/02-local-dns.conf`) **on the NAS**, not locally.

- **Local dev repo**: `/Users/adamknowles/dev/ultimate-arr-stack/`
- **NAS deploy path**: `/volume1/docker/arr-stack/`

## Cross-Stack: Therapy Stack

A separate `therapy-stack` runs at `/volume1/docker/therapy-stack/` on its own network (`therapy-net`, 172.21.0.0/24). Baserow is also on the `arr-stack` network (static IP 172.20.0.20) so Traefik can route to it.

**Files referencing therapy-stack:** `pihole/dnsmasq.d/02-local-dns.conf`, `traefik/dynamic/therapy.local.yml`

**IMPORTANT:** Baserow's static IP (172.20.0.20) is critical. Without it, Docker can assign Gluetun's IP (172.20.0.3) to Baserow on reboot, breaking the VPN stack. The `ip_range: 172.20.0.128/25` in `docker-compose.traefik.yml` confines dynamic IPs to 128-255.

Therapy-stack local repo: `/Users/adamknowles/dev/n8n Therapybot/Git repo/`

## Deploying to the NAS

**The rule (no exceptions): every code change — even a trivial patch image bump — MUST be tested on the NAS and confirmed working BEFORE it reaches `main`.** There is no "trivial" fast-path that skips NAS testing.

This is delivered **branch-first** (resolves the old "test before commit" vs "deploy via git only" tension — confirmed by the user 2026-06-19). **The NAS has no git installed** — deployment is file sync, not `git checkout`:

1. Make the change locally on a **feature branch**, commit, and push the branch.
2. Sync the branch's tracked files to the NAS with `./scripts/sync-nas.sh` (rsync over SSH, touches only `git ls-files` paths — never `.env`/config/volumes), then recreate the affected service(s) via compose (never SCP loose files, never ad-hoc `docker run`).
3. **Verify on the NAS:** container healthy, API/UI responds, migration clean, and `npm run test:e2e` where relevant.
4. Only once it's confirmed working → **merge the branch to `main`** (locally or via `gh pr merge`), then sync `main` to the NAS. A local merge auto-syncs via the `post-merge` hook (`./setup-hooks.sh`); a `gh pr merge` is remote-side and fires no local hook, so immediately follow it with `git fetch origin main && ./scripts/sync-nas.sh` (from a checkout of `main`) — do this every time, not just when asked. Nothing untested ever reaches `main`.
5. If it fails verification → fix on the branch and re-verify, or discard the branch. Re-sync `main` to the NAS with `./scripts/sync-nas.sh` to revert its file copy.

`./scripts/sync-nas.sh` only copies files — it never recreates containers. After any sync that touches a compose/service file, still recreate that service manually via its own compose file.

**NEVER pass `--remove-orphans` to any `docker compose` command on the NAS.** The stack's services are split across multiple compose files sharing one project name, so compose treats every container from the *other* files as an orphan and deletes them all (this took out 11 containers on 2026-08-01). Likewise, only ever recreate a service via the compose file that defines it — e.g. traefik must go through `docker-compose.traefik.yml` or it loses its `traefik-lan` macvlan and every `.lan` URL dies. See `docs/TROUBLESHOOTING.md`.

Back up a service's config volume before any version bump with a DB migration (`docker run --rm -v <vol>:/src:ro -v <dir>:/bak alpine tar czf /bak/<svc>-config-backup-<stamp>.tgz -C /src .`). Never `docker stop` + ad-hoc `docker run` against a live container's static IP to test — apply the change through compose so the test reflects the real config.

## Tests

Run `npm test` (bats + Playwright) after any change to Docker Compose files, service config, networks, or ports. All tests must pass. `npm run test:bats` is fast, static, and needs no NAS/Docker access — it validates compose files themselves (no duplicate ports/IPs, pinned images, no secrets, `.env.example` in sync, pre-commit hook actually installed) and should catch config bugs before they ever reach the NAS. `npm run test:e2e` (Playwright, run on the NAS itself for full coverage) is split by domain under `tests/e2e/`: UI screenshots, API assertions, VPN egress/leak/killswitch checks, DNS/Traefik routing, addon coverage (Decypharr/Magnetio/stremio-jellyfin), and Gluetun zombie-container resilience checks. Don't hardcode a test count in this doc — that's exactly how the old "14 tests" claim went stale; describe categories instead.
