# Quality control map

Which surface checks what. Filled in from what actually runs, not from what
was intended; the point of the table is the cells that say MISSING.

Adapted from the same map in leonardoazeredo/ultimate-arr-stack, which found
gaps there that nothing else had surfaced. A review of this file's first draft
found five rows that overstated coverage — the map is only worth having if it
is checked against the code every time it changes.

## Legend

- **YES** — runs there and fails the surface when it fails.
- **DIAG** — runs there and reports; never fails the surface.
- **SKIP** — present but skipped on that surface (usually: needs the NAS).
- **N/A** — the surface cannot do this by nature.
- **MISSING** — could run there and does not.
- **—** — not that surface's job.

## The surfaces

| surface | when | what it is |
|---|---|---|
| **Hook** | every commit, on the developer's machine | `scripts/pre-commit` — eleven checks, sourced from `scripts/lib/check-*.sh`. Three need SSH to the NAS and one more needs the NAS config; they report SKIP without it. The hook does not run bats. |
| **Local** | on demand | `tests/run-tests.sh` (bats) and `npm run test:e2e` (Playwright, needs `.env.e2e` and the NAS) |
| **CI** | every pull request, and pushes to main | `.github/workflows/ci.yml` — bats, lint, supply chain |
| **Nightly** | 04:17 UTC and on demand | the same workflow's image scan |
| **NAS** | before every merge, by hand | branch-first deploy per CLAUDE.md: recreate, verify, `npm run test:e2e` |

## The map

