# E2E test suite

Playwright tests against a live running stack (NAS or a local dev copy). Split by domain:

| File | Covers |
|---|---|
| `ui-screenshots.spec.ts` | Login + screenshot each service's web UI (Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent, SABnzbd, Seerr, Bazarr, Pi-hole) |
| `api-assertions.spec.ts` | Root folders, media counts, download-client tests, indexer tests, health checks via each app's API |
| `vpn-security.spec.ts` | Egress-IP leak checks (tunneled services match Gluetun, bridge services don't), killswitch chaos test, port-forwarding stub |
| `networking.spec.ts` | DNS resolution via Pi-hole, Traefik `.lan` routing end-to-end, Pi-hole port publication |
| `addons.spec.ts` | Decypharr, Magnetio (scraper/addon/redis), stremio-jellyfin |
| `resilience.spec.ts` | Gluetun zombie-container detection (stale netns after a recreate) |

`helpers.ts` is not a spec file — it hosts `HOST`, `PORTS`, `url()`, `addHeaderToAllRequests()`, and the docker-exec helpers (`DOCKER_AVAILABLE`, `dockerExec`, `dockerInspect`, `egressIp`).

## Running

```bash
npx playwright test                          # everything except opt-in disruptive tests
npx playwright test tests/e2e/vpn-security.spec.ts
npm test                                     # bats (static compose checks) + this suite
```

Requires `.env.e2e` (copy from `.env.e2e.example`) with `NAS_HOST` and the service credentials/API keys.

## Gating conventions

- **`DOCKER_AVAILABLE`** (`helpers.ts`): probes `docker version` at load time. Tests that need `docker exec`/`docker inspect` against the live stack (egress-IP checks, zombie detection, Magnetio's internal-only endpoints) call `test.skip(!DOCKER_AVAILABLE, ...)` — they only actually run on the NAS itself (or wherever the docker CLI can reach the stack's containers), and skip cleanly everywhere else instead of failing.
- **Missing env vars** (`TRAEFIK_LAN_IP`, `MAGNETIO_REDIS_PASSWORD`, per-service credentials): tests `test.skip()` when the var they need isn't set, rather than failing — keeps the suite runnable against a partially-configured `.env.e2e`.
- **`ALLOW_DISRUPTIVE_TESTS=1`**: gates the one test that stops a live container (`vpn-security.spec.ts`'s killswitch chaos test — `docker stop gluetun`, confirm qBittorrent's egress fails closed rather than leaking, then restart Gluetun and poll for healthy). Unset, it skips. This test interrupts real downloads/searches while it runs, so it's never part of plain `npm test` — run it deliberately:
  ```bash
  ALLOW_DISRUPTIVE_TESTS=1 npx playwright test tests/e2e/vpn-security.spec.ts -g killswitch
  ```
