import { test, expect } from '@playwright/test';
import { url, requireStackReachable, dockerExec } from './helpers';

// Split out of the former stack.spec.ts on 2026-08-16, alongside
// ui-screenshots.spec.ts.

// ─── VPN connectivity test ────────────────────────────────────────────────────

// The "VPN connectivity" test that used to live here has moved to
// vpn-security.spec.ts, and was rewritten rather than relocated. It reached
// Sonarr's API and concluded the tunnel was up, on the stated premise that
// "Sonarr/Radarr/qBittorrent run through Gluetun (network_mode:
// service:gluetun)". That premise is false: Sonarr and Radarr were moved OFF
// the VPN netns onto the bridge (docs/MIGRATION-arr-off-vpn.md), so the test
// passed identically whether the VPN was working, misrouted, or leaking.
// vpn-security.spec.ts compares real egress IPs per service instead.

// ─── API assertion tests ─────────────────────────────────────────────────────

test.describe('API assertions', () => {
  test('Radarr — root folder is /data/media/movies', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const res = await request.get(url('radarr', '/api/v3/rootfolder'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const folders = await res.json();
    expect(folders).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ path: '/data/media/movies', accessible: true }),
      ]),
    );
  });

  test('Sonarr — root folder is /data/media/tv', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const res = await request.get(url('sonarr', '/api/v3/rootfolder'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const folders = await res.json();
    expect(folders).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ path: '/data/media/tv', accessible: true }),
      ]),
    );
  });

  test('Radarr — has movies', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const res = await request.get(url('radarr', '/api/v3/movie'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const movies = await res.json();
    expect(movies.length).toBeGreaterThan(0);
  });

  test('Sonarr — has series', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const res = await request.get(url('sonarr', '/api/v3/series'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const series = await res.json();
    expect(series.length).toBeGreaterThan(0);
  });

  // ─── Wiring assertions ───────────────────────────────────────────────────
  //
  // The four tests above prove Sonarr and Radarr are up and hold a library.
  // They say nothing about whether the apps can still reach the things they
  // depend on, which is where this stack actually breaks: a download client
  // that stopped answering, an indexer disabled by a 451 from the wrong VPN
  // exit country, an API key rotated out from under a consumer. Each of those
  // leaves every check above green.
  //
  // Adapted from leonardoazeredo/ultimate-arr-stack's api-assertions.spec.ts.

  /**
   * Assert every enabled download client passes its own connection test.
   *
   * Deliberately not written as "assert some client in testall is valid".
   * `arrayContaining([objectContaining({ isValid: true })])` is satisfied by a
   * single healthy client, so a stack with qBittorrent working and SABnzbd
   * broken passes it — the failure the test exists to catch. Results are
   * matched back to their client by id instead, and every one must pass.
   *
   * Nor does it name expected clients. Which clients a deployment runs is
   * config, not a property of this repo; what must hold everywhere is that the
   * ones it does run are reachable.
   */
  async function assertDownloadClientsHealthy(
    request: import('@playwright/test').APIRequestContext,
    app: 'sonarr' | 'radarr',
    apiKey: string,
  ) {
    const listRes = await request.get(url(app, '/api/v3/downloadclient'), {
      headers: { 'X-Api-Key': apiKey },
    });
    expect(listRes.ok()).toBeTruthy();
    const clients: Array<{ id: number; name: string; enable: boolean }> = await listRes.json();

    const enabled = clients.filter((c) => c.enable);
    expect(enabled.length, `${app} has no enabled download client at all`).toBeGreaterThan(0);

    const testRes = await request.post(url(app, '/api/v3/downloadclient/testall'), {
      headers: { 'X-Api-Key': apiKey },
    });
    expect(testRes.ok()).toBeTruthy();
    const results: Array<{ id: number; isValid: boolean; validationFailures?: unknown }> =
      await testRes.json();

    for (const client of enabled) {
      const result = results.find((r) => r.id === client.id);
      expect(result, `${app}: no test result returned for "${client.name}"`).toBeDefined();
      expect(
        result!.isValid,
        `${app} cannot reach download client "${client.name}": ` +
          JSON.stringify(result!.validationFailures ?? result),
      ).toBe(true);
    }
  }

  test('Sonarr — every enabled download client is reachable', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');
    await assertDownloadClientsHealthy(request, 'sonarr', apiKey!);
  });

  test('Radarr — every enabled download client is reachable', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');
    await assertDownloadClientsHealthy(request, 'radarr', apiKey!);
  });

  test('Sonarr — has at least one RSS-enabled indexer', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const res = await request.get(url('sonarr', '/api/v3/indexer'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const indexers: Array<{ enableRss: boolean }> = await res.json();
    // Prowlarr syncs these in. An empty or all-disabled list means the sync
    // has broken, or every indexer got disabled by repeated failures — the
    // shape of the VPN-exit-country 451 incident.
    expect(indexers.filter((i) => i.enableRss).length).toBeGreaterThan(0);
  });

  test('Radarr — has at least one RSS-enabled indexer', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const res = await request.get(url('radarr', '/api/v3/indexer'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const indexers: Array<{ enableRss: boolean }> = await res.json();
    expect(indexers.filter((i) => i.enableRss).length).toBeGreaterThan(0);
  });

  test('Sonarr — reports no error-level health issues', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    // Sonarr's own health check already knows about broken remote path
    // mappings, unreachable download clients and failed indexers. Surfacing it
    // here costs one request and catches things no assertion in this file
    // thought to look for. Warnings are left alone deliberately: they include
    // routine noise like pending updates, and gating on them would make the
    // suite fail for reasons nobody would act on.
    const res = await request.get(url('sonarr', '/api/v3/health'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const issues: Array<{ type: string; message: string }> = await res.json();
    const errors = issues.filter((i) => i.type === 'error');
    expect(errors.map((e) => e.message)).toEqual([]);
  });

  test('Radarr — reports no error-level health issues', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const res = await request.get(url('radarr', '/api/v3/health'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const issues: Array<{ type: string; message: string }> = await res.json();
    const errors = issues.filter((i) => i.type === 'error');
    expect(errors.map((e) => e.message)).toEqual([]);
  });

  // ─── Credential propagation ──────────────────────────────────────────────
  //
  // Sonarr's and Radarr's API keys are held as copies by three other
  // consumers. Rotating a key updates the app but not its consumers, and the
  // symptom shows up somewhere unrelated — Jellyseerr requests silently
  // failing, Prowlarr reporting an indexer dead. Each direction is checked
  // where it can actually be observed.

  test('Prowlarr — its configured applications all still authenticate', async ({ request }) => {
    const apiKey = process.env.PROWLARR_API_KEY;
    test.skip(!apiKey, 'PROWLARR_API_KEY not set');

    const apps = await request.get(url('prowlarr', '/api/v1/applications'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(apps.ok()).toBeTruthy();
    const appList: Array<{ name: string }> = await apps.json();
    // An empty list is a failure, not a pass: with no applications configured
    // Prowlarr syncs indexers nowhere, and the loop below would assert nothing.
    expect(appList.length, 'Prowlarr has no applications configured').toBeGreaterThan(0);

    for (const app of appList) {
      const res = await request.post(url('prowlarr', '/api/v1/applications/test'), {
        headers: { 'X-Api-Key': apiKey!, 'Content-Type': 'application/json' },
        data: app,
      });
      expect(res.ok(), `Prowlarr cannot authenticate to "${app.name}"`).toBeTruthy();
    }
  });

  test('Seerr — its Radarr and Sonarr probes succeed', async ({ request }) => {
    requireStackReachable(test.skip);

    // Seerr's own API key is not in .env.e2e and should not be: it is
    // generated by the app, not configured. Read it from the container so this
    // check needs no new secret anywhere.
    let seerrKey: string;
    try {
      seerrKey = dockerExec('seerr', [
        'node',
        '-e',
        'console.log(require("/app/config/settings.json").main.apiKey)',
      ]).trim();
    } catch (err) {
      throw new Error(`could not read Seerr's own API key from the container: ${err}`);
    }
    expect(seerrKey.length).toBeGreaterThan(0);

    for (const svc of ['radarr', 'sonarr'] as const) {
      const res = await request.get(url('seerr', `/api/v1/service/${svc}/0`), {
        headers: { 'X-Api-Key': seerrKey },
      });
      expect(res.ok(), `Seerr's ${svc} probe failed — stale API key or path override`).toBeTruthy();
    }
  });

  test("Bazarr — the Sonarr/Radarr keys it stores are the current ones", async ({ request }) => {
    const bazarrKey = process.env.BAZARR_API_KEY;
    const sonarrKey = process.env.SONARR_API_KEY;
    const radarrKey = process.env.RADARR_API_KEY;
    test.skip(
      !bazarrKey || !sonarrKey || !radarrKey,
      'BAZARR_API_KEY / SONARR_API_KEY / RADARR_API_KEY not set',
    );

    // A direct comparison works here and nowhere else. Sonarr and Radarr mask
    // secret fields on every GET, so asking them what key a consumer holds is
    // a structural dead end; Bazarr's /api/system/settings returns
    // sonarr.apikey and radarr.apikey in the clear.
    const res = await request.get(url('bazarr', '/api/system/settings'), {
      headers: { 'X-API-KEY': bazarrKey! },
    });
    expect(res.ok()).toBeTruthy();
    const settings = await res.json();
    expect(settings.sonarr.apikey, "Bazarr holds a stale Sonarr API key").toBe(sonarrKey);
    expect(settings.radarr.apikey, "Bazarr holds a stale Radarr API key").toBe(radarrKey);
  });
});