| capability | Hook | Local | CI | Nightly | NAS | where |
|---|---|---|---|---|---|---|
| Compose files parse (`docker compose config`) | YES | YES | YES | N/A | YES | hook `check-yaml-syntax`; bats `compose-validation` |
| Port and static-IP conflicts across files | YES | YES | YES | N/A | — | hook `check-conflicts`; bats `port-conflicts` |
| Secret patterns in tracked files | YES | YES | YES | N/A | — | hook `check-secrets`; bats `pre-commit-checks` drives it |
| Every compose variable documented in `.env.example` | YES | YES | YES | N/A | — | hook `check-env-vars`; bats `env-vars` |
| Internal doc links resolve | YES | YES | YES | N/A | — | hook `check-doc-links`; bats `pre-commit-checks` drives it |
| No real LAN domain hard-coded in tracked files | YES | MISSING | MISSING | N/A | — | hook `check-hardcoded-domain` (needs `.env` to know the domain) |
| Image tags pinned (no `latest`, no untagged) | — | YES | YES | N/A | — | bats `compose-validation`, `security`. A major-only tag (e.g. `:2`) passes and still floats |
| Image tags exist on their registry | DIAG | YES* | YES | N/A | — | hook `check-image-versions` reports newer tags, never fails; bats `compose-validation` — *fails, not skips, without a network |
| Volumes pinned to physical names | — | YES | YES | N/A | — | bats `compose-validation` |
| Every service has a restart policy and logging config; none is privileged | — | YES | YES | N/A | — | bats `compose-validation` |
| Container posture: docker socket read-only, no `env_file` on infrastructure, no `SYS_TIME`, traefik `no-new-privileges`, media mounts read-only | — | YES | YES | N/A | — | bats `security` |
| Every download client inside gluetun's namespace | — | YES | YES | N/A | — | bats `compose-validation` + `helpers/check-clients-tunnelled.py`, over resolved compose JSON |
| Project names pinned; core three share `arr-stack` | — | YES | YES | N/A | — | bats `compose-validation` |
| `arr-stack` subnet, `ip_range` and gateway pinned | — | YES | YES | N/A | — | bats `compose-validation`, over resolved compose JSON |
| Services declaring a VPN binding are inside gluetun's *current* namespace | — | — | — | N/A | YES | e2e `resilience`; `detect-vpn-zombies.sh` (unit-tested in bats `vpn-zombies`) |
| Gluetun's capability set (OpenVPN path) | — | YES | YES | N/A | — | bats `openvpn-caps` |
| The pre-commit hook is installed and points at the repo's script | — | YES | YES | N/A | — | bats `hooks-installed` (CI runs `setup-hooks.sh` first) |
| shellcheck, `error` severity | — | YES | YES | N/A | — | bats `shellcheck` |
| shellcheck, `warning` severity | — | — | DIAG | N/A | — | CI `lint` |
| actionlint over the workflow | — | — | YES | N/A | — | CI `lint` |
| hadolint over the devcontainer Dockerfile | — | — | YES | N/A | — | CI `lint`, policy in `.hadolint.yaml` |
| `configure-apps.sh` HTTP layer (curl stubbed) | — | YES | YES | N/A | — | bats `configure-helpers` |
| Bazarr language plan across profile states | — | YES | YES | N/A | — | bats `bazarr-language-plan` |
| `audiobooks-tv-mirror.sh` links (checked by inode), prunes, `--dry-run` | — | YES | YES | N/A | — | bats `audiobooks-tv-mirror` |
| `arr-backup.sh` archive name at the destination (`--encrypt` stays `.tar.gz.gpg`), 7-day rotation, a real-gpg decrypt-and-extract | — | YES | YES | N/A | — | bats `arr-backup` (docker and gpg stubbed; the restore test needs `gpg` installed, skips otherwise) |
| `configure-apps.sh` structure (step order, no unbounded curl, CLI) | — | YES | YES | N/A | — | bats `configure-apps` |
| `configure-apps.sh` against real services | — | — | — | N/A | YES | by hand, `--dry-run` then run; throwaway containers for Bazarr |
| Python in `scripts/lib/` and `tests/helpers/` — lint | — | MISSING | MISSING | N/A | — | nothing runs pyflakes/ruff |
| YAML lint beyond `compose config` | — | MISSING | MISSING | N/A | — | no yamllint |
| Vulnerabilities, misconfiguration, secrets over the tree (trivy) | — | MISSING | YES | N/A | — | CI `supply chain`, HIGH/CRITICAL block |
| SBOM | — | MISSING | YES | N/A | — | CI `supply chain`, artifact |
| Container image CVEs | — | MISSING | — | DIAG | — | CI `nightly`, artifact + summary table |
| Uptime Kuma monitors match the services | YES (SSH) | — | SKIP | N/A | — | hook `check-uptime-monitors` |
| `.lan` DNS duplicates; `.env` backup in sync | YES (SSH) | — | SKIP | N/A | — | hook `check-dns-duplicates`, `check-env-backup` |
| Public domain resolves and answers | YES (NAS config) | — | SKIP | N/A | — | hook `check-domains` |
| Every service UI answers; API state (root folders, clients, profiles) | — | — | — | N/A | YES | e2e `ui-screenshots`, `api-assertions` |
| Traefik routes each `.lan` host; `.lan` resolves to the macvlan; Pi-hole publishes its ports | — | — | — | N/A | YES | e2e `networking` |
| VPN egress per service; killswitch | — | — | — | N/A | YES | e2e `vpn-security` (killswitch needs `ALLOW_DISRUPTIVE_TESTS=1`) |
| No executables under `/data` | — | — | — | N/A | YES | e2e `media-hygiene`; `scan-executables.sh` |
| The devcontainer Dockerfile builds | — | MISSING | — | YES | — | CI `nightly — the devcontainer builds` |
| Mutation testing of the guards | — | MISSING | MISSING | MISSING | — | the fork has a corpus; not adopted |

## Gaps this map makes visible

1. **The Python has no linter.** `scripts/lib/bazarr-language-plan.py` and `tests/helpers/check-clients-tunnelled.py` are unit-tested but nothing runs pyflakes or ruff over them. Cheap to add to `lint`.
2. **Nothing lints YAML** beyond `docker compose config`, which accepts a lot.
3. **Four hook checks exist only on a machine that can reach the NAS** — monitors, DNS duplicates, `.env` backup sync (SSH) and the public-domain check (NAS config). A contributor's push is never checked for them, and CI cannot be. The hard-coded-domain check is hook-only for a different reason: it needs `.env` to know what to look for.
4. **The e2e suite runs only from a machine with `.env.e2e`.** By design — it needs the stack — but the NAS step is the only place UI, routing and egress are ever exercised.
5. **A test image floats.** `tests/openvpn-caps.bats` probes `/dev/net/tun` with a bare `alpine`, which the pinning test cannot see.
6. **The guards are never mutation-tested.** Each architecture test carries negatives that assert the specific failure message instead, which proves the check can fail in the ways we thought of.

## Maintaining this file

When a job, test file or hook check is added or removed, change the row here in the same commit — and check the row against the code, not against the intent. A row that says YES for a check that does not run there is worse than no map.
