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

**Automated alternative:** `.github/workflows/nas-auto-deploy.yml` (`workflow_dispatch`, manual trigger only — added 2026-08-16) runs steps 1-4 above end-to-end: bats → connect to the NAS over Tailscale → back up config volumes (GFS-tiered retention, see `docs/BACKUP.md`) → sync the dispatched branch to the NAS → recreate the changed service(s) → wait for health → `npm run test:e2e` on the NAS → merge to `main` → sync `main` to the NAS. Any failing step stops the pipeline before main is touched, same guarantee as the manual flow. Requires one-time secret setup (`TS_AUTHKEY_CI`, `NAS_SSH_HOST`, `NAS_SSH_USER`, `NAS_SSH_KEY` — see `docs/BACKUP.md`'s *Automated Pre-Deploy Backup* section).

**Live-dispatch verification log (2026-08-16):**
- Run 1 ([31945054751](https://github.com/leonardoazeredo/ultimate-arr-stack/actions/runs/31945054751)) failed at the bats step: `tests/hooks-installed.bats` expects `./setup-hooks.sh` to already have run (it checks for `.git/hooks/pre-commit`/`post-merge` symlinks), which nobody does on a fresh CI checkout — it's a local-dev-machine setup step, not a repo-correctness check. **Fixed** in #21 by running `./setup-hooks.sh` as the first line of the bats step, so the check now verifies the script itself instead of failing for an unrelated reason. Worth remembering generally: a bats/test suite written and only ever run on a maintainer's already-configured machine can quietly assume local state that a clean CI checkout won't have — worth an explicit pass over any test suite before wiring it into CI for exactly this reason.
- Run 2 ([31945201657](https://github.com/leonardoazeredo/ultimate-arr-stack/actions/runs/31945201657)) got past bats and appeared to get past "Connect to Tailscale" and "Configure SSH to NAS", but failed at "Back up config volumes (GFS retention)": `ssh: connect to host *** port 22: Connection timed out`, exit 255, after ~2 minutes stuck on the OS-default TCP connect timeout. Digging into the logs found the earlier "Configure SSH to NAS" pass was a **false positive**: its `ssh-keyscan` retry loop (`for i in 1..10; do ssh-keyscan ... && break; sleep 3; done`) had no check after the loop, so it exited 0 whether or not any attempt actually reached the NAS — the ~80s gap before the next step lines up with all 10 attempts running to exhaustion without ever getting a host key. So this run never actually established SSH connectivity from the ephemeral GitHub-hosted runner to the NAS over Tailscale at all; the underlying "why" (route propagation delay, DERP/NAT-traversal issue from a non-LAN peer, something else) is still open — `tailscale status` locally showed neither peer has ACL tags, so a tag-based ACL restriction isn't the obvious explanation. **Fixed the false-pass** in PR #22: the keyscan loop now hard-fails with a clear error if it never gets a key, dumps `tailscale status`/`tailscale ping` output for diagnosis, and every real `ssh` call in the workflow now carries `-o ConnectTimeout=15` so a genuine failure surfaces in ~15s instead of ~2 minutes. This run was dispatched against `main` itself (no compose diff), so even a clean run would only have verified connectivity, not the compose-recreate path — do a run against a branch with a real compose change once connectivity is confirmed working.
- Snag worth remembering generally: a step that "succeeds" because a retry loop has no post-loop failure check can mask a real problem for several steps until something downstream finally trips over it — worth grep'ing any `for ... do cmd && break; done` pattern for a hard failure check after the loop, not just inside it.

`./scripts/sync-nas.sh` only pulls files — it never recreates containers. After any sync that touches a compose/service file, still recreate that service manually via its own compose file. Every containerized-git invocation on the NAS needs `-c safe.directory=/repo` (git only honors `safe.directory` via `--global` config, never per-repo, so this can't be set once and forgotten) — `leoleg`'s `arrgit` bash alias on the NAS bakes this in for ad hoc use.

**NEVER pass `--remove-orphans` to any `docker compose` command on the NAS.** The stack's services are split across multiple compose files sharing one project name, so compose treats every container from the *other* files as an orphan and deletes them all (this took out 11 containers on 2026-08-01). Likewise, only ever recreate a service via the compose file that defines it — e.g. traefik must go through `docker-compose.traefik.yml` or it loses its `traefik-lan` macvlan and every `.lan` URL dies. See `docs/TROUBLESHOOTING.md`.

Back up a service's config volume before any version bump with a DB migration (`docker run --rm -v <vol>:/src:ro -v <dir>:/bak alpine tar czf /bak/<svc>-config-backup-<stamp>.tgz -C /src .`). Never `docker stop` + ad-hoc `docker run` against a live container's static IP to test — apply the change through compose so the test reflects the real config.

## Tests

Run `npm test` (bats + Playwright) after any change to Docker Compose files, service config, networks, or ports. All tests must pass. `npm run test:bats` is fast, static, and needs no NAS/Docker access — it validates compose files themselves (no duplicate ports/IPs, pinned images, no secrets, `.env.example` in sync, pre-commit hook actually installed) and should catch config bugs before they ever reach the NAS. `npm run test:e2e` (Playwright, run on the NAS itself for full coverage) is split by domain under `tests/e2e/`: UI screenshots, API assertions, VPN egress/leak/killswitch checks, DNS/Traefik routing, addon coverage (Decypharr/Magnetio/stremio-jellyfin), and Gluetun zombie-container resilience checks. Don't hardcode a test count in this doc — that's exactly how the old "14 tests" claim went stale; describe categories instead.
