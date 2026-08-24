//
// Shared fixtures for the end-to-end suite: service addressing, the VPN
// topology the tests assert against, and a docker channel that works whether
// the suite runs on the NAS or from a laptop.
//

import { execFileSync } from 'node:child_process';
import * as path from 'path';

// ─── Addressing ──────────────────────────────────────────────────────────────

export const HOST = process.env.NAS_HOST ?? 'localhost';
export const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

export function screenshotPath(name: string) {
  return path.join(SCREENSHOTS_DIR, `${name}.png`);
}

export const PORTS = {
  jellyfin: 8096,
  sonarr: 8989,
  radarr: 7878,
  prowlarr: 9696,
  qbittorrent: 8085,
  sabnzbd: 8082,
  seerr: 5055,
  bazarr: 6767,
  pihole: 8081,
} as const;

export function url(service: keyof typeof PORTS, pathStr = '') {
  return `http://${HOST}:${PORTS[service]}${pathStr}`;
}

// ─── VPN topology ────────────────────────────────────────────────────────────
//
// One definition, shared. Every service listed here carries
// network_mode: "service:gluetun" in docker-compose.arr-stack.yml; the bridge
// list is everything that deliberately does not, per
// docs/MIGRATION-arr-off-vpn.md. Keeping both here means a topology change is
// a one-line edit rather than a hunt through the specs.

export const TUNNELED_SERVICES = ['qbittorrent', 'prowlarr', 'sabnzbd', 'flaresolverr'] as const;
export const BRIDGE_SERVICES = ['sonarr', 'radarr'] as const;

// ─── UI auth helpers ─────────────────────────────────────────────────────────

/** Intercept all requests and add a custom header. Works for SPA auth bypass. */
export async function addHeaderToAllRequests(page: import('@playwright/test').Page, name: string, value: string) {
  await page.route('**/*', async (route) => {
    const headers = { ...route.request().headers(), [name]: value };
    await route.continue({ headers });
  });
}

// ─── Reaching the stack's containers ─────────────────────────────────────────
//
// Several tests need to run commands inside the stack's containers, which means
// talking to whichever docker daemon owns them. That is usually not the machine
// running the suite.
//
// Two channels, tried in order:
//
//   local  the daemon on this machine already has the stack
//   ssh    it does not, but a NAS we can log into does
//
// The local probe asks whether `gluetun` is inspectable rather than whether the
// docker CLI works. Those are different questions with different answers: a
// laptop running Docker Desktop replies happily to `docker version` while
// holding none of these containers, so a CLI-presence check reports success and
// every dependent test then dies on "No such container". Inspecting a container
// the stack actually owns answers the question being asked.

const SSH_TARGET = process.env.NAS_SSH ?? process.env.NAS_HOST ?? '';
const SSH_FLAGS = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10'];

