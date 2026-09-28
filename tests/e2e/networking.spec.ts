import { test, expect } from '@playwright/test';
import { promises as dns } from 'dns';
import * as fs from 'fs';
import * as path from 'path';
import { HOST, requireStackReachable, docker } from './helpers';

// The .lan tier end to end, as a browser on the LAN uses it: Pi-hole answers
// <name>.lan with Traefik's macvlan IP, and Traefik routes by Host header to
// the service. Every hop can break while each container stays healthy on its
// own: a stale Pi-hole mapping, a traefik recreated without its macvlan (see
// docs/TROUBLESHOOTING.md), or a router pointing at the wrong backend.
//
// Run from a LAN machine, not the NAS: the NAS cannot reach its own macvlan
// addresses.

const TRAEFIK_LAN_IP = process.env.TRAEFIK_LAN_IP;

// The hosts come from the tracked Traefik config, so a router added there is
// tested without anyone editing this file, provided it has an entry below.
const LOCAL_SERVICES = path.resolve(__dirname, '../../traefik/dynamic/local-services.yml');
const ROUTED_HOSTS = [...fs.readFileSync(LOCAL_SERVICES, 'utf8').matchAll(/Host\(`([^`]+\.lan)`\)/g)].map((m) => m[1]);

// What each host must answer with. A marker only that app serves, so Traefik's
// own 404, or a route to the wrong backend, cannot pass as routed. `optional`
// names the container of a utility that may not be deployed at all.
type Route = { path: string; marker: RegExp; optional?: string } | { path: string; redirect: string };
const ROUTES: Record<string, Route> = {
  'jellyfin.lan': { path: '/System/Info/Public', marker: /"ProductName":"Jellyfin Server"/ },
  'seerr.lan': { path: '/login', marker: /<title[^>]*>[^<]*Seerr<\/title>/ },
  'jellyseerr.lan': { path: '/', redirect: 'http://seerr.lan/' },
  'jellyseer.lan': { path: '/', redirect: 'http://seerr.lan/' },
  'sonarr.lan': { path: '/login', marker: /<title>[^<]*Sonarr<\/title>/ },
  'radarr.lan': { path: '/login', marker: /<title>[^<]*Radarr<\/title>/ },
  'prowlarr.lan': { path: '/login', marker: /<title>[^<]*Prowlarr<\/title>/ },
  'bazarr.lan': { path: '/', marker: /<title>Bazarr<\/title>/ },
  'qbit.lan': { path: '/', marker: /<title>(VueTorrent|qBittorrent[^<]*)<\/title>/ },
  'sabnzbd.lan': { path: '/', marker: /SABnzbd/ },
  'traefik.lan': { path: '/dashboard/', marker: /<title>Traefik[^<]*<\/title>/ },
  'pihole.lan': { path: '/admin/login', marker: /<title>Pi-hole[^<]*<\/title>/ },
  'uptime.lan': { path: '/dashboard', marker: /<title>Uptime Kuma<\/title>/, optional: 'uptime-kuma' },
  'duc.lan': { path: '/', marker: /duc\.cgi/, optional: 'duc' },
  'beszel.lan': { path: '/', marker: /<title>Beszel<\/title>/, optional: 'beszel' },
};

// Pi-hole publishes DNS on the NAS's address; queries go straight there, not
// through whatever resolver this machine happens to use.
let nasAddress: Promise<string> | undefined;
function nasIp(): Promise<string> {
  nasAddress ??= dns.lookup(HOST, { family: 4 }).then((r) => r.address);
  return nasAddress;
}

async function resolveViaPihole(name: string): Promise<string[]> {
  const resolver = new dns.Resolver({ timeout: 3_000, tries: 2 });
  resolver.setServers([await nasIp()]);
  return resolver.resolve4(name);
}

test.describe('Networking', () => {
  // Pi-hole's healthcheck digs 127.0.0.1 from inside its own container, so it
  // stays green when nothing on the LAN can reach it. Every client, and every
  // .lan name, depends on port 53 being published on the address they use.
  test('Pi-hole — DNS is published on the NAS over UDP and TCP', async () => {
    requireStackReachable(test.skip);

    const ports: Record<string, Array<{ HostIp: string; HostPort: string }> | null> = JSON.parse(
      docker(['inspect', '--format', '{{json .NetworkSettings.Ports}}', 'pihole']),
    );
    const ip = await nasIp();
    for (const proto of ['udp', 'tcp']) {
      const bindings = ports[`53/${proto}`] ?? [];
      expect(
        bindings.some((b) => b.HostPort === '53' && [ip, '0.0.0.0', '::', ''].includes(b.HostIp)),
        `Pi-hole's 53/${proto} is not published on ${ip}:53; bindings: ${JSON.stringify(bindings)}`,
      ).toBe(true);
    }
  });

  test('every routed .lan host has an expected response defined here', () => {
    expect(ROUTED_HOSTS.length, `no Host(\`*.lan\`) rules found in ${LOCAL_SERVICES}`).toBeGreaterThan(0);
    expect(ROUTED_HOSTS.filter((h) => !ROUTES[h]), 'add these hosts to ROUTES in networking.spec.ts').toEqual([]);
  });

  for (const host of ROUTED_HOSTS) {
    test(`${host} resolves to Traefik and reaches its service`, async ({ request }) => {
      test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');
      requireStackReachable(test.skip);
      const route = ROUTES[host];
      test.skip(!route, `no expected response for ${host} (the test above fails for this)`);

      if ('optional' in route && route.optional) {
        // Not deployed at all is fine; deployed but stopped is not.
        let deployed = true;
        try {
          docker(['inspect', '--format', '{{.Id}}', route.optional]);
        } catch {
          deployed = false;
        }
        test.skip(!deployed, `${route.optional} is not deployed here (optional utility)`);
      }

      expect(await resolveViaPihole(host), `Pi-hole does not answer ${host} with Traefik's LAN IP`).toEqual([TRAEFIK_LAN_IP]);

      const res = await request.get(`http://${TRAEFIK_LAN_IP}${route.path}`, {
        headers: { Host: host },
        maxRedirects: 0,
        timeout: 15_000,
      });
      if ('redirect' in route) {
        expect([301, 302, 307, 308], `${host} should redirect; got HTTP ${res.status()}`).toContain(res.status());
        expect(res.headers()['location'], `${host} redirects somewhere else`).toBe(route.redirect);
      } else {
        expect(res.status(), `${host}${route.path} through Traefik`).toBe(200);
        const body = await res.text();
        const seen = body.match(/<title[^>]*>[^<]*<\/title>/)?.[0] ?? body.slice(0, 120);
        expect(route.marker.test(body), `${host} answered, but not as its service; got: ${seen}`).toBe(true);
      }
    });
  }
});
