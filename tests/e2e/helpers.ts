import { test, expect, type APIRequestContext, type Page } from '@playwright/test';
import { spawnSync } from 'child_process';
import * as path from 'path';

// Shared by every spec: where the NAS is, how to reach each service's API and
// how to run docker commands against the live stack.

// ─── Where the stack is ─────────────────────────────────────────────────────

// From .env.e2e (loaded by playwright.config.ts). Empty when that file is
// missing, which a git worktree does not inherit: url() and the docker
// helpers then fail with a message saying so rather than aiming at nothing.
export const HOST = process.env.NAS_HOST ?? '';

// Host ports, as published in docker-compose.arr-stack.yml. SABnzbd's is 8082
// on the host (8080 inside gluetun's namespace).
export const PORTS = {
  jellyfin: 8096,
  seerr: 5055,
  sonarr: 8989,
  radarr: 7878,
  prowlarr: 9696,
  bazarr: 6767,
  qbittorrent: 8085,
  sabnzbd: 8082,
  pihole: 8081,
} as const;

export type Service = keyof typeof PORTS;

export function url(service: Service, urlPath = '/'): string {
  if (!HOST) {
    throw new Error('NAS_HOST is not set. It comes from .env.e2e, which a git worktree does not have: copy it from the main checkout.');
  }
  return `http://${HOST}:${PORTS[service]}${urlPath}`;
}

export function screenshotPath(name: string): string {
  return path.join(__dirname, 'screenshots', `${name}.png`);
}

// For apps that authenticate every request by header rather than by cookie
// (Bazarr's X-API-KEY). Added only to requests for the NAS, so the key is
// never sent to a third-party host the page happens to load from.
export async function addHeaderToAllRequests(page: Page, name: string, value: string): Promise<void> {
  await page.route('**/*', (route) => {
    const request = route.request();
    if (new URL(request.url()).hostname !== HOST) return route.continue();
    return route.continue({ headers: { ...request.headers(), [name]: value } });
  });
}

// ─── Services in gluetun's network namespace ────────────────────────────────

// Every service the compose files bind into gluetun's namespace
// (`network_mode: "service:gluetun"` or `"container:gluetun"`), by container
// name. The VPN egress and namespace checks iterate over this, so a service
// missing here is one nobody checks for a leak. Keep it on one line:
// tests/vpn-zombies.bats fails unless it names exactly those services.
export const GLUETUN_NAMESPACE_SERVICES = ['qbittorrent', 'sabnzbd', 'prowlarr', 'flaresolverr'] as const;

// ─── Running commands on the NAS ────────────────────────────────────────────

// NAS_SSH (an ssh target such as a ~/.ssh/config alias) wins over NAS_HOST.
// A localhost target means the suite is running on the NAS itself, so
// commands run here without ssh.
const LOCAL_TARGETS = new Set(['localhost', '127.0.0.1', '::1']);

function nasTarget(): string {
  const target = process.env.NAS_SSH || HOST;
  if (!target) {
    throw new Error('Neither NAS_SSH nor NAS_HOST is set, so there is no NAS to run docker against. Both come from .env.e2e.');
  }
  return target;
}

// Single-quote for the remote shell: ssh joins its arguments into one string,
// so an unquoted `(` or `*.exe` would be interpreted on the NAS.
function shellQuote(arg: string): string {
  return `'${arg.replace(/'/g, `'\\''`)}'`;
}

// Runs argv on the NAS host and returns stdout; throws on a non-zero exit.
// BatchMode because the suite must never sit at a password prompt: key-based
// auth works, or the command fails.
export function runOnNas(argv: string[], timeoutMs = 30_000): string {
  const target = nasTarget();
  const local = LOCAL_TARGETS.has(target);
  const [cmd, args] = local
    ? [argv[0], argv.slice(1)]
    : ['ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1', target, argv.map(shellQuote).join(' ')]];
  const where = local ? 'locally' : `on ${target}`;

  const result = spawnSync(cmd, args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 });
  if (result.error) {
    throw new Error(`\`${argv.join(' ')}\` could not run ${where}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    // stderr only: stdout may be a config file holding keys.
    throw new Error(`\`${argv.join(' ')}\` failed ${where} (exit ${result.status}): ${result.stderr.trim()}`);
  }
  return result.stdout;
}

export function docker(args: string[], timeoutMs = 30_000): string {
  return runOnNas(['docker', ...args], timeoutMs);
}

