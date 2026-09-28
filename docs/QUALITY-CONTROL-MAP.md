# Quality control map

For each part of the stack: which check covers it, where that check runs, whether a failure stops anything, and when the check quietly doesn't run. Everything here was read off the code, not off the docs that describe it.

## Where checks run

| Surface | What it runs | When | A failure |
|---|---|---|---|
| **Hook** | `scripts/pre-commit`: eleven checks from `scripts/lib/check-*.sh` | `git commit`, once `./setup-hooks.sh` has linked it into the common git dir | aborts the commit if a blocking check fails; warn-only checks print and pass. `--no-verify` skips the lot |
| **Local bats** | `./tests/run-tests.sh`: every `tests/*.bats` | by hand | a red run that only you see |
| **CI required** | `bats suite` (the same bats run), `lint (actionlint, hadolint, shellcheck warnings)`, `supply chain (trivy, sbom)` | PR to `main`, push to `main`, manual dispatch | branch protection won't merge the PR |
| **CI nightly** | `nightly — trivy over every compose image`, `nightly — the devcontainer builds` | daily 03:23 UTC, and manual dispatch | a red run; never gates anything |
| **e2e** | `npm run test:e2e`: Playwright specs in `tests/e2e/` against the live stack | by hand, with `.env.e2e` | a red run that only you see |
| **Renovate** | `renovate.json` | before 9am Monday (Europe/London), if the Renovate app is installed | opens a PR whose body says to test on the NAS first |
| **NAS** | by hand: the rule in [CLAUDE.md](../CLAUDE.md#deploying-to-the-nas) and the [pre-release checklist](../CONTRIBUTING.md#pre-release-checklist). By cron, if you install it: `check-vpn.sh` feeding a Kuma push monitor ([UTILITIES.md](UTILITIES.md#the-vpn-check-and-why-it-is-a-push-monitor)) | every change, before `main` | the branch shouldn't merge. Nothing enforces that |

## Capability map

**blocks** stops the commit or merge. **fails** is a red result only whoever ran it sees. **warns** prints and passes. Blank: not checked there.

| Capability | Hook | Local bats | CI required | CI nightly | e2e | Renovate | NAS |
|---|---|---|---|---|---|---|---|
| **Compose model** | | | | | | | |
| Compose files render (each file alone, every profile) | blocks² | fails | blocks | | | | `compose up` |
| Host ports and static IPs unique | blocks² | fails² | blocks² | | | | |
| Static IPs in `172.20.0.0/24` or `10.8.1.0/24`; `arr-stack` subnet, `ip_range`, gateway pinned; static IPs outside `ip_range` | | fails | blocks | | | | `docker network inspect` for the neighbour's reserved IP |
| Project `name:` pinned; the core three share `arr-stack` | | fails | blocks | | | | |
| Named volumes pinned with `name:` | | fails | blocks | | | | |
| Restart policy, logging, container posture³ | | fails | blocks | | | | |
| **Images** | | | | | | | |
| Tagged, never `:latest` | | fails | blocks | | | | |
| Tag exists on its registry | | fails | blocks | | | | `docker compose pull` |
| Newer version available | warns | | | | | opens PRs | |
| CVEs in the images | | | | reports | | | |
| **VPN** | | | | | | | |
| Download clients inside gluetun's namespace (compose)⁴ | | fails | blocks | | | | |
| Scripts' and e2e's tunnelled lists match compose⁵ | | fails | blocks | | | | |
| OpenVPN tunnel comes up with the granted capabilities | | fails | blocks | | | | |
| Egress: gluetun ≠ NAS, each tunnelled service = gluetun, Sonarr/Radarr ≠ gluetun | | | | | fails | | cron `check-vpn.sh` |
| Dependents on gluetun's current namespace | | | | | fails | | `detect-vpn-zombies.sh` |
| Killswitch (qBittorrent loses egress with gluetun stopped) | | | | | fails, opt-in | | |
| `check-vpn.sh` / `detect-vpn-zombies.sh` logic, docker faked | | fails | blocks | | | | |
| **Repository hygiene** | | | | | | | |
| Secrets⁶ | blocks | fails | blocks | | | | |
| Compose `${VAR}` documented in `.env.example` | blocks | fails | blocks | | | | |
| Internal doc links⁷ | blocks | fails | blocks | | | | |
| Your domain in tracked files | warns | | | | | | |
| Your NAS hostname in tracked files | blocks | | | | | | |
| YAML syntax of other files | blocks¹ | | | | | | |
| Hook installed where git runs it | | fails | skipped | | | | |
| shellcheck at `error` | | fails | blocks | | | | |
| shellcheck at `warning` | | | reports | | | | |
| Workflows (actionlint), devcontainer Dockerfile (hadolint) | | | blocks | devcontainer must build | | | |
| **Scripts** | | | | | | | |
| `arr-backup.sh` naming, encryption, rotation (docker, gpg stubbed) | | fails | blocks | | | | |
| `configure-apps.sh` HTTP helpers, Bazarr plan, command line | | fails | blocks | | | | |
| Duplicate `.lan` detection: hook check 8 and `check-dns-duplicates.sh` (SSH, docker and a grep without `-P` faked) | | fails | blocks | | | | |
| **Live stack** | | | | | | | |
| App settings and health through their APIs⁸ | | | | | fails | | |
| UIs log in and render | | | | | fails | | |
| Pi-hole DNS published on the NAS, UDP and TCP | | | | | fails | | |
| `.lan` names resolve through Pi-hole and route through Traefik | warns (resolve only) | | | | fails | | |
| External names answer through the tunnel | warns | | | | | | |
| NAS drift: `.env.nas.backup`, Kuma monitors, duplicate `.lan` entries | warns | | | | | | |
| No executables under `/data` | | | | | fails | | cron `scan-executables.sh` |
| Every container healthy | | | | | | | by hand |
| **Supply chain** | | | | | | | |
| npm dependency CVEs; secrets and misconfiguration in the tree (trivy, HIGH/CRITICAL) | | | blocks | | | | |
| SBOM (syft, SPDX + CycloneDX artifact) | | | produced | | | | |
| Action digests, npm versions | | | | | | opens PRs | |

1. Hook check 3 parses only **staged** `*.yml`/`*.yaml`: PyYAML (syntax only) if `.venv` or `python3` has it, else `docker compose config` for compose files, else it prints SKIPPED and passes.
2. Hook check 4 and `tests/port-conflicts.bats` render every compose file, staged or not, with every profile and the placeholders in `tests/fixtures/.env.test`, and read the model, not the text. Two published ports clash on the same port and protocol when the host IPs match or either is a wildcard, in one file or across files. gluetun's ports are named with the services in its namespace, and a port on one of those services is an error of its own. Static IPs clash per network. A file that doesn't render blocks. Host-network services aren't seen (see [gaps](#gaps)).
3. No `privileged`, docker socket `:ro`, no `env_file`, no `SYS_TIME`, Traefik `no-new-privileges`, Jellyfin media `:ro` (`tests/security.bats`).
4. Read from the rendered model. A client is matched by service name (`qbittorrent`, `sabnzbd`) or by an image token (qbittorrent, transmission, deluge, rtorrent, rutorrent, aria2, sabnzbd, nzbget). Prowlarr and FlareSolverr aren't clients; footnote 5 holds them.
5. `TUNNELED` in `detect-vpn-zombies.sh`, what `check-vpn.sh --list-tunnelled` derives, and `GLUETUN_NAMESPACE_SERVICES` in `tests/e2e/helpers.ts` (which the e2e egress and namespace tests iterate over) must each equal the compose `service:`/`container:gluetun` bindings in both directions (`tests/vpn-zombies.bats`).
6. The hook scans every tracked and staged file except `*.md`, `tests/fixtures/`, `scripts/lib/check-*.sh` and `common.sh`. Its two patterns labelled WARNING still count as errors and block. bats runs `check_secrets` on throwaway repos, not on the tree, and scans `.env.example` itself; CI's other secret check is trivy's own ruleset.
7. Relative links to `.md` files and `#anchors`, outside fenced code. Links to other file types and external URLs aren't followed.
8. Root folders, qBittorrent and SABnzbd categories, every enabled download client passing its app's own test, RSS indexers, no error-level health checks, Prowlarr's synced apps, Seerr's metadata source and stored servers, Bazarr's profile and stored API keys.

## Where a check quietly doesn't run

**Hook**
- Exits 0 before any check when nothing is staged as added, copied or modified.
- Check 4 prints SKIPPED and passes without `docker compose` or a working `python3`.
- The link `setup-hooks.sh` makes is absolute, so every worktree runs the `scripts/pre-commit` and `scripts/lib/` of the checkout that last ran it, against its own files.
- The hostname block, the domain warning and checks 6–9 read untracked files from the committing checkout: `.claude/config.local.md`, `.env` or `.env.nas.backup`. A fresh clone, a git worktree and CI have none of them, so those checks skip.
- Checks 6–8 skip when the NAS doesn't answer ping, port 22 is closed, SSH auth fails, or there is no `timeout` command on `PATH` (it's what probes the port). Check 9 also needs `dig` and `NAS_IP` in `.env.nas.backup`.
- Check 8 compares `02-local-dns.conf` only with itself when it can't read `pihole.toml` from the `pihole` container, and its OK line then says `pihole.toml not compared`.
- Check 10 skips offline. Each registry that doesn't answer is named as a SKIP. It stops at 30 s only when `timeout` or `gtimeout` exists.

