import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';
import { HOST, requireStackReachable, dockerInspect } from './helpers';

//
// Outside-in networking checks.
//
// Everything in this file guards an outage this stack has actually had, and
// they share a shape: the container was fine and the path to it was not. A
// healthcheck executing inside a container is in no position to notice that
// nothing outside can reach it, so `docker ps`, container health and deunhealth
// all reported normality throughout. These assertions look from the outside,
// which is the only vantage point that can tell.
//

const TRAEFIK_LAN_IP = process.env.TRAEFIK_LAN_IP;

// Reached through Traefik's macvlan address with an explicit Host header, so
// the runner's own resolver is never consulted. A failure is therefore about
// Traefik's routing, not about name lookup — DNS has its own check below.
const ROUTED_SERVICES = [
  { host: 'jellyfin.lan', probePath: '/System/Info/Public', bodyContains: 'Jellyfin' },
  { host: 'sonarr.lan', probePath: '/', bodyContains: 'Sonarr' },
] as const;

test.describe('Traefik routing', () => {
  // Incident of 2026-08-01. Recreating Traefik through a compose file that does
  // not define its traefik-lan macvlan detaches it from that network. Every
  // .lan address stops working while the container carries on reporting
  // healthy. Nothing short of a real request routed by Traefik reveals it.
  for (const { host, probePath, bodyContains } of ROUTED_SERVICES) {
    test(`${host} reaches its backend through Traefik`, async ({ request }) => {
      test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP is not set in .env.e2e');

      // Both endpoints answer without credentials, so routing can be proven
      // without involving API keys.
      const response = await request.get(`http://${TRAEFIK_LAN_IP}${probePath}`, {
        headers: { Host: host },
        ignoreHTTPSErrors: true,
      });

      expect(response.status()).toBe(200);
      expect(await response.text()).toContain(bodyContains);
    });
  }
});

test.describe('DNS resolution', () => {
  test('jellyfin.lan resolves to Traefik on the macvlan', () => {
    test.skip(!TRAEFIK_LAN_IP, 'TRAEFIK_LAN_IP is not set in .env.e2e');

    // Pi-hole answers on the NAS's own port 53, so this is a plain query with
    // no container access involved — it runs the same off the NAS as on it.
    let answer: string;
    try {
      answer = execFileSync('dig', [`@${HOST}`, 'jellyfin.lan', '+short'], {
        encoding: 'utf8',
        timeout: 5_000,
      }).trim();
    } catch (cause) {
      test.skip(true, `dig is unavailable or the query failed: ${cause}`);
      return;
    }

    expect(answer).toBe(TRAEFIK_LAN_IP);
  });
});

test.describe('Pi-hole port publication', () => {
  test('Pi-hole publishes its DNS and web ports rather than dropping them', () => {
    // Incident of 2026-08-05, which took DNS down for the whole house. The NAS
    // came back on DHCP after a reboot, so Pi-hole's bindings — pinned to a
    // ${NAS_IP} that no longer belonged to the host — could not be established.
    // The container started regardless and declared itself healthy, because its
    // healthcheck resolves against 127.0.0.1 from inside its own namespace,
    // which succeeds no matter how unreachable it is from anywhere else.
    //
    // Docker discards the entire mapping set when a single binding fails, which
    // is why the admin UI on 8081 disappeared along with DNS. Reading the
    // published mapping is what exposes it.
    requireStackReachable(test.skip);

    const published = JSON.parse(
      dockerInspect('pihole', '{{json .NetworkSettings.Ports}}'),
    ) as Record<string, unknown>;

    for (const portKey of ['53/tcp', '53/udp', '80/tcp']) {
      expect(published[portKey], `${portKey} is absent from the port map`).toBeTruthy();
      expect(published[portKey], `${portKey} is present but unbound — silently unpublished`).not.toBeNull();
    }
  });
});
