# Claude Code Instructions

## NAS Access

SSH credentials are in `.claude/config.local.md`. Read it before running any NAS commands.

## Project Structure

Docker media stack for Ugreen NAS. Edit NAS files (like `pihole/dnsmasq.d/02-local-dns.conf`) **on the NAS**, not locally.

- **Local dev repo**: `/Users/adamknowles/dev/ultimate-arr-stack/`
- **NAS deploy path**: `/volume1/docker/arr-stack/`

## Cross-Stack: Therapy Stack

**Unverified / likely stale on this NAS as of 2026-08-15.** This section describes a `therapy-stack`/Baserow coupling that was checked directly on the live NAS before the arr-core network rename (Phase 2 of the segmentation plan) and found not to exist: no `baserow` container, no `172.20.0.20` binding on the network, no `/volume1/docker/therapy-stack/` directory, and no `traefik/dynamic/therapy.local.yml` file. This may describe a different deployment (the local dev repo path below is also for a different user/machine) rather than this one. Re-verify on the live NAS before relying on any of the following if this setup ever does need to interoperate with a therapy-stack deployment:

A separate `therapy-stack` would run at `/volume1/docker/therapy-stack/` on its own network (`therapy-net`, 172.21.0.0/24), with Baserow on the `arr-core` network (formerly `arr-stack`) at static IP 172.20.0.20 so Traefik can route to it. Files that would reference it: `pihole/dnsmasq.d/02-local-dns.conf`, `traefik/dynamic/therapy.local.yml`. If it does exist, Baserow's static IP matters for the same reason every other static IP in `docker-compose.arr-stack.yml` is pinned: the `ip_range: 172.20.0.128/25` confines Docker's dynamic allocation to `.128`-`.255`, so a manually-added container needs an explicit IP outside that range or it risks colliding with a dynamically-assigned one (e.g. Gluetun's `.3`) on restart.

Therapy-stack local repo (unverified, different user's machine): `/Users/adamknowles/dev/n8n Therapybot/Git repo/`

## Deploying to the NAS

**The rule (no exceptions): every code change — even a trivial patch image bump — MUST be tested on the NAS and confirmed working BEFORE it reaches `main`.** There is no "trivial" fast-path that skips NAS testing.

This is delivered **branch-first** (resolves the old "test before commit" vs "deploy via git only" tension — confirmed by the user 2026-06-19). **Native git can't be installed on the NAS's OS** (`apt-get install git` fails on unmet deps tangled with unrelated vendor-pinned packages — never force it with `apt --fix-broken install`, that risks cascading into Ugreen's pinned packages). Real git still works there via a containerized `alpine/git` image bind-mounted onto the deploy path — bootstrapped 2026-08-15, `origin` points at the fork. Deployment is `git pull`, not file copying:

1. Make the change locally on a **feature branch**, commit, and push the branch.
2. Sync the branch to the NAS with `./scripts/sync-nas.sh` (checks out and fast-forwards to your current local branch on the NAS through the containerized git — never `.env`/config/volumes, those aren't tracked), then recreate the affected service(s) via compose (never SCP loose files, never ad-hoc `docker run`).
3. **Verify on the NAS:** container healthy, API/UI responds, migration clean, and `npm run test:e2e` where relevant.
4. Only once it's confirmed working → **merge the branch to `main`** (locally or via `gh pr merge`), then sync `main` to the NAS. A local merge auto-syncs via the `post-merge` hook (`./setup-hooks.sh`); a `gh pr merge` is remote-side and fires no local hook, so immediately follow it with `git fetch origin main && ./scripts/sync-nas.sh` (from a checkout of `main`) — do this every time, not just when asked. Nothing untested ever reaches `main`.
5. If it fails verification → fix on the branch and re-verify, or discard the branch. Re-sync `main` to the NAS with `./scripts/sync-nas.sh` to bring it back.

**Automated alternative:** `.github/workflows/nas-auto-deploy.yml` (`workflow_dispatch`, manual trigger only — added 2026-08-16) runs steps 1-4 above end-to-end: bats → connect to the NAS over Tailscale → back up config volumes (GFS-tiered retention, see `docs/BACKUP.md`) → sync the dispatched branch to the NAS → recreate the changed service(s) → wait for health → `npm run test:e2e` on the NAS → merge to `main` → sync `main` to the NAS. Any failing step stops the pipeline before main is touched, same guarantee as the manual flow. Requires one-time secret setup (`TS_AUTHKEY_CI`, `NAS_SSH_HOST`, `NAS_SSH_USER`, `NAS_SSH_KEY` — see `docs/BACKUP.md`'s *Automated Pre-Deploy Backup* section) and hasn't yet had a live end-to-end run to confirm the secrets/ACLs are correctly configured — treat its first run as a verification run, not a routine one, and fall back to the manual steps above if it fails for an infra reason (Tailscale ACL, SSH key) rather than a real test failure.

`./scripts/sync-nas.sh` only pulls files — it never recreates containers. After any sync that touches a compose/service file, still recreate that service manually via its own compose file. Every containerized-git invocation on the NAS needs `-c safe.directory=/repo` (git only honors `safe.directory` via `--global` config, never per-repo, so this can't be set once and forgotten) — `leoleg`'s `arrgit` bash alias on the NAS bakes this in for ad hoc use.

**NEVER pass `--remove-orphans` to any `docker compose` command on the NAS.** The stack's services are split across multiple compose files sharing one project name, so compose treats every container from the *other* files as an orphan and deletes them all (this took out 11 containers on 2026-08-01). Likewise, only ever recreate a service via the compose file that defines it — e.g. traefik must go through `docker-compose.traefik.yml` or it loses its `traefik-lan` macvlan and every `.lan` URL dies. See `docs/TROUBLESHOOTING.md`.

Back up a service's config volume before any version bump with a DB migration (`docker run --rm -v <vol>:/src:ro -v <dir>:/bak alpine tar czf /bak/<svc>-config-backup-<stamp>.tgz -C /src .`). Never `docker stop` + ad-hoc `docker run` against a live container's static IP to test — apply the change through compose so the test reflects the real config.

## Tests

Run `npm test` (bats + Playwright) after any change to Docker Compose files, service config, networks, or ports. All tests must pass. `npm run test:bats` is fast, static, and needs no NAS/Docker access — it validates compose files themselves (no duplicate ports/IPs, pinned images, no secrets, `.env.example` in sync, pre-commit hook actually installed) and should catch config bugs before they ever reach the NAS. `npm run test:e2e` (Playwright, run on the NAS itself for full coverage) is split by domain under `tests/e2e/`: UI screenshots, API assertions, VPN egress/leak/killswitch checks, DNS/Traefik routing, addon coverage (Decypharr/Magnetio/stremio-jellyfin), and Gluetun zombie-container resilience checks. Don't hardcode a test count in this doc — that's exactly how the old "14 tests" claim went stale; describe categories instead.
