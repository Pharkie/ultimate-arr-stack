import { test, expect } from '@playwright/test';
import { url, DOCKER_AVAILABLE, dockerExec } from './helpers';

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

  test('Sonarr — qBittorrent download client is configured and reachable', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const clients = await request.get(url('sonarr', '/api/v3/downloadclient'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(clients.ok()).toBeTruthy();
    const clientList = await clients.json();
    expect(clientList).toEqual(
      expect.arrayContaining([expect.objectContaining({ name: 'qBittorrent', enable: true })]),
    );

    const test_ = await request.post(url('sonarr', '/api/v3/downloadclient/testall'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(test_.ok()).toBeTruthy();
    const results = await test_.json();
    expect(results).toEqual(expect.arrayContaining([expect.objectContaining({ isValid: true })]));
  });

  test('Radarr — qBittorrent download client is configured and reachable', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const clients = await request.get(url('radarr', '/api/v3/downloadclient'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(clients.ok()).toBeTruthy();
    const clientList = await clients.json();
    expect(clientList).toEqual(
      expect.arrayContaining([expect.objectContaining({ name: 'qBittorrent', enable: true })]),
    );

    const test_ = await request.post(url('radarr', '/api/v3/downloadclient/testall'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(test_.ok()).toBeTruthy();
    const results = await test_.json();
    expect(results).toEqual(expect.arrayContaining([expect.objectContaining({ isValid: true })]));
  });

  test('Sonarr — SABnzbd download client is configured and reachable', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const clients = await request.get(url('sonarr', '/api/v3/downloadclient'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(clients.ok()).toBeTruthy();
    const clientList = await clients.json();
    expect(clientList).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ implementation: 'Sabnzbd', enable: true }),
      ]),
    );

    const test_ = await request.post(url('sonarr', '/api/v3/downloadclient/testall'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(test_.ok()).toBeTruthy();
    const results = await test_.json();
    expect(results).toEqual(expect.arrayContaining([expect.objectContaining({ isValid: true })]));
  });

  test('Radarr — SABnzbd download client is configured and reachable', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const clients = await request.get(url('radarr', '/api/v3/downloadclient'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(clients.ok()).toBeTruthy();
    const clientList = await clients.json();
    expect(clientList).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ implementation: 'Sabnzbd', enable: true }),
      ]),
    );

    const test_ = await request.post(url('radarr', '/api/v3/downloadclient/testall'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(test_.ok()).toBeTruthy();
    const results = await test_.json();
    expect(results).toEqual(expect.arrayContaining([expect.objectContaining({ isValid: true })]));
  });

  test('Sonarr — has at least one enabled indexer', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const res = await request.get(url('sonarr', '/api/v3/indexer'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const indexers = await res.json();
    expect(indexers).toEqual(expect.arrayContaining([expect.objectContaining({ enableRss: true })]));
  });

  test('Radarr — has at least one enabled indexer', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const res = await request.get(url('radarr', '/api/v3/indexer'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const indexers = await res.json();
    expect(indexers).toEqual(expect.arrayContaining([expect.objectContaining({ enableRss: true })]));
  });

  test('Sonarr — no health check errors (e.g. remote path mapping)', async ({ request }) => {
    const apiKey = process.env.SONARR_API_KEY;
    test.skip(!apiKey, 'SONARR_API_KEY not set');

    const res = await request.get(url('sonarr', '/api/v3/health'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const issues = await res.json();
    const errors = issues.filter((i: { type: string }) => i.type === 'error');
    expect(errors).toEqual([]);
  });

  test('Radarr — no health check errors (e.g. remote path mapping)', async ({ request }) => {
    const apiKey = process.env.RADARR_API_KEY;
    test.skip(!apiKey, 'RADARR_API_KEY not set');

    const res = await request.get(url('radarr', '/api/v3/health'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(res.ok()).toBeTruthy();
    const issues = await res.json();
    const errors = issues.filter((i: { type: string }) => i.type === 'error');
    expect(errors).toEqual([]);
  });

  // --- Credential-propagation live checks. These exercise the exact three
  // directions that broke live on 2026-08-17 (Prowlarr -> Sonarr/Radarr
  // Applications, Seerr -> Sonarr/Radarr, Bazarr -> Sonarr/Radarr) and were
  // previously only caught by a 30-minute NAS timer, not by anything that
  // runs on every test:e2e pass. Mirrors scripts/detect-credential-drift.sh's
  // own checks so both stay in sync. ---

  test('Prowlarr — Applications test passes for Sonarr/Radarr', async ({ request }) => {
    const apiKey = process.env.PROWLARR_API_KEY;
    test.skip(!apiKey, 'PROWLARR_API_KEY not set');

    const apps = await request.get(url('prowlarr', '/api/v1/applications'), {
      headers: { 'X-Api-Key': apiKey! },
    });
    expect(apps.ok()).toBeTruthy();
    const appList = await apps.json();
    expect(appList.length).toBeGreaterThan(0);

    for (const app of appList) {
      const testRes = await request.post(url('prowlarr', '/api/v1/applications/test'), {
        headers: { 'X-Api-Key': apiKey!, 'Content-Type': 'application/json' },
        data: app,
      });
      expect(testRes.ok(), `Prowlarr application test failed for ${app.name}`).toBeTruthy();
    }
  });

  test('Seerr — Radarr/Sonarr service probes succeed', async ({ request }) => {
    test.skip(!DOCKER_AVAILABLE, 'requires docker exec access (run on the NAS)');

    let seerrKey: string;
    try {
      seerrKey = dockerExec('seerr', [
        'node',
        '-e',
        'console.log(require("/app/config/settings.json").main.apiKey)',
      ]).trim();
    } catch {
      test.skip(true, "could not read Seerr's own key - is the container up?");
      return;
    }
    expect(seerrKey.length).toBeGreaterThan(0);

    for (const svc of ['radarr', 'sonarr']) {
      const res = await request.get(url('seerr', `/api/v1/service/${svc}/0`), {
        headers: { 'X-Api-Key': seerrKey },
      });
      expect(res.ok(), `Seerr -> ${svc} service probe failed`).toBeTruthy();
    }
  });

  test('Bazarr — stored Sonarr/Radarr apiKey matches the current key', async ({ request }) => {
    const bazarrKey = process.env.BAZARR_API_KEY;
    const sonarrKey = process.env.SONARR_API_KEY;
    const radarrKey = process.env.RADARR_API_KEY;
    test.skip(
      !bazarrKey || !sonarrKey || !radarrKey,
      'BAZARR_API_KEY / SONARR_API_KEY / RADARR_API_KEY not set',
    );

    // Unlike Sonarr/Radarr's own APIs (which mask secret fields on every GET
    // - see the note above), Bazarr's /api/system/settings does NOT mask
    // its stored sonarr.apikey/radarr.apikey fields (confirmed live
    // 2026-08-17). So a direct comparison is a valid drift check here,
    // where it would be a structural dead end for Sonarr/Radarr themselves.
    const res = await request.get(url('bazarr', '/api/system/settings'), {
      headers: { 'X-API-KEY': bazarrKey! },
    });
    expect(res.ok()).toBeTruthy();
    const settings = await res.json();
    expect(settings.sonarr.apikey).toBe(sonarrKey);
    expect(settings.radarr.apikey).toBe(radarrKey);
  });
});
