import { test, expect } from '@playwright/test';
import { requireStackReachable, docker, dockerExec, GLUETUN_NAMESPACE_SERVICES } from './helpers';

// After gluetun restarts or is recreated, its dependents can be left on a
// namespace that no longer exists: running, answering on localhost, healthy by
// their own healthcheck, and cut off from everything else (docs/
// TROUBLESHOOTING.md, "Stale Network Namespace" and "After a Gluetun
// RECREATE"). Nothing goes red, so this asks the two questions that tell.

test.describe('Resilience', () => {
  for (const service of GLUETUN_NAMESPACE_SERVICES) {
    test(`${service} is joined to gluetun's current network namespace`, () => {
      requireStackReachable(test.skip);

      const gluetunId = docker(['inspect', '--format', '{{.Id}}', 'gluetun']).trim();
      const [mode, running] = docker(['inspect', '--format', '{{.HostConfig.NetworkMode}} {{.State.Running}}', service])
        .trim()
        .split(' ');

      // A gluetun restart can SIGKILL a dependent and leave it Exited.
      expect(running, `${service} is not running; try: docker restart ${service}`).toBe('true');

      // Recreated gluetun: the dependent still names the old container, and
      // `docker restart` cannot rejoin it. Only compose can.
      expect(
        mode,
        `${service} is joined to a gluetun container that no longer exists. ` +
          `Recreate it: docker compose -f docker-compose.arr-stack.yml up -d ${service}`,
      ).toBe(`container:${gluetunId}`);

      // Restarted gluetun: same container, new namespace. The dependent is a
      // zombie on the old one, which only the namespace itself can show.
      const netns = (container: string) => dockerExec(container, ['readlink', '/proc/self/ns/net']).trim();
      expect(
        netns(service),
        `${service} is on the namespace gluetun had before its last restart; try: docker restart ${service}`,
      ).toBe(netns('gluetun'));
    });
  }
});
