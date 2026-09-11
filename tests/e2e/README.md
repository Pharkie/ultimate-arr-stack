# E2E test suite

Playwright tests against a live running stack (NAS or a local dev copy). Split by domain:

| File | Covers |
|---|---|
| `ui-screenshots.spec.ts` | Login + screenshot each service's web UI (Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent, SABnzbd, Seerr, Bazarr, Pi-hole) |
| `api-assertions.spec.ts` | Root folders, media counts, download-client tests, indexer tests, health checks via each app's API |
| `vpn-security.spec.ts` | Egress-IP leak checks (tunneled services match Gluetun, bridge services don't), killswitch chaos test, port-forwarding stub |
| `networking.spec.ts` | DNS resolution via Pi-hole, Traefik `.lan` routing end-to-end, Pi-hole port publication |
| `addons.spec.ts` | Decypharr, Magnetio (scraper/addon/redis), stremio-jellyfin, Homepage, and two container-toolchain contracts |
| `operations.spec.ts` | uptime-kuma, beszel, duc over the bridge, and the Docker socket proxy asserted in both directions (what it must allow, what it must refuse) |
| `resilience.spec.ts` | Gluetun zombie-container detection (stale netns after a recreate) |

`helpers.ts` is not a spec file. It hosts `HOST`, `PORTS`, `url()`, `addHeaderToAllRequests()`, and the docker-exec helpers (`DOCKER_AVAILABLE`, `dockerExec`, `dockerInspect`, `egressIp`).

## Running

```bash
npx playwright test                          # everything except opt-in disruptive tests
npx playwright test tests/e2e/vpn-security.spec.ts
npm test                                     # bats (static compose checks) + this suite
```

Requires `.env.e2e` (copy from `.env.e2e.example`) with `NAS_HOST` and the service credentials/API keys.

## Gating conventions

- **`DOCKER_AVAILABLE`** (`helpers.ts`): probes `docker version` at load time. Tests that need `docker exec`/`docker inspect` against the live stack (egress-IP checks, zombie detection, Magnetio's internal-only endpoints) call `test.skip(!DOCKER_AVAILABLE, ...)`: they only actually run on the NAS itself (or wherever the docker CLI can reach the stack's containers), and skip cleanly everywhere else instead of failing.
- **Missing env vars** (`TRAEFIK_LAN_IP`, `MAGNETIO_REDIS_PASSWORD`, per-service credentials): tests `test.skip()` when the var they need isn't set, rather than failing. That keeps the suite runnable against a partially-configured `.env.e2e`.
- **`ALLOW_DISRUPTIVE_TESTS=1`**: gates the one test that stops a live container (`vpn-security.spec.ts`'s killswitch chaos test: `docker stop gluetun`, confirm qBittorrent's egress fails closed rather than leaking, then restart Gluetun and poll for healthy). Unset, it skips. This test interrupts real downloads/searches while it runs, so it's never part of plain `npm test`. Run it deliberately:
  ```bash
  ALLOW_DISRUPTIVE_TESTS=1 npx playwright test tests/e2e/vpn-security.spec.ts -g killswitch
  ```

## Coverage floor

Skipping is a feature here: the gates above are what keep the suite runnable off-NAS. But
skipping *everything* is a configuration failure that would otherwise read as a pass, because
Playwright exits 0 when tests skip.

`executed-floor-reporter.ts` prints a census (`executed / skipped / failed / collected`) on every
run and fails any **full-suite** run that executed fewer than 30 of the 58 collected tests. Runs
that collected fewer than 50 in total (a single spec, or `-g`) are exempt, so the documented
single-file invocations above still work.

Reference numbers, measured on the NAS 2026-09-11: the suite collects 68 and executes 66 with a
complete `.env.e2e` (2 skip: the killswitch chaos test and the port-forwarding stub). Off-NAS,
every test that needs `docker` skips, which is why the executed count there is not the number to
read; 3 executed is the signature of a missing or rotted `.env.e2e`. `forbidOnly` is on for the
same reason: a stray `test.only` would shrink a green run to one test.

Do not hardcode these numbers anywhere else. They move whenever a spec gains a test, and the
census line printed by every run is the number that cannot go stale.

## What this suite does not cover, deliberately

Twelve compose services have no e2e test, and for most of them that is correct rather than a gap.
Measured 2026-09-11 by asking each container what it listens on:

- `diun`, `gluetun-rotator` and `gluetun-recover` have no listening socket beyond Docker's own
  resolver. There is nothing to probe.
- `beszel-agent`, `deunhealth`, `dnscrypt-proxy` and `vpn-socks5` ship no shell, so `docker exec`
  cannot reach them either. They are covered by the compose-level checks in the bats suite.
- `configarr` is a one-shot job (`restart: "no"`) that runs once and exits 0. That it is Exited is
  its working state, not a fault; run it with
  `docker compose -f docker-compose.utilities.yml run --rm configarr`.
- `cloudflared` is opt-in behind a compose profile and is not running by default.
- `tailscale` is asserted by the bats suite and by `tests/network-segmentation.bats`, which needs a
  VLAN20 address rather than an HTTP client.

`traefik` itself has no direct HTTP test: its routing is what `networking.spec.ts` asserts, which
is the more meaningful check. The one real limitation there is stated in that file: the `.lan`
tests stop at the 401 gate, so they prove authentication is enforced and not that a credentialed
request reaches a live backend. `operations.spec.ts` now covers `duc` and `beszel` backends
directly, which is the half that was missing.

To watch the floor fire: `E2E_EXECUTED_FLOOR=200 npx playwright test`.
