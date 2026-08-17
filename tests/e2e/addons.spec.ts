import { test, expect } from '@playwright/test';
import { url, DOCKER_AVAILABLE, dockerExec } from './helpers';

// Newer additions to the stack — Decypharr/TorBox, Magnetio, stremio-jellyfin
// — had zero test coverage before this file existed.

test.describe('Decypharr', () => {
  test('Decypharr web UI responds', async ({ request }) => {
    const res = await request.get(url('decypharr', '/'));
    expect(res.ok()).toBeTruthy();
  });
});

test.describe('Magnetio', () => {
  test('magnetio-scraper health endpoint responds', () => {
    // Internal only — no published port — so this needs docker exec.
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    const body = dockerExec('magnetio-scraper', ['wget', '-qO-', 'http://localhost:8080/health']);
    expect(body).toBeTruthy();
  });

  test('magnetio-addon manifest is reachable (published via Gluetun port 7000)', async ({ request }) => {
    const res = await request.get(url('magnetioAddon', '/manifest.json'));
    expect(res.ok()).toBeTruthy();
    const manifest = await res.json();
    expect(manifest.id ?? manifest.name).toBeTruthy();
  });

  test('magnetio-redis responds to PING', () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    const password = process.env.MAGNETIO_REDIS_PASSWORD;
    test.skip(!password, 'MAGNETIO_REDIS_PASSWORD not set');

    const reply = dockerExec('magnetio-redis', ['redis-cli', '-a', password!, 'PING']);
    expect(reply).toContain('PONG');
  });
});

test.describe('stremio-jellyfin', () => {
  test('stremio-jellyfin manifest is reachable', async ({ request }) => {
    const res = await request.get(url('stremioJellyfin', '/manifest.json'));
    expect(res.ok()).toBeTruthy();
    const manifest = await res.json();
    expect(manifest.id ?? manifest.name).toBeTruthy();
  });
});

// Container-toolchain contracts. Regression for snags #14/#15 from the
// credential-drift work (2026-08-17): scripts written against an assumed
// toolchain broke live when a base image didn't have what was expected
// (Bazarr has no pyyaml, Seerr has no curl). These assert the toolchain
// shape the detector script and its tests rely on, so a future base-image
// bump that silently changes it fails here instead of in production.
test.describe('Container toolchain contracts', () => {
  test('seerr has no curl but does have node', () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');

    expect(() => dockerExec('seerr', ['which', 'curl'])).toThrow();
    expect(() => dockerExec('seerr', ['which', 'node'])).not.toThrow();
  });

  test('bazarr has no importable yaml module', () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');

    expect(() => dockerExec('bazarr', ['python3', '-c', 'import yaml'])).toThrow();
  });
});