**bats, local and CI**
- No `docker compose`: the render, volume-pin, architecture and port-conflict tests skip. The architecture and port-conflict tests also need `python3`.
- No docker daemon, or no `/dev/net/tun` inside containers: the OpenVPN test skips.
- No `shellcheck` on `PATH` and no docker: the shellcheck tests skip.
- The tag-existence test skips without `curl`, but fails, rather than skips, without a network.
- bash older than 4.1 (macOS `/bin/bash`): the two whole-hook tests skip, so they only run in CI.
- No `gpg`: the real-gpg restore test skips.
- `CI` set: the hook-installed test on this repository skips. CI still runs `setup-hooks.sh`, so the installer has to succeed.

**CI**
- `bats suite`, `lint` and `supply chain` don't run on the nightly schedule, and the nightly jobs run only on schedule or dispatch.
- Required checks gate PR merges. Branch protection on `main` isn't enforced for admins and doesn't require a PR, so an admin's direct push is checked after it lands. That's a repository setting, not code.

**e2e**
- Without `.env.e2e`, which a git worktree doesn't inherit, the tests that use docker on the NAS fail: egress, namespaces, Pi-hole `:53`, the `/data` scan, Seerr. `ALLOW_UNVERIFIED_VPN=1` turns exactly those into skips, visibly. qBittorrent's category test needs only `NAS_HOST`, and fails without it.
- Every other API and UI test skips when its API key or login is missing from `.env.e2e`.
- `.lan` routing tests skip without `TRAEFIK_LAN_IP`, and for an optional utility that isn't deployed. They must run from a LAN machine; the NAS can't reach its own macvlan.
- The killswitch test skips unless `ALLOW_DISRUPTIVE_TESTS=1`, because it stops the live gluetun.

