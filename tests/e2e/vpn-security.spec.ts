import { test, expect } from '@playwright/test';
import {
  DOCKER_TRANSPORT,
  requireStackReachable,
  TUNNELED_SERVICES,
  BRIDGE_SERVICES,
  egressIp,
  dockerInspect,
  dockerLifecycle,
} from './helpers';

//
// Does each service's traffic actually leave where it is supposed to?
//
// The only evidence that answers this is the public address a container's
// traffic emerges from. An earlier version of this check called Sonarr's API
// and treated a reply as proof the tunnel was up — reasoning that quietly
// stopped holding the day Sonarr and Radarr were moved off the VPN namespace,
// after which it proved nothing at all. Comparing egress addresses is what
// separates "tunneled" from "leaking"; nothing else does.
//
// The commands run against whichever docker daemon owns the stack: this
// machine's when the containers are here, otherwise the NAS's over SSH. An
// earlier version demanded they be local, so on any development machine the
// whole file skipped and the suite still exited 0 — a green run in which the
// VPN had not been examined once. See helpers.ts.
//
// scripts/check-vpn.sh performs the same comparison by hand. Keep the two in
// agreement.
//

test.describe('VPN egress — leak detection', () => {
  test.beforeAll(() => {
    // Printed so a run that reached the NAS over SSH is distinguishable from
    // one that silently examined nothing.
    console.log(`  [vpn-security] docker transport: ${DOCKER_TRANSPORT}`);
  });

  test.beforeEach(() => {
    requireStackReachable(test.skip);
  });

  test("Gluetun's exit address is not the NAS's own", () => {
    // Sonarr sits on the bridge, so whatever address it egresses from is the
    // host's ordinary WAN address — a free reference point for "untunneled".
    const throughTunnel = egressIp('gluetun');
    const throughHost = egressIp('sonarr');

    expect(throughTunnel).toBeTruthy();
    expect(throughHost).toBeTruthy();
    expect(throughTunnel).not.toBe(throughHost);
  });

  for (const service of TUNNELED_SERVICES) {
    test(`${service} leaves via Gluetun and not around it`, () => {
      // The assertion is equality with Gluetun, deliberately. Merely differing
      // from the NAS address would be far too weak: a service escaping down
      // some third route also differs from the NAS address, while being every
      // bit as untunneled as one going out the front door.
      const throughTunnel = egressIp('gluetun');
      const observed = egressIp(service);

      expect(throughTunnel).toBeTruthy();
      expect(observed).toBeTruthy();
      expect(observed).toBe(throughTunnel);
    });
  }

  for (const service of BRIDGE_SERVICES) {
    test(`${service} remains off the VPN (guards the migration)`, () => {
      // docs/MIGRATION-arr-off-vpn.md, expressed as something that cannot rot
      // silently. Should either of these begin matching Gluetun's address,
      // someone has put it back inside the tunnel — most likely by restoring
      // network_mode: "service:gluetun" — without touching the migration notes
      // or this file.
      const throughTunnel = egressIp('gluetun');
      const observed = egressIp(service);

      expect(throughTunnel).toBeTruthy();
      expect(observed).toBeTruthy();
      expect(observed).not.toBe(throughTunnel);
    });
  }
});

test.describe('VPN killswitch', () => {
  test('qBittorrent loses egress entirely when Gluetun stops, rather than falling back', async () => {
    requireStackReachable(test.skip);
    test.skip(
      process.env.ALLOW_DISRUPTIVE_TESTS !== '1',
      'set ALLOW_DISRUPTIVE_TESTS=1 to run — it stops the live Gluetun container, interrupting real downloads and searches',
    );
    test.setTimeout(120_000);

    const hostAddress = egressIp('sonarr');
    expect(hostAddress).toBeTruthy();

    try {
      dockerLifecycle('stop', 'gluetun');

      // With the killswitch intact the lookup cannot complete at all, so null
      // is the pass. Receiving an address instead — the host's above all —
      // would mean traffic found its way out around the dead tunnel, which is
      // the exact leak this exists to rule out.
      expect(egressIp('qbittorrent')).toBeNull();
    } finally {
      dockerLifecycle('start', 'gluetun');

      // Restore the stack whatever the assertion did, and confirm the restore
      // rather than assuming it.
      const giveUpAt = Date.now() + 90_000;
      let recovered = false;

      while (Date.now() < giveUpAt) {
        try {
          if (dockerInspect('gluetun', '{{.State.Health.Status}}') === 'healthy') {
            recovered = true;
            break;
          }
        } catch {
          // Gluetun is mid-restart and not yet inspectable; keep waiting.
        }
        await new Promise((resolve) => setTimeout(resolve, 2_000));
      }

      expect(recovered).toBeTruthy();
    }
  });
});