export function dockerExec(container: string, args: string[], timeoutMs = 30_000): string {
  return docker(['exec', container, ...args], timeoutMs);
}

// ─── Fail, don't skip, when the stack is out of reach ───────────────────────

let reachability: { ok: true } | { ok: false; reason: string } | undefined;

// Call first in any test that needs docker on the NAS, passing test.skip.
// An unreachable stack FAILS the test: a VPN leak check that did not run is an
// unverified result, and reporting it as skipped would let the suite exit 0.
// ALLOW_UNVERIFIED_VPN=1 is the explicit, visible opt-out for running without
// a NAS; only then does this skip.
export function requireStackReachable(skip: typeof test.skip): void {
  if (!reachability) {
    try {
      docker(['version', '--format', '{{.Server.Version}}'], 20_000);
      reachability = { ok: true };
    } catch (err) {
      reachability = { ok: false, reason: (err as Error).message };
    }
  }
  if (reachability.ok) return;

  if (process.env.ALLOW_UNVERIFIED_VPN === '1') {
    skip(true, `ALLOW_UNVERIFIED_VPN=1 and the stack is unreachable (${reachability.reason})`);
    return;
  }
  throw new Error(
    `Cannot reach docker on the NAS, so this check cannot run: ${reachability.reason}\n` +
      'Set NAS_HOST (and NAS_SSH if ssh needs a different target) in .env.e2e, with key-based ssh working. ' +
      'To run without a NAS, set ALLOW_UNVERIFIED_VPN=1: these tests then skip, and say why.',
  );
}

// ─── Seerr's own API key ────────────────────────────────────────────────────

// Seerr generates its API key on first start and keeps it in settings.json;
// it is not in .env.e2e. Reading it at test time means a reinstalled Seerr
// cannot leave the suite holding a stale key. Never log the file: it also
// holds the Sonarr and Radarr keys Seerr uses.
export function readSeerrApiKey(): string {
  const raw = dockerExec('seerr', ['cat', '/app/config/settings.json']);
  let key: unknown;
  try {
    key = JSON.parse(raw)?.main?.apiKey;
  } catch {
    throw new Error("Seerr's /app/config/settings.json is not valid JSON");
  }
  if (typeof key !== 'string' || key === '') {
    throw new Error("Seerr's settings.json has no main.apiKey. Has Seerr been through its setup wizard?");
  }
  return key;
}

// ─── Download clients ───────────────────────────────────────────────────────

type ProviderTestResult = {
  id: number;
  isValid: boolean;
  validationFailures: Array<{ propertyName?: string; errorMessage: string; isWarning?: boolean }>;
};

// Every enabled download client must pass the app's own connection test.
// testall answers 400 when any client fails, and silently leaves out a client
// whose settings don't validate, so results are matched to clients by id: a
// client with no result fails as untested instead of passing by omission.
// No enabled client at all fails too. Grabs then go nowhere, with no error.
export async function assertDownloadClientsHealthy(
  request: APIRequestContext,
  app: 'sonarr' | 'radarr' | 'prowlarr',
  apiKey: string,
): Promise<void> {
  const api = app === 'prowlarr' ? '/api/v1' : '/api/v3';
  const headers = { 'X-Api-Key': apiKey };

  const listRes = await request.get(url(app, `${api}/downloadclient`), { headers });
  expect(listRes.ok(), `${app}: could not list download clients (HTTP ${listRes.status()})`).toBeTruthy();
  const clients: Array<{ id: number; name: string; enable: boolean }> = (await listRes.json()).filter(
    (c: { enable: boolean }) => c.enable,
  );
  expect(clients.map((c) => c.name), `${app} has no enabled download client`).not.toEqual([]);

  const testRes = await request.post(url(app, `${api}/downloadclient/testall`), { headers, timeout: 60_000 });
  expect([200, 400], `${app}: download client testall answered HTTP ${testRes.status()}`).toContain(testRes.status());
  const results: ProviderTestResult[] = await testRes.json();

  const failures = clients.flatMap((client) => {
    const result = results.find((r) => r.id === client.id);
    if (!result) return [`${client.name}: not tested (its settings do not validate)`];
    if (result.isValid) return [];
    const reasons = result.validationFailures.filter((f) => !f.isWarning).map((f) => f.errorMessage);
    return [`${client.name}: ${reasons.join('; ') || 'failed with no reason given'}`];
  });
  expect(failures, `${app} download clients failing their own test`).toEqual([]);
}
