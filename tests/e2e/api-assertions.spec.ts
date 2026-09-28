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
});
