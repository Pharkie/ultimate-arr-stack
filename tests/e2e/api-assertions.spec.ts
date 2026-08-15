import { test, expect } from '@playwright/test';
import { url } from './helpers';

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
});
