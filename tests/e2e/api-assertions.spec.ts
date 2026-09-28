import { test, expect } from '@playwright/test';
import { url, requireStackReachable, dockerExec, assertDownloadClientsHealthy, readSeerrApiKey } from './helpers';

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

  // Sonarr and Radarr reach qBittorrent and SABnzbd through gluetun
  // (gluetun:8085, gluetun:8080), so a VPN-side fault surfaces here first:
  // the client is unreachable, grabs fail, and only the app's own pages say
  // so. This runs each app's own client test.
  for (const [app, name, keyVar] of [
    ['sonarr', 'Sonarr', 'SONARR_API_KEY'],
    ['radarr', 'Radarr', 'RADARR_API_KEY'],
  ] as const) {
    test(`${name} — every enabled download client passes its own test`, async ({ request }) => {
      const apiKey = process.env[keyVar];
      test.skip(!apiKey, `${keyVar} not set`);
      await assertDownloadClientsHealthy(request, app, apiKey!);
    });
  }

  // Prowlarr's own download clients serve only its search page — the one
  // route this stack has for something that is neither TV nor a movie. Added
  // 2026-09-10 after that page's download button turned out to do nothing at
  // all: no clients configured, so no grab event and no error, just silence.
  test('Prowlarr — every enabled download client is reachable', async ({ request }) => {
    const apiKey = process.env.PROWLARR_API_KEY;
    test.skip(!apiKey, 'PROWLARR_API_KEY not set');
    await assertDownloadClientsHealthy(request, 'prowlarr', apiKey!);
  });

  // The `other` category is where those grabs land. Sonarr and Radarr collect
  // from tv/ and movies/; nothing collects from other/ — it is a landing spot.
  test('qBittorrent — tv, movies and other categories map to /data/torrents/<name>', async ({ request }) => {
    // qBittorrent whitelists the LAN for auth; log in anyway when credentials
    // are provided so the test does not depend on where it is run from.
    const user = process.env.QBIT_USERNAME;
    const pass = process.env.QBIT_PASSWORD;
    if (user && pass) {
      await request.post(url('qbittorrent', '/api/v2/auth/login'), { form: { username: user, password: pass } });
    }
    const res = await request.get(url('qbittorrent', '/api/v2/torrents/categories'));
    expect(res.ok(), `categories request: HTTP ${res.status()}`).toBeTruthy();
    const cats: Record<string, { savePath: string }> = await res.json();
    for (const name of ['tv', 'movies', 'other']) {
      expect(cats[name]?.savePath, `qBittorrent category "${name}"`).toBe(`/data/torrents/${name}`);
    }
  });

  test('SABnzbd — tv, movies and other categories exist', async ({ request }) => {
    const apiKey = process.env.SABNZBD_API_KEY;
    test.skip(!apiKey, 'SABNZBD_API_KEY not set');
    const res = await request.get(
      url('sabnzbd', `/api?mode=get_config&section=categories&output=json&apikey=${apiKey}`),
    );
    expect(res.ok()).toBeTruthy();
    const body: { config: { categories: Array<{ name: string }> } } = await res.json();
    const names = body.config.categories.map((c) => c.name);
    expect(names).toEqual(expect.arrayContaining(['tv', 'movies', 'other']));
  });

  // configure-apps.sh points Seerr's TV and anime metadata at TVDB so the
  // seasons it offers are the seasons Sonarr (TVDB-only) will fetch. TMDB
  // splits some shows that TVDB files as one anthology; with TMDB metadata a
  // request for "Season 1" of the split entry fetched the wrong season of the
  // anthology, or nothing (Monster: The Ed Gein Story, 2026-09-15). The
  // setting is a single JSON field that a Seerr reinstall or a wizard re-run
  // resets, and nothing else would notice.
  test('Seerr — TV and anime metadata come from TVDB', async ({ request }) => {
    requireStackReachable(test.skip);

    const seerrKey = readSeerrApiKey();

    const res = await request.get(url('seerr', '/api/v1/settings/metadatas'), {
      headers: { 'X-Api-Key': seerrKey },
    });
    expect(res.ok(), `could not read Seerr's metadata providers (HTTP ${res.status()})`).toBeTruthy();
    const providers: { tv: string; anime: string } = await res.json();
    expect(providers.tv, 'Seerr takes TV metadata from TMDB; run configure-apps.sh --only seerr').toBe('tvdb');
    expect(providers.anime, 'Seerr takes anime metadata from TMDB; run configure-apps.sh --only seerr').toBe('tvdb');
  });

  // Seerr reports appData=false, and its UI warns that "All data will be
  // cleared", whenever /app/config/DOCKER exists. The image ships that marker
  // and Docker copies it into a new named volume, so every fresh install got
  // the warning (issue #49). The compose command deletes it on start; this
  // fails if the marker survives a start.
  test('Seerr — config volume passes its own mount check', async ({ request }) => {
    requireStackReachable(test.skip);

    const res = await request.get(url('seerr', '/api/v1/status/appdata'));
    expect(res.ok(), `could not read Seerr's appdata status (HTTP ${res.status()})`).toBeTruthy();
    const status: { appData: boolean; appDataPath: string } = await res.json();
    expect(
      status.appData,
      `Seerr says ${status.appDataPath} is not mounted properly — /app/config/DOCKER is back; ` +
        'check the seerr command in docker-compose.arr-stack.yml',
    ).toBe(true);
  });


  // configure-apps.sh manages one subtitle profile (named English, or adopted
  // by contents) and points both defaults at its real id. The previous
  // version pinned the defaults to id 1 without checking that such a profile
  // existed, so a Bazarr with a different layout was reported configured
  // while searching for nothing. Added 2026-09-10 with that rewrite.
  test('Bazarr — an English subtitle profile exists and both defaults point at it', async ({ request }) => {
    const bazarrKey = process.env.BAZARR_API_KEY;
    test.skip(!bazarrKey, 'BAZARR_API_KEY not set');
    const headers = { 'X-API-KEY': bazarrKey! };

    const profilesRes = await request.get(url('bazarr', '/api/system/languages/profiles'), { headers });
    expect(profilesRes.ok()).toBeTruthy();
    const profiles: Array<{ profileId: number; name: string; items: Array<{ language: string }> }> =
      await profilesRes.json();
    // Same rule as scripts/lib/bazarr-language-plan.py: the profile named
    // English, else one whose language SET is exactly {en} (a profile may hold
    // several rows for one language — normal, forced, hearing-impaired).
    const langSet = (p: { items: Array<{ language: string }> }) => [...new Set(p.items.map((i) => i.language))].sort().join(' ');
    const english = profiles.find((p) => p.name === 'English') ?? profiles.find((p) => langSet(p) === 'en');
    expect(english, `no profile named English and none whose languages are exactly {en}; have: ${JSON.stringify(profiles.map((p) => [p.name, langSet(p)]))}`).toBeDefined();

    const settingsRes = await request.get(url('bazarr', '/api/system/settings'), { headers });
    expect(settingsRes.ok()).toBeTruthy();
    const general = (await settingsRes.json()).general;
    expect(general.serie_default_enabled, 'series default profile not enabled').toBe(true);
    expect(general.movie_default_enabled, 'movie default profile not enabled').toBe(true);
    expect(Number(general.serie_default_profile), 'series default points at a different profile').toBe(english!.profileId);
    expect(Number(general.movie_default_profile), 'movie default points at a different profile').toBe(english!.profileId);
  });

  // RSS is how Sonarr and Radarr notice new releases by themselves. With it
  // off on every indexer, a search still works when asked, so nothing looks
  // broken, but a new episode or a newly released movie is never picked up.
  for (const [app, name, keyVar] of [
    ['sonarr', 'Sonarr', 'SONARR_API_KEY'],
    ['radarr', 'Radarr', 'RADARR_API_KEY'],
  ] as const) {
    test(`${name} — at least one indexer has RSS enabled`, async ({ request }) => {
      const apiKey = process.env[keyVar];
      test.skip(!apiKey, `${keyVar} not set`);

      const res = await request.get(url(app, '/api/v3/indexer'), { headers: { 'X-Api-Key': apiKey! } });
      expect(res.ok(), `could not list ${name}'s indexers (HTTP ${res.status()})`).toBeTruthy();
      const indexers: Array<{ name: string; enableRss: boolean }> = await res.json();
      expect(
        indexers.filter((i) => i.enableRss).map((i) => i.name),
        `no ${name} indexer has RSS enabled; have: ${indexers.map((i) => i.name).join(', ') || 'none'}`,
      ).not.toEqual([]);
    });
  }

  // Each app's own health check already knows about an unreachable download
  // client, a missing root folder or every indexer failing, but says so only
  // on its System page. Error level only: warnings (one indexer in backoff, an
  // update available) come and go on a healthy stack.
  for (const [app, name, keyVar, api] of [
    ['sonarr', 'Sonarr', 'SONARR_API_KEY', '/api/v3'],
    ['radarr', 'Radarr', 'RADARR_API_KEY', '/api/v3'],
    ['prowlarr', 'Prowlarr', 'PROWLARR_API_KEY', '/api/v1'],
  ] as const) {
    test(`${name} — no health check at error level`, async ({ request }) => {
      const apiKey = process.env[keyVar];
      test.skip(!apiKey, `${keyVar} not set`);

      const res = await request.get(url(app, `${api}/health`), { headers: { 'X-Api-Key': apiKey! } });
      expect(res.ok(), `could not read ${name}'s health (HTTP ${res.status()})`).toBeTruthy();
      const checks: Array<{ type: string; source: string; message: string }> = await res.json();
      const errors = checks.filter((c) => c.type === 'error').map((c) => `${c.source}: ${c.message}`);
      expect(errors, `${name} reports health errors`).toEqual([]);
    });
  }

  // Credentials copied between apps. Each app below holds its own copy of
  // another app's API key, taken at setup. Regenerate a key or rebuild a
  // config volume and the copy goes stale, and only the app holding it
  // notices, in its own logs.

  // Prowlarr pushes its indexers to Sonarr and Radarr through these
  // applications. No application at all means they get no indexers from it.
  // testall skips an application whose sync is disabled, so results are
  // matched by id: a missing result is a failure, not a pass.
  test('Prowlarr — every application it syncs to passes its own test', async ({ request }) => {
    const apiKey = process.env.PROWLARR_API_KEY;
    test.skip(!apiKey, 'PROWLARR_API_KEY not set');
    const headers = { 'X-Api-Key': apiKey! };

    const listRes = await request.get(url('prowlarr', '/api/v1/applications'), { headers });
    expect(listRes.ok(), `could not list Prowlarr's applications (HTTP ${listRes.status()})`).toBeTruthy();
    const apps: Array<{ id: number; name: string; enable: boolean }> = await listRes.json();
    expect(apps.map((a) => a.name), 'Prowlarr has no applications, so Sonarr and Radarr get no indexers from it').not.toEqual([]);

    const testRes = await request.post(url('prowlarr', '/api/v1/applications/testall'), { headers, timeout: 60_000 });
    expect([200, 400], `applications testall answered HTTP ${testRes.status()}`).toContain(testRes.status());
    const results: Array<{ id: number; isValid: boolean; validationFailures: Array<{ errorMessage: string; isWarning?: boolean }> }> =
      await testRes.json();

    const failures = apps.flatMap((a) => {
      const result = results.find((r) => r.id === a.id);
      if (!result) return [`${a.name}: not tested${a.enable ? '' : ' (sync is disabled)'}`];
      if (result.isValid) return [];
      return [`${a.name}: ${result.validationFailures.filter((f) => !f.isWarning).map((f) => f.errorMessage).join('; ')}`];
    });
    expect(failures, 'Prowlarr applications failing their own test').toEqual([]);
  });

  // Seerr hands requests to Radarr and Sonarr with the keys it stored at
  // setup; with a stale one, requests show "Failed" in Seerr while every app
  // is up. Probed through Seerr's own test endpoint, so it is Seerr's copy of
  // the key and Seerr's route to the app that get tested. Server ids are
  // Seerr's own and change when a server is re-added, so every listed server
  // is probed rather than a fixed id.
  for (const [kind, name, media] of [
    ['radarr', 'Radarr', 'movie'],
    ['sonarr', 'Sonarr', 'TV'],
  ] as const) {
    test(`Seerr — every ${name} server it knows answers with the settings Seerr stored`, async ({ request }) => {
      requireStackReachable(test.skip);
      const headers = { 'X-Api-Key': readSeerrApiKey() };

      const listRes = await request.get(url('seerr', `/api/v1/settings/${kind}`), { headers });
      expect(listRes.ok(), `could not list Seerr's ${name} servers (HTTP ${listRes.status()})`).toBeTruthy();
      const servers: Array<{ id: number; name: string }> = await listRes.json();
      expect(servers.map((s) => s.name), `Seerr has no ${name} server, so ${media} requests have nowhere to go`).not.toEqual([]);

      const failures: string[] = [];
      for (const server of servers) {
        const probe = await request.post(url('seerr', `/api/v1/settings/${kind}/test`), {
          headers,
          data: server,
          timeout: 30_000,
        });
        if (!probe.ok()) failures.push(`${server.name} (id ${server.id}): HTTP ${probe.status()}`);
      }
      expect(failures, `Seerr cannot reach ${name} with the settings it has stored`).toEqual([]);
    });
  }

  // Bazarr keeps its own copy of the Sonarr and Radarr keys. With a stale one
  // it stops syncing that library: no new subtitles, and its lists quietly
  // age. Compared with the key each app reports now. Booleans only, so a
  // failure never prints a key.
  test('Bazarr — its stored Sonarr and Radarr API keys are the current ones', async ({ request }) => {
    const bazarrKey = process.env.BAZARR_API_KEY;
    const keys = { sonarr: process.env.SONARR_API_KEY, radarr: process.env.RADARR_API_KEY };
    test.skip(!bazarrKey || !keys.sonarr || !keys.radarr, 'BAZARR_API_KEY, SONARR_API_KEY and RADARR_API_KEY are all needed');

    const settingsRes = await request.get(url('bazarr', '/api/system/settings'), { headers: { 'X-API-KEY': bazarrKey! } });
    expect(settingsRes.ok(), `could not read Bazarr's settings (HTTP ${settingsRes.status()})`).toBeTruthy();
    const settings: Record<'sonarr' | 'radarr', { apikey?: string }> = await settingsRes.json();

    for (const [app, name] of [['sonarr', 'Sonarr'], ['radarr', 'Radarr']] as const) {
      const hostRes = await request.get(url(app, '/api/v3/config/host'), { headers: { 'X-Api-Key': keys[app]! } });
      expect(hostRes.ok(), `could not read ${name}'s current API key (HTTP ${hostRes.status()})`).toBeTruthy();
      const current: unknown = (await hostRes.json()).apiKey;
      // Or two missing keys would compare equal.
      expect(typeof current === 'string' && current !== '', `${name} did not report an API key`).toBe(true);
      expect(
        settings[app]?.apikey === current,
        `Bazarr's stored ${name} API key is not ${name}'s current one; update it in Bazarr → Settings → ${name}`,
      ).toBe(true);
    }
  });
});
