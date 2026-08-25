import { test, expect } from '@playwright/test';
import {
  DOCKER_TRANSPORT,
  requireStackReachable,
  TUNNELED_SERVICES,
  dockerInspect,
} from './helpers';

//
// Is every VPN-tunneled service actually inside the Gluetun that is running
// right now?
//
// Restarting Gluetun is harmless — the container ID survives and its
// dependents come back with it. Recreating it is not. A recreate mints a new
// ID, and `docker compose up -d` will recreate Gluetun whenever its own
// definition has drifted, even when the command was aimed at something else
// entirely. The dependents stay pinned to an ID that no longer exists, and
// Docker never corrects the reference.
//
// What makes this worth a test rather than a healthcheck is that nothing
// routine can see it. `docker ps` prints Up. The container's own healthcheck
// passes, because it asks its own localhost. deunhealth stays quiet, because
// nothing ever reports unhealthy. The service is simply unreachable from the
// rest of the stack, and its traffic has nowhere to go.
//
// scripts/detect-vpn-zombies.sh answers the same question from a shell, and is
// the thing to run over SSH or on a timer. This asks the containers directly
// through whichever docker daemon owns the stack — this machine's when they
// are here, the NAS's over SSH otherwise — so it works from a dev machine,
// which a `bash scripts/…` call would not. tests/vpn-zombies.bats unit-tests
// the script itself with docker stubbed. The two lists are held together by a
// drift guard in that file.
//

test.describe('Gluetun namespace integrity', () => {
  test.beforeAll(() => {
    console.log(`  [resilience] docker transport: ${DOCKER_TRANSPORT}`);
  });

  test.beforeEach(() => {
    requireStackReachable(test.skip);
  });

  for (const service of TUNNELED_SERVICES) {
    test(`${service} is inside Gluetun's current network namespace`, () => {
      const liveNamespace = dockerInspect('gluetun', '{{.Id}}');
      expect(liveNamespace, 'gluetun reported no container ID').toBeTruthy();

      const netMode = dockerInspect(service, '{{.HostConfig.NetworkMode}}');

      // Assert the shape before the value. A service that has quietly stopped
      // being namespace-joined at all — moved to the bridge, say — would
      // otherwise fail with a confusing ID mismatch rather than the real
      // reason, and a service that is *supposed* to move belongs in
      // BRIDGE_SERVICES, not silently here.
      expect(
        netMode,
        `${service} is on "${netMode}", not joined to a container namespace at all`,
      ).toMatch(/^container:/);

      expect(
        netMode.replace(/^container:/, ''),
        `${service} is a zombie: pinned to a Gluetun container that is no longer running. ` +
          `It will look healthy in docker ps and unreachable to everything else. ` +
          `Fix: docker restart ${service}`,
      ).toBe(liveNamespace);
    });
  }
});
