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

test.describe('Admin-UI HTTPS tier', () => {
  // Targets the documented 2026-08-01 incident: Traefik can be recreated via
  // the wrong compose file, silently lose its traefik-lan macvlan, and keep
  // reporting healthy while every .lan URL is actually dead. A container
  // health check can't see this — only an end-to-end HTTP request through
  // Traefik's actual routing logic can. Send the Host header directly to
  // TRAEFIK_LAN_IP rather than relying on the test runner's own DNS
  // resolution working, so this test isolates Traefik's routing specifically.
  //
  // Every `.lan` host (admin tier and, since the Jellyfin/Seerr extension,
  // media tier too) now redirects http→https and requires basicauth — see
  // docs/HTTPS-LOCAL.md. Smoke-checks a few representative hosts rather than
  // all 13: the routing/TLS/auth mechanism is identical per-host (see
  // traefik/dynamic/local-services.yml's `-secure` router pattern), so this
  // catches a regression in the shared mechanism without re-testing config
  // that's already covered statically. sonarr.lan represents the original
  // admin-tier hosts; jellyfin.lan/seerr.lan cover the newer media-tier
  // hosts, which have their own app-level login in addition to this gate.
  //
  // Deliberate coverage gap: these tests only prove the 401-without-creds
  // gate, not that a *credentialed* request reaches the right backend -
  // admin-auth short-circuits before Traefik ever forwards the request, so a
  // dead/misconfigured backend would also return 401 and pass here. Doing
  // better would mean wiring a dedicated test-only basicauth credential into
  // .env.e2e (the human admin-auth password isn't available to this suite,
  // and reusing it would leak into `.env.e2e`, an inappropriate place for a
  // credential shared with real devices) - out of scope for this change.
  // Backend health for Jellyfin/Seerr specifically is already covered
  // independently by ui-screenshots.spec.ts, which logs into both via their
  // direct LAN-published ports (bypassing Traefik entirely).
  for (const domain of ['sonarr.lan', 'jellyfin.lan', 'seerr.lan'] as const) {
    test(`http ${domain} redirects to https`, async ({ request }) => {
      test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');

      const res = await request.get(`http://${TRAEFIK_LAN_IP}/`, {
        headers: { Host: domain },
        maxRedirects: 0,
      });
      expect(res.status()).toBe(301);
      expect(res.headers()['location']).toBe(`https://${domain}/`);
    });

    test(`https ${domain} without credentials is rejected`, async () => {
      test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP not set');

      // Can't use Playwright's `request` fixture with a spoofed Host header
      // here: Traefik's `sniStrict: true` (tls.yml) rejects the TLS
      // handshake outright unless the *SNI* itself is a real `.lan`
      // hostname (confirmed live - connecting by bare IP gets a TLS
      // "unrecognized_name" alert before any HTTP response), and
      // Playwright's request context has no way to set SNI independently of
      // the connection address (tried dns.setServers() to make the hostname
      // resolve for real - it doesn't work, Playwright's fixture resolves
      // through a path that ignores it, unlike the historical
      // dns.resolve4/6-vs-dns.lookup() distinction documented in git
      // history for this file). Node's own `https` module *does* expose SNI
      // (`servername`) separately from the connection target, exactly like
      // curl's `--resolve` - use it directly instead.
      //
      // rejectUnauthorized stays false because the mkcert CA root never
      // leaves the machine that generated it (see docs/HTTPS-LOCAL.md) - the
      // e2e runner has no copy to verify against. Asserting on the presented
      // cert's own SAN list instead catches the actual regression this
      // guards against: a stale/wrong cert deployed without this host in its
      // SAN list still completes a TLS handshake (mkcert leaf, just for the
      // wrong names) but wouldn't list `domain` under subjectaltname.
      const { status, subjectaltname } = await new Promise<{ status: number; subjectaltname: string }>((resolve, reject) => {
        const req = https.request(
          {
            host: TRAEFIK_LAN_IP,
            port: 443,
            path: '/',
            method: 'GET',
            servername: domain,
            headers: { Host: domain },
            rejectUnauthorized: false,
            timeout: 10_000,
          },
          (res) => {
            const cert = res.socket && 'getPeerCertificate' in res.socket ? (res.socket as import('tls').TLSSocket).getPeerCertificate() : null;
            res.resume();
            resolve({ status: res.statusCode ?? 0, subjectaltname: cert?.subjectaltname ?? '' });
          },
        );
        req.on('error', reject);
        req.on('timeout', () => req.destroy(new Error('request timed out')));
        req.end();
      });
      expect(status).toBe(401);
      expect(subjectaltname).toContain(`DNS:${domain}`);
    });
  }
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
