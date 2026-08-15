import { execFileSync } from 'node:child_process';
import * as path from 'node:path';
import { test, expect } from '@playwright/test';
import { DOCKER_AVAILABLE } from './helpers';

const ZOMBIE_SCRIPT = path.join(__dirname, '../../scripts/detect-vpn-zombies.sh');

test.describe('Gluetun zombie-container detection', () => {
  test("VPN-tunneled dependents share Gluetun's current netns (no stale zombie)", () => {
    // The nastiest documented failure mode: on a Gluetun *recreate* (new
    // container ID — not just a restart, which gluetun-recover already
    // handles), dependents with network_mode: service:gluetun/container:gluetun
    // can become invisible zombies — healthy on their own localhost, but
    // unreachable from the rest of the stack. Neither docker ps, health
    // status, nor deunhealth can see this. Delegates to
    // scripts/detect-vpn-zombies.sh (also usable standalone via SSH/cron)
    // so the detection logic has one source of truth.
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');

    try {
      const output = execFileSync('bash', [ZOMBIE_SCRIPT], { encoding: 'utf8', timeout: 15_000 });
      expect(output).toContain('OK');
    } catch (err: any) {
      const output = (err.stdout ?? '') + (err.stderr ?? '');
      throw new Error(`Zombie container(s) detected:\n${output}`);
    }
  });
});
