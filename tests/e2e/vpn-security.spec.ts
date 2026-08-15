import { test, expect } from '@playwright/test';
import { DOCKER_AVAILABLE, egressIp } from './helpers';

// These tests need local `docker exec` access, so they only actually run on
// the NAS itself (not from a remote dev machine pointed at NAS_HOST). This
// replaces the old "VPN connectivity" test, which checked Sonarr's API —
// Sonarr was deliberately moved OFF Gluetun's VPN netns (see
// docs/MIGRATION-arr-off-vpn.md), so that test proved nothing about VPN
// health. These productionize scripts/check-vpn.sh's IP comparison,
// per-service, as an automated check instead of a manual one.

const TUNNELED_SERVICES = ['qbittorrent', 'prowlarr', 'sabnzbd', 'flaresolverr'] as const;
const BRIDGE_SERVICES = ['sonarr', 'radarr'] as const;

test.describe('VPN egress — leak detection', () => {
  test.beforeEach(() => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
  });

  test('Gluetun exit IP differs from host WAN IP', () => {
    const gluetunIp = egressIp('gluetun');
    const hostIp = egressIp('sonarr'); // sonarr is bridge-only — gives host WAN egress
    expect(gluetunIp).toBeTruthy();
    expect(hostIp).toBeTruthy();
    expect(gluetunIp).not.toBe(hostIp);
  });

  for (const service of TUNNELED_SERVICES) {
    test(`${service} egress IP matches Gluetun's exit IP (tunneled, not leaking)`, () => {
      const gluetunIp = egressIp('gluetun');
      const hostIp = egressIp('sonarr');
      const serviceIp = egressIp(service);
      expect(gluetunIp).toBeTruthy();
      expect(serviceIp).toBeTruthy();
      expect(serviceIp).toBe(gluetunIp);
      expect(serviceIp).not.toBe(hostIp);
    });
  }

  for (const service of BRIDGE_SERVICES) {
    test(`${service} egress IP matches host WAN IP, NOT Gluetun (post-migration regression guard)`, () => {
      // Codifies docs/MIGRATION-arr-off-vpn.md's intent as a permanent
      // automated check: Sonarr/Radarr were deliberately taken off the VPN
      // netns and must stay off it. If this ever starts matching Gluetun's
      // IP instead, something re-tunneled them (or moved them onto
      // network_mode: service:gluetun) without updating this test.
      const gluetunIp = egressIp('gluetun');
      const serviceIp = egressIp(service);
      expect(gluetunIp).toBeTruthy();
      expect(serviceIp).toBeTruthy();
      expect(serviceIp).not.toBe(gluetunIp);
    });
  }
});

test.describe('VPN killswitch — chaos test', () => {
  test('stopping Gluetun blocks qBittorrent egress rather than leaking via a fallback route', async () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    test.skip(
      process.env.ALLOW_DISRUPTIVE_TESTS !== '1',
      'set ALLOW_DISRUPTIVE_TESTS=1 to run this test — it stops the live Gluetun container, interrupting real downloads/searches',
    );
    test.setTimeout(90_000);

    const { execFileSync } = await import('node:child_process');
    const hostIp = egressIp('sonarr');
    expect(hostIp).toBeTruthy();

    try {
      execFileSync('docker', ['stop', 'gluetun'], { timeout: 30_000 });

      // A working killswitch means qBittorrent's egress call fails/times out
      // entirely — NOT that it falls back to the host's raw route. Returning
      // hostIp here would mean the killswitch failed and traffic leaked.
      const leakCheckIp = egressIp('qbittorrent');
      expect(leakCheckIp).toBeNull();
    } finally {
      execFileSync('docker', ['start', 'gluetun'], { timeout: 30_000 });

      // Wait for Gluetun to report healthy again before ending the test, so
      // the suite always leaves the stack in a working state.
      const deadline = Date.now() + 60_000;
      let healthy = false;
      while (Date.now() < deadline) {
        try {
          const status = execFileSync(
            'docker', ['inspect', '--format', '{{.State.Health.Status}}', 'gluetun'], { encoding: 'utf8' },
          ).trim();
          if (status === 'healthy') { healthy = true; break; }
        } catch {
          // keep polling
        }
        await new Promise((r) => setTimeout(r, 2_000));
      }
      expect(healthy).toBeTruthy();
    }
  });
});

test.describe('VPN port forwarding', () => {
  test('Gluetun forwarded port matches qBittorrent listening port', () => {
    // VPN_PORT_FORWARDING is not enabled in this stack's compose config
    // today (see .env.example's note on it as an optional provider feature)
    // — Gluetun's control server has no forwarded port to report. Nothing to
    // verify until port forwarding is actually turned on; left as an
    // explicit skip (not silently omitted) so it's easy to flesh out if that
    // changes.
    test.skip(true, 'VPN_PORT_FORWARDING is not configured in this stack — nothing to verify yet');
  });
});
