import { execFileSync } from 'node:child_process';
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

test.describe('ProtonVPN exit node egress', () => {
  // Covers docker-compose.tailscale.yml's gluetun-exit / tailscale-exit pair:
  // a SECOND ProtonVPN tunnel whose only job is to be the internet egress for
  // the Tailscale exit node, so a phone using it gets home LAN access AND a
  // Proton IP simultaneously. Opt-in, so these skip when it isn't deployed.
  const running = (name: string): boolean => {
    try {
      return execFileSync('docker', ['inspect', '--format', '{{.State.Running}}', name], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim() === 'true';
    } catch {
      return false;
    }
  };

  test.beforeEach(() => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    test.skip(!running('gluetun-exit'), 'gluetun-exit not deployed — the ProtonVPN exit-node stack is opt-in');
  });

  test('gluetun-exit egress IP differs from host WAN IP', () => {
    // The whole point: traffic leaving the exit node must NOT carry the home
    // IP. If these ever match, the exit node is giving away exactly what the
    // user wanted hidden — and it would look fine from the phone.
    const exitIp = egressIp('gluetun-exit');
    const hostIp = egressIp('sonarr'); // bridge-only — gives host WAN egress
    expect(exitIp).toBeTruthy();
    expect(hostIp).toBeTruthy();
    expect(exitIp).not.toBe(hostIp);
  });

  test('tailscale-exit egress IP matches gluetun-exit (sharing its netns, not leaking)', () => {
    // Deliberately NOT asserting gluetun-exit differs from gluetun: both are
    // pinned to VPN_EXIT_COUNTRIES/VPN_COUNTRIES=Netherlands and may
    // legitimately land on the same Proton server, which would make that a
    // flaky test rather than a meaningful one.
    const exitIp = egressIp('gluetun-exit');
    const tsIp = egressIp('tailscale-exit');
    const hostIp = egressIp('sonarr');
    expect(exitIp).toBeTruthy();
    expect(tsIp).toBeTruthy();
    expect(tsIp).toBe(exitIp);
    expect(tsIp).not.toBe(hostIp);
  });
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

test.describe('Exit-node killswitch — chaos test', () => {
  test('stopping gluetun-exit blocks exit-node egress rather than leaking via the home connection', async () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    test.skip(
      process.env.ALLOW_DISRUPTIVE_TESTS !== '1',
      'set ALLOW_DISRUPTIVE_TESTS=1 to run this test — it stops the live gluetun-exit container, cutting internet for any device currently using the exit node',
    );
    test.setTimeout(180_000);

    const { execFileSync } = await import('node:child_process');

    const running = (name: string): boolean => {
      try {
        return execFileSync('docker', ['inspect', '--format', '{{.State.Running}}', name], {
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore'],
        }).trim() === 'true';
      } catch {
        return false;
      }
    };
    test.skip(!running('gluetun-exit'), 'gluetun-exit not deployed — the ProtonVPN exit-node stack is opt-in');

    // This is the property the whole exit-node feature exists to guarantee:
    // if the Proton tunnel dies, traffic must stop dead rather than fall back
    // to the home connection. A fallback would hand out exactly the IP the
    // user is paying to hide, and it would look completely normal from the
    // phone. It was verified by hand once (Go/No-Go check I, 2026-08-23);
    // this is the regression guard so it stays verified.
    //
    // What this does and does NOT prove: it asserts the NAS side never
    // egresses via the host route while the tunnel is down. It cannot drive a
    // real tailnet client, so the client-side half of check I — a phone
    // holding the exit node and losing internet entirely — remains a manual
    // test. Fail-closed on this side is the necessary condition for it.
    const hostIp = egressIp('sonarr'); // bridge-only — gives host WAN egress
    expect(hostIp).toBeTruthy();

    try {
      execFileSync('docker', ['stop', 'gluetun-exit'], { timeout: 30_000 });

      // tailscale-exit rides gluetun-exit's netns, so with the tunnel down it
      // must have no egress at all. Returning hostIp here is the failure this
      // test exists to catch: the exit node leaking the home IP.
      const leakCheckIp = egressIp('tailscale-exit');
      expect(leakCheckIp).not.toBe(hostIp);
      expect(leakCheckIp).toBeNull();
    } finally {
      execFileSync('docker', ['start', 'gluetun-exit'], { timeout: 30_000 });

      // Wait for the tunnel before touching its dependents — restarting them
      // against a half-built netns just re-orphans them.
      const deadline = Date.now() + 120_000;
      let healthy = false;
      while (Date.now() < deadline) {
        try {
          const status = execFileSync(
            'docker', ['inspect', '--format', '{{.State.Health.Status}}', 'gluetun-exit'], { encoding: 'utf8' },
          ).trim();
          if (status === 'healthy') { healthy = true; break; }
        } catch {
          // keep polling
        }
        await new Promise((r) => setTimeout(r, 2_000));
      }

      // A stop/start hands gluetun-exit a BRAND NEW network namespace, and
      // containers using `network_mode: service:gluetun-exit` are not moved
      // into it — they are left running against the dead one. deunhealth does
      // eventually notice and restart them, but it took ~2 minutes when this
      // was measured live, so restart them here rather than leaving the exit
      // node broken for the next test in the run.
      for (const dependent of ['tailscale-exit', 'tailscale-exit-routing']) {
        try {
          execFileSync('docker', ['restart', dependent], { timeout: 60_000 });
        } catch {
          // Not deployed, or already being restarted by deunhealth.
        }
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
