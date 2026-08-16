import { execFileSync } from 'node:child_process';
import * as https from 'node:https';
import { test, expect } from '@playwright/test';
import { HOST, DOCKER_AVAILABLE, dockerInspect } from './helpers';

const TRAEFIK_LAN_IP = process.env.TRAEFIK_LAN_IP;

test.describe('DNS resolution', () => {
  test('Pi-hole resolves jellyfin.lan to the Traefik macvlan IP', () => {
    test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');

    // Pi-hole's DNS port is published on the host (${NAS_IP}:53), so this is
    // reachable without docker exec — works from a remote dev machine too,
    // not just on the NAS itself.
    let resolved: string;
    try {
      resolved = execFileSync('dig', [`@${HOST}`, 'jellyfin.lan', '+short'], { encoding: 'utf8', timeout: 5_000 }).trim();
    } catch (err) {
      test.skip(true, `dig not available or query failed: ${err}`);
      return;
    }
    expect(resolved).toBe(TRAEFIK_LAN_IP);
  });
});

test.describe('Traefik routing', () => {
  // Targets the documented 2026-08-01 incident: Traefik can be recreated via
  // the wrong compose file, silently lose its traefik-lan macvlan, and keep
  // reporting healthy while every .lan URL is actually dead. A container
  // health check can't see this — only an end-to-end HTTP request through
  // Traefik's actual routing logic can. Send the Host header directly to
  // TRAEFIK_LAN_IP rather than relying on the test runner's own DNS
  // resolution working, so this test isolates Traefik's routing specifically.
  for (const [domain, expectPath, expectMarker] of [
    // Both are media-tier, plain-HTTP, unauthenticated endpoints, so no API
    // key or TLS/basicauth handling is needed just to prove the routing
    // works end-to-end. Admin-tier hosts (Sonarr et al.) now redirect to
    // HTTPS + basicauth (see docs/HTTPS-LOCAL.md) and are covered instead by
    // the "Admin-UI HTTPS tier" suite below.
    ['jellyfin.lan', '/System/Info/Public', 'Jellyfin'],
    ['seerr.lan', '/api/v1/status', 'version'],
  ] as const) {
    test(`curling ${domain} end-to-end returns the real backend, not a Traefik routing error`, async ({ request }) => {
      test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');

      // maxRedirects: 0 and a manual re-request by path (never by the
      // Location header's hostname) keeps this test's "connect by IP, spoof
      // Host" trick intact through a login redirect too. Auto-following
      // (Playwright's default) issues the follow-up request against the
      // Location header's actual hostname, which needs real DNS — and
      // Playwright's own request context resolves via dns.resolve4/6
      // (bypassing /etc/hosts and Node's --dns-result-order), so neither
      // --add-host nor NODE_OPTIONS could fix it. This app (e.g. Sonarr)
      // redirects to a *.lan hostname whose AAAA record is deliberately "::"
      // (see pihole/dnsmasq.d/02-local-dns.conf.example) for musl containers
      // elsewhere in the stack — resolving that "::" here landed on the
      // NAS's own loopback-bound UGOS admin panel instead of failing,
      // producing a confusing false result (run 31968540414).
      let res = await request.get(`http://${TRAEFIK_LAN_IP}${expectPath}`, {
        headers: { Host: domain },
        ignoreHTTPSErrors: true,
        maxRedirects: 0,
      });
      if (res.status() >= 300 && res.status() < 400) {
        const location = new URL(res.headers()['location'], `http://${domain}`);
        res = await request.get(`http://${TRAEFIK_LAN_IP}${location.pathname}${location.search}`, {
          headers: { Host: domain },
          ignoreHTTPSErrors: true,
          maxRedirects: 0,
        });
      }
      expect(res.status()).toBe(200);
      const body = await res.text();
      expect(body).toContain(expectMarker);
    });
  }
});

test.describe('Admin-UI HTTPS tier', () => {
  // Smoke-checks the Phase 4 HTTPS/basicauth gate (docs/HTTPS-LOCAL.md) on
  // one representative admin host rather than all 11 - the routing itself
  // is identical per-host (see traefik/dynamic/local-services.yml's
  // `-secure` router pattern), so this catches a regression in the shared
  // mechanism without re-testing config that's already covered statically.
  test('http sonarr.lan redirects to https', async ({ request }) => {
    test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');

    const res = await request.get(`http://${TRAEFIK_LAN_IP}/`, {
      headers: { Host: 'sonarr.lan' },
      maxRedirects: 0,
    });
    expect(res.status()).toBe(301);
    expect(res.headers()['location']).toBe('https://sonarr.lan/');
  });

  test('https sonarr.lan without credentials is rejected', async () => {
    test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');

    // Unlike the plain-HTTP tests above, this can't use Playwright's
    // `request` fixture with a spoofed Host header: Traefik's
    // `sniStrict: true` (tls.yml) rejects the TLS handshake outright unless
    // the *SNI* itself is a real `.lan` hostname (confirmed live - connecting
    // by bare IP gets a TLS "unrecognized_name" alert before any HTTP
    // response), and Playwright's request context has no way to set SNI
    // independently of the connection address (tried dns.setServers() to
    // make `sonarr.lan` resolve for real - it doesn't work, Playwright's
    // fixture resolves through a path that ignores it, unlike the historical
    // dns.resolve4/6-vs-dns.lookup() distinction the comment above is about).
    // Node's own `https` module *does* expose SNI (`servername`) separately
    // from the connection target, exactly like curl's `--resolve` - use it
    // directly instead.
    const status = await new Promise<number>((resolve, reject) => {
      const req = https.request(
        {
          host: TRAEFIK_LAN_IP,
          port: 443,
          path: '/',
          method: 'GET',
          servername: 'sonarr.lan',
          headers: { Host: 'sonarr.lan' },
          rejectUnauthorized: false,
          timeout: 10_000,
        },
        (res) => {
          res.resume();
          resolve(res.statusCode ?? 0);
        },
      );
      req.on('error', reject);
      req.on('timeout', () => req.destroy(new Error('request timed out')));
      req.end();
    });
    expect(status).toBe(401);
  });
});

test.describe('Pi-hole port publication', () => {
  test('Pi-hole DNS/web ports are actually published on the host (not silently dropped)', () => {
    // Targets the documented 2026-08-05 incident: UGOS reverted the NAS to
    // DHCP on boot, and Pi-hole's IP-pinned port bindings silently failed to
    // establish while the container still showed Up/healthy — Pi-hole's own
    // `dig @127.0.0.1` healthcheck can't see this because it queries inside
    // the container's own netns, not the published host binding. Only
    // inspecting the actual port mapping reveals it. (The boot-time root
    // cause — UGOS reverting DHCP — isn't testable from here; it's mitigated
    // separately by scripts/boot-compose-up.sh + the systemd unit.)
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');

    const portsJson = dockerInspect('pihole', '{{json .NetworkSettings.Ports}}');
    const ports = JSON.parse(portsJson) as Record<string, unknown>;

    for (const key of ['53/tcp', '53/udp', '80/tcp']) {
      expect(ports[key], `expected ${key} to be published`).toBeTruthy();
      expect(ports[key], `${key} binding is null — port silently unpublished`).not.toBeNull();
    }
  });
});