/** Wrap for a remote POSIX shell — ssh hands the string to a shell to re-parse. */
function quoteForRemoteShell(word: string): string {
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

/** Does this machine's own docker daemon hold the stack? */
export const STACK_IS_LOCAL = ((): boolean => {
  try {
    execFileSync('docker', ['inspect', '--format', '{{.Id}}', 'gluetun'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

export type DockerTransport = 'local' | 'ssh' | 'none';

export const DOCKER_TRANSPORT: DockerTransport = ((): DockerTransport => {
  if (STACK_IS_LOCAL) return 'local';
  if (!SSH_TARGET) return 'none';
  try {
    const probe = `docker inspect --format ${quoteForRemoteShell('{{.Id}}')} gluetun`;
    execFileSync('ssh', [...SSH_FLAGS, SSH_TARGET, probe], { stdio: 'ignore', timeout: 20_000 });
    return 'ssh';
  } catch {
    return 'none';
  }
})();

export const STACK_IS_REACHABLE = DOCKER_TRANSPORT !== 'none';

export const STACK_UNREACHABLE_REASON = SSH_TARGET
  ? `the stack's containers could not be reached: no gluetun on this machine's docker, and ` +
    `the configured NAS did not answer an inspect over SSH either. Check the NAS is up and ` +
    `its SSH service is enabled, or run the suite on the NAS itself.`
  : `the stack's containers could not be reached: no gluetun on this machine's docker, and ` +
    `no NAS to fall back to — neither NAS_SSH nor NAS_HOST is set. Define one in .env.e2e ` +
    `(note that a git worktree will not have that file), or run the suite on the NAS itself.`;

// An unreachable stack fails these tests rather than skipping them.
//
// Skipping was tried and proved actively dangerous. When the NAS dropped its
// SSH service, a run reported "16 passed, 9 skipped" and exited 0 — with every
// leak check among the skipped. Both CI and a human read exit 0 as "the VPN is
// fine", when in truth nothing about the VPN had been examined at all.
//
// A check that did not execute has produced no evidence. Reporting it as
// success is the precise failure mode this file exists to detect, so it is not
// tolerated here either. Anyone who genuinely wants to run without a NAS says
// so out loud:
//
//     ALLOW_UNVERIFIED_VPN=1 npm run test:e2e
//
// which restores skipping — but as a visible decision in the command, not an
// accident of whichever machine happened to run it.

export const ALLOW_UNVERIFIED_VPN = process.env.ALLOW_UNVERIFIED_VPN === '1';

/**
 * Guard for any test that drives the stack's containers.
 *
 * Returns quietly when the stack is reachable. Skips only if the operator has
 * explicitly accepted an unverified VPN; otherwise throws, so the run ends red
 * instead of misleadingly green.
 */
export function requireStackReachable(skip: (condition: boolean, reason: string) => void): void {
  if (STACK_IS_REACHABLE) return;

  if (ALLOW_UNVERIFIED_VPN) {
    skip(true, `${STACK_UNREACHABLE_REASON} (skipped via ALLOW_UNVERIFIED_VPN=1)`);
    return;
  }

  throw new Error(
    `${STACK_UNREACHABLE_REASON}\n\n` +
    `This fails rather than skips deliberately. A leak check that never ran is ` +
    `an unverified result, and exiting 0 would present it as a verified one. ` +
    `Restore the connection, or accept the gap on purpose with ALLOW_UNVERIFIED_VPN=1.`,
  );
}

// ─── Docker commands ─────────────────────────────────────────────────────────

/** Issue a docker subcommand over whichever channel reaches the stack. */
function runDocker(argv: string[], timeoutMs: number): string {
  if (DOCKER_TRANSPORT === 'ssh') {
    const remoteCommand = ['docker', ...argv].map(quoteForRemoteShell).join(' ');
    // The extra margin covers ssh's own connection setup, which is not part of
    // the timeout the caller is reasoning about.
    return execFileSync('ssh', [...SSH_FLAGS, SSH_TARGET, remoteCommand], {
      encoding: 'utf8',
      timeout: timeoutMs + 5_000,
    }).trim();
  }
  return execFileSync('docker', argv, { encoding: 'utf8', timeout: timeoutMs }).trim();
}

export function dockerExec(container: string, cmd: string[], timeoutMs = 10_000): string {
  return runDocker(['exec', container, ...cmd], timeoutMs);
}

export function dockerInspect(container: string, format: string): string {
  return runDocker(['inspect', '--format', format, container], 10_000);
}

/** Stop/start, for the killswitch test. Kept separate so the destructive verbs are easy to grep. */
export function dockerLifecycle(action: 'stop' | 'start', container: string): void {
  runDocker([action, container], 30_000);
}

/**
 * The public IP a container's traffic comes out of, asked from inside it.
 *
 * Returns null whenever the lookup fails or times out. That is a real answer,
 * not an error: a container whose egress is being blocked by a working
 * killswitch is exactly a container that cannot reach an IP echo service.
 */
export function egressIp(container: string): string | null {
  // Image bases differ — gluetun's Alpine carries wget only, the LSIO images
  // carry curl — so pick inside the container instead of maintaining a map of
  // which is which. Detecting first rather than running curl and letting it
  // fail keeps "sh: curl: not found" off stderr; the runner echoes that for
  // every call, and output people learn to scroll past is worthless in a leak
  // detector.
  //
  // The /ip path matters: ifconfig.me returns a bare address to curl but its
  // full HTML page to wget, which sends no Accept header. That path is plain
  // text either way.
  const probe =
    'if command -v curl >/dev/null 2>&1; then ' +
    'curl -s --max-time 5 https://ifconfig.me/ip; ' +
    'else wget -qO- --timeout=5 https://ifconfig.me/ip; fi';

  try {
    return dockerExec(container, ['sh', '-c', probe], 15_000);
  } catch {
    return null;
  }
}
