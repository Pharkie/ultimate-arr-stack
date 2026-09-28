import { test, expect } from '@playwright/test';
import { isIP } from 'net';
import { requireStackReachable, docker, dockerExec, runOnNas, GLUETUN_NAMESPACE_SERVICES } from './helpers';

// Compares real egress IPs, measured from inside each container. Nothing
// weaker will do: a service's UI answering says nothing about which way its
// traffic leaves, and a check that reached Sonarr's API passed identically
// whether the VPN worked or leaked (see api-assertions.spec.ts).

// Prints the public IP the caller exits from, or NOEGRESS. Cloudflare's trace
// is fetched by IP literal first, so a Pi-hole wobble (gluetun's only DNS)
// cannot pass for a dead tunnel, and a dead tunnel cannot hide behind a DNS
// failure. curl where the image has it, else wget: gluetun ships only
// busybox wget. IPv4-only endpoints, so every measurement compares like with
// like.
const EGRESS_SCRIPT = [
  'get() { if command -v curl >/dev/null 2>&1; then curl -fsS -m 8 "$1"; else wget -qO- -T 8 "$1"; fi; }',
  'for u in https://1.1.1.1/cdn-cgi/trace https://1.0.0.1/cdn-cgi/trace; do',
  '  ip=$(get "$u" 2>/dev/null | sed -n "s/^ip=//p")',
  '  [ -n "$ip" ] && { echo "$ip"; exit 0; }',
  'done',
  'ip=$(get https://api.ipify.org 2>/dev/null)',
  '[ -n "$ip" ] && { echo "$ip"; exit 0; }',
  'echo NOEGRESS',
].join('\n');

function parseEgress(output: string, where: string): string | null {
  const out = output.trim();
  if (out === 'NOEGRESS') return null;
  if (isIP(out)) return out;
  throw new Error(`egress probe in ${where} printed neither an IP nor NOEGRESS: ${out.slice(0, 200)}`);
}

// null means the container has no route out at all.
function egressOf(container: string): string | null {
  return parseEgress(dockerExec(container, ['sh', '-c', EGRESS_SCRIPT], 45_000), container);
}

// The NAS's own connection, measured on the host rather than from a container.
function nasEgress(): string | null {
  return parseEgress(runOnNas(['sh', '-c', EGRESS_SCRIPT], 45_000), 'the NAS host');
}

let gluetunIp: string | undefined;
function vpnExit(): string {
  if (!gluetunIp) {
    const ip = egressOf('gluetun');
    expect(ip, 'gluetun has no egress at all; the tunnel is down').not.toBeNull();
    gluetunIp = ip!;
  }
  return gluetunIp;
}

test.describe('VPN security', () => {
  // If gluetun exits from the NAS's own address, the "tunnel" is not
  // tunnelling, and every comparison below would pass on a leak.
  test("gluetun exits somewhere other than the NAS's own connection", () => {
    requireStackReachable(test.skip);
    const nas = nasEgress();
    expect(nas, 'the NAS host has no egress, so there is nothing to compare the VPN with').not.toBeNull();
    expect(vpnExit(), "gluetun's exit IP is the NAS's own: traffic is not going through the VPN").not.toBe(nas);
  });

  // Each of these must exit through the tunnel. One that exits anywhere else
  // has left gluetun's namespace (or was never in it) and is leaking; one
  // with no egress at all is on a dead namespace (resilience.spec.ts).
  for (const service of GLUETUN_NAMESPACE_SERVICES) {
    test(`${service} exits through gluetun`, () => {
      requireStackReachable(test.skip);
      const exit = vpnExit();
      const ip = egressOf(service);
      expect(ip, `${service} has no egress; it may be on a gluetun namespace that no longer exists`).not.toBeNull();
      expect(ip, `${service} leaks: it exits from ${ip}, not gluetun's ${exit}`).toBe(exit);
    });
  }

  // Sonarr and Radarr moved to the bridge (docs/MIGRATION-arr-off-vpn.md) so a
  // VPN reconnect no longer cuts them off from Seerr and Bazarr. Exiting via
  // the VPN means that move was undone, and they are back to breaking on
  // every reconnect.
  for (const service of ['sonarr', 'radarr']) {
    test(`${service} is off the VPN`, () => {
      requireStackReachable(test.skip);
      const exit = vpnExit();
      const ip = egressOf(service);
      expect(ip, `${service} has no egress at all`).not.toBeNull();
      expect(ip, `${service} exits through gluetun; it belongs on the arr-stack bridge`).not.toBe(exit);
    });
  }

  // The killswitch: with gluetun stopped, qBittorrent must lose its route out,
  // not fall back to the NAS's connection. Stops the live gluetun, which cuts
  // every download, so it runs only on request. Afterwards gluetun is started
  // again and its dependents restarted onto its new namespace, as
  // docs/TROUBLESHOOTING.md prescribes after a gluetun restart.
  test('killswitch — qBittorrent has no egress while gluetun is stopped', async () => {
    test.skip(
      process.env.ALLOW_DISRUPTIVE_TESTS !== '1',
      'stops the live gluetun and interrupts downloads; set ALLOW_DISRUPTIVE_TESTS=1 to run it',
    );
    requireStackReachable(test.skip);
    test.setTimeout(8 * 60_000);

    const nas = nasEgress();
    vpnExit();

    docker(['stop', 'gluetun'], 90_000);
    try {
      let leaked: string | null;
      try {
        leaked = egressOf('qbittorrent');
      } catch (err) {
        // Only a stopped qBittorrent explains a failed exec; anything else
        // leaves the question unanswered, and that is not a pass.
        const running = docker(['inspect', '--format', '{{.State.Running}}', 'qbittorrent']).trim();
        if (running === 'true') throw err;
        leaked = null;
      }
      expect(
        leaked,
        leaked === nas
          ? "qBittorrent fell back to the NAS's own connection with gluetun stopped"
          : `qBittorrent still reached the internet (as ${leaked}) with gluetun stopped`,
      ).toBeNull();
    } finally {
      docker(['start', 'gluetun'], 90_000);
      const deadline = Date.now() + 4 * 60_000;
      let health = '';
      while (Date.now() < deadline) {
        health = docker(['inspect', '--format', '{{.State.Health.Status}}', 'gluetun']).trim();
        if (health === 'healthy') break;
        await new Promise((r) => setTimeout(r, 5_000));
      }
      expect(health, 'gluetun did not come back healthy after the killswitch test; check the stack now').toBe('healthy');
      // The dependents are still on the namespace gluetun had before it stopped.
      docker(['restart', ...GLUETUN_NAMESPACE_SERVICES], 3 * 60_000);
    }

    gluetunIp = undefined; // a reconnect can land on a different server
    expect(egressOf('qbittorrent'), 'qBittorrent did not recover its VPN egress after gluetun restarted').toBe(vpnExit());
  });
});