**Renovate**
- `renovate.json` does nothing unless the Renovate app is installed on the repository.

## Gaps

Things nothing checks, or checks that can't see what they're meant to. Each was confirmed in the code.

- **Ports bound by host-network services aren't checked.** Tailscale and beszel-agent use `network_mode: host`, so the ports they listen on never appear in the compose model. The conflict check names them in a NOTE.
- **The NAS-first rule is enforced by nothing.** CI can't reach the NAS, and nothing records that e2e ran for a commit.
- **Hostname and domain leaks are never checked in CI or in a worktree.** Only a checkout holding the untracked config runs them. The hook's secret patterns (WireGuard, OpenVPN, Cloudflare, bcrypt) never run over the tree in CI, and never over `*.md` anywhere.
- **No IPv6 or DNS-leak test.** Every egress probe is IPv4-only. `check-vpn.sh` checks that DNS resolves inside gluetun, not where the queries go.
- **The killswitch covers qBittorrent only,** and only when asked for.
- **Nothing exercises `gluetun-recover`,** or checks that every gluetun-bound service carries the `gluetun.dependent=true` label it acts on.
- **Image CVEs never gate or notify.** The nightly findings sit in the run summary and the `trivy-images` artifact.
- **Tag existence is checked only when a PR or push runs bats.** A tag pulled upstream between changes surfaces at the next change, or at the next `docker compose pull`.
- **A minor-only tag passes the pinning checks** (`traefik:v3.7`) though it moves with each patch release, and compose images aren't pinned by digest.
- **Update discovery rests on hook check 10.** This repository has no Renovate PR, branch or Dependency Dashboard issue, so nothing shows the app is installed. Nothing reports new versions of the digest-pinned CI tool images in `ci.yml`.
- **YAML outside the compose files is parsed only by the hook, and only when staged.** The `*.yml.example` templates and `renovate.json` are never validated, and the YAML check has no negative test.
- **Some code is never type-checked or linted.** Playwright strips the e2e specs' types without checking them, and CI never loads the specs at all. The `*.bats` files and the two Python helpers aren't linted.
- **Untested scripts** (shellcheck at `error` only): `check-network.sh`, `fix-radarr-paths.sh`, `fix-sonarr-folders.sh`, `queue-cleanup.sh`, `restart-stack.sh`, `scan-executables.sh`. Hook checks 3, 6, 7 and 9 have no tests either.
- **The three executable-extension lists** in `configure-apps.sh`, `scan-executables.sh` and `media-hygiene.spec.ts` must match, and nothing compares them.
- **Backups:** a volume that fails to copy prints an error (and posts to `HA_WEBHOOK_URL` if set), but the script still exits 0, and no test covers that path. The volume list is hard-coded and never compared with the compose files. Nothing checks that the scheduled backup ran.
- **No live test for** cloudflared, Tailscale, dnscrypt-proxy, diun, deunhealth or configarr. The utilities get only their optional `.lan` routes, and the tunnel only hook check 9's two external names.
- **The neighbouring project's static IP on `arr-stack`** lives outside this repo. Only `docker network inspect` on the NAS shows it.

## Keeping this page true

Change this page in the same commit as any hook check, test file or CI job you add, remove or change. Check each entry against the code, not against what the check was meant to do.
