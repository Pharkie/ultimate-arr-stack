import { test, expect } from '@playwright/test';
import { url, bridgeUrl, HOST, DOCKER_AVAILABLE } from './helpers';

// The operations group: monitoring, dashboards, and the Docker API proxy.
//
// These had no end-to-end coverage of any kind. The four services here are the
// ones that are actually reachable over the bridge network from inside this
// container -- measured 2026-09-11, not assumed: diun, gluetun-rotator and
// gluetun-recover listen on nothing but Docker's own DNS resolver, configarr is
// a one-shot job that exits 0 by design, and beszel-agent, deunhealth,
// dnscrypt-proxy and vpn-socks5 ship no shell, so there is no surface to test
// from here at all. Their coverage is the compose-level checks in the bats
// suite, and saying so is better than a test that could not fail.
//
// Why these matter despite being "only" the ops group: nothing else in either
// suite notices when they stop answering. deunhealth restarts unhealthy
// containers, gluetun-recover is what puts tunneled containers back on a live
// VPN namespace, diun reports image updates, and the socket proxy is the only
// thing standing between those tools and the raw Docker socket.

test.describe('Operations services', () => {
  test.skip(!DOCKER_AVAILABLE, 'needs Docker socket access to resolve bridge IPs (run on the NAS)');

  test('uptime-kuma answers on its published port', async ({ request }) => {
    // The only one of the four with a host port, so this also covers the
    // binding itself and not just the process.
    const res = await request.get(`http://${HOST}:3001/`, { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.text();
    expect(body).toContain('<html');
  });

  test('uptime-kuma API answers, so the UI has a backend', async ({ request }) => {
    // The page is a static shell; this is the call it makes on load. A UI that
    // serves HTML while its API is dead looks identical in a screenshot.
    const res = await request.get(`http://${HOST}:3001/api/entry-page`, { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body).toHaveProperty('type');
  });

  test('beszel hub reports its API healthy', async ({ request }) => {
    const res = await request.get(bridgeUrl('beszel', 8090, '/api/health'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toContain('healthy');
  });

  test('beszel hub serves its UI', async ({ request }) => {
    const res = await request.get(bridgeUrl('beszel', 8090, '/'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
  });

  test('duc serves its web UI over the bridge', async ({ request }) => {
    // duc.lan is asserted through Traefik in networking.spec.ts, but that test
    // stops at the 401 gate and never reaches this backend.
    const res = await request.get(bridgeUrl('duc', 80, '/'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.text();
    expect(body).toContain('duc');
  });
});

// The socket proxy is a security boundary, so it gets assertions in both
// directions: what it must allow, and what it must refuse. A test that only
// checked reachability would pass just as well against a proxy that had been
// started with everything enabled.
test.describe('Docker socket proxy', () => {
  test.skip(!DOCKER_AVAILABLE, 'needs Docker socket access to resolve the bridge IP (run on the NAS)');

  const proxy = (path: string) => bridgeUrl('docker-socket-proxy', 2375, path);

  test('it answers, and forwards the Docker version', async ({ request }) => {
    const res = await request.get(proxy('/version'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.Version).toBeTruthy();
  });

  test('it allows the read surfaces its consumers need', async ({ request }) => {
    // traefik's docker provider needs container and network listings, diun
    // needs image info, gluetun-recover watches events. Losing any of these
    // breaks a consumer silently, so each is asserted rather than assumed from
    // the env block.
    for (const path of ['/containers/json', '/networks', '/images/json', '/info']) {
      const res = await request.get(proxy(path), { timeout: 10_000 });
      expect(res.ok(), `GET ${path} should be allowed`).toBeTruthy();
    }
  });

  test('it refuses the read surfaces nobody asked for', async ({ request }) => {
    // These are refusals by the proxy's own policy: 403 comes back without the
    // request reaching the daemon, which is the observable difference from a
    // 404 the daemon would have produced. Measured 2026-09-11.
    for (const path of ['/volumes', '/secrets']) {
      const res = await request.get(proxy(path), { timeout: 10_000 });
      expect(res.status(), `GET ${path} must be refused by policy`).toBe(403);
    }
  });

  test('EXEC=0 does not block the exec flow, and this records that', async ({ request }) => {
    // A negative result, kept as a test because the assumption it corrects is
    // the kind that gets written into a comment and believed.
    //
    // docker-compose.utilities.yml sets EXEC=0, which reads like "no exec
    // through this proxy". It is not. EXEC gates the GET endpoints only
    // (`/exec/{id}/json`, `/exec/{id}/start`), while creating an exec instance
    // is POST /containers/{id}/exec, and POST is enabled wholesale for
    // gluetun-recover's `docker restart`. Measured against the live proxy: a
    // POST with a well-formed body returns 201 with an exec id, so the flow
    // cannot be completed through this proxy only because starting an exec is
    // POST /exec/{id}/start and that one IS refused.
    //
    // What this test pins is the reachable half: instance creation succeeds.
    // The marker `PROXY-EXEC-REACHABLE` in the failure message is deliberate --
    // if the proxy is ever replaced by socket mounts (the fix), this test fails
    // loudly with a message that says so, instead of silently passing because
    // the endpoint stopped existing.
    const container = (await (await request.get(proxy('/containers/json'), { timeout: 10_000 })).json())[0];
    expect(container, 'proxy returned no containers to name').toBeTruthy();
    const name = (container.Names?.[0] ?? '').replace(/^\//, '');
    expect(name).toBeTruthy();

    const res = await request.post(proxy(`/containers/${name}/exec`), {
      timeout: 10_000,
      failOnStatusCode: false,
      data: { AttachStdout: true, Cmd: ['/bin/true'] },
    });
    if (res.status() === 403) {
      throw new Error(
        'PROXY-EXEC-REACHABLE: exec creation is now refused. That is an improvement: ' +
          'update this test to assert the refusal, and delete the EXEC=0 caveat in docs/QUALITY-CONTROL-MAP.md.',
      );
    }
    expect(res.status(), 'exec creation is forwarded (see the comment above)').toBe(201);
    const body = await res.json();
    expect(body.Id, 'the daemon returned an exec instance id').toBeTruthy();
  });

  test('it permits container restart, which is why POST is enabled at all', async ({ request }) => {
    // The documented reason POST=1 is set: gluetun-recover's `docker restart`
    // after a VPN reconnect. Asserted against a name that does not exist, so
    // the assertion is about the proxy's method policy rather than about any
    // container: a 404 from the daemon means the request was forwarded, a 403
    // would mean it was blocked and gluetun-recover is broken.
    //
    // The counterpart: this same permission is what makes the proxy a
    // stop/kill/delete surface for anything on arr-core, which is why the
    // consumers that need it are named in docker-compose.utilities.yml's
    // comment rather than left implicit.
    const res = await request.post(proxy('/containers/playwright-nonexistent-probe/restart'), {
      timeout: 10_000,
      failOnStatusCode: false,
    });
    expect(res.status(), 'restart must be forwarded, not refused by policy').not.toBe(403);
  });
});
