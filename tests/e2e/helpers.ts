import { execFileSync } from 'node:child_process';
import * as path from 'path';

export const HOST = process.env.NAS_HOST ?? 'localhost';
export const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

export function screenshotPath(name: string) {
  return path.join(SCREENSHOTS_DIR, `${name}.png`);
}

// ─── Service ports ───────────────────────────────────────────────────────────

export const PORTS = {
  jellyfin: 8096,
  sonarr: 8989,
  radarr: 7878,
  prowlarr: 9696,
  qbittorrent: 8085,
  sabnzbd: 8082,
  seerr: 5055,
  bazarr: 6767,
  pihole: 8081,
  decypharr: 8282,
  magnetioAddon: 7000,
  stremioJellyfin: 60421,
  homepage: 3000,
} as const;

export function url(service: keyof typeof PORTS, pathStr = '') {
  return `http://${HOST}:${PORTS[service]}${pathStr}`;
}

// ─── UI auth helpers ─────────────────────────────────────────────────────────

/** Intercept all requests and add a custom header. Works for SPA auth bypass. */
export async function addHeaderToAllRequests(page: import('@playwright/test').Page, name: string, value: string) {
  await page.route('**/*', async (route) => {
    const headers = { ...route.request().headers(), [name]: value };
    await route.continue({ headers });
  });
}

// ─── Docker-exec helpers ─────────────────────────────────────────────────────
//
// The tests that use these (VPN egress/leak checks, zombie-container
// detection, published-port checks) need local `docker` CLI + socket access,
// which is only available when the suite runs directly on the NAS — not from
// a remote dev machine pointed at NAS_HOST over the network. DOCKER_AVAILABLE
// gates those tests to test.skip() off-NAS, consistent with this suite's
// existing convention of skipping on missing config rather than failing.

export const DOCKER_AVAILABLE = (() => {
  try {
    execFileSync('docker', ['version', '--format', '{{.Server.Version}}'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

export function dockerExec(container: string, cmd: string[], timeoutMs = 10_000): string {
  return execFileSync('docker', ['exec', container, ...cmd], { encoding: 'utf8', timeout: timeoutMs }).trim();
}

export function dockerInspect(container: string, format: string): string {
  return execFileSync('docker', ['inspect', '--format', format, container], { encoding: 'utf8' }).trim();
}

/**
 * Egress IP as seen by an external service, fetched from inside `container`.
 * Different images ship different HTTP clients (Gluetun's alpine-based image
 * only has wget; LSIO images have curl) so try curl then fall back to wget
 * inside one shell invocation rather than guessing per-container. Uses the
 * `/ip` path specifically: ifconfig.me serves curl a plain IP at the bare
 * root, but serves wget (no Accept header) its full HTML homepage instead —
 * `/ip` returns plain text for both clients, confirmed live against Gluetun.
 * Returns null on timeout/failure (e.g. killswitch correctly blocking egress).
 */
export function egressIp(container: string): string | null {
  try {
    return dockerExec(container, [
      'sh', '-c',
      'curl -s --max-time 5 https://ifconfig.me/ip || wget -qO- --timeout=5 https://ifconfig.me/ip',
    ], 15_000);
  } catch {
    return null;
  }
}
