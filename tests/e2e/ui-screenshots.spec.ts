import { test, expect } from '@playwright/test';
import { HOST, url, screenshotPath, addHeaderToAllRequests } from './helpers';

test.describe('UI screenshots', () => {
  test('Jellyfin — login and screenshot home', async ({ page, context }) => {
    // Why this test is written the way it is.
    //
    // Its job is to prove a human can log in and that the library then renders,
    // and to leave a screenshot behind for the README. It ran for months at
    // ~28s and then timed out at 60s on 2026-09-11 with no change to the stack,
    // which is the signature of a test whose budget is a guess rather than a
    // sum. Three things made it one:
    //
    //   1. `waitForLoadState('networkidle')`, three times. Jellyfin's web client
    //      holds a websocket open and keeps fetching thumbnails, so "no request
    //      for 500ms" is not a state this page reliably reaches. When it does
    //      not, the wait does not fail -- it burns the remaining test budget,
    //      and the failure surfaces as "Test timeout of 60000ms exceeded" with
    //      no indication of which line.
    //   2. Up to 8s of waiting per unresolved image, summed over every image on
    //      a full-page screenshot of a media library. One slow poster grid and
    //      the loop alone could exceed the budget.
    //   3. Fixed sleeps (3s + 1s + a 200ms-per-step vertical scroll) that were
    //      generous when written and are pure cost now.
    //
    // So: wait for named states instead of for quiet, bound every wait, and set
    // a budget that matches the real work. The screenshot is still the
    // assertion that matters -- a login that lands on an error page renders no
    // carousels, and that is checked before the shot.
    test.setTimeout(180_000);

    const username = process.env.JELLYFIN_USERNAME;
    const password = process.env.JELLYFIN_PASSWORD;
    test.skip(!username || !password, 'JELLYFIN_USERNAME / JELLYFIN_PASSWORD not set');

    // Bounded and non-fatal: a page that never goes quiet is not a failure, it
    // is a reason to stop waiting. `catch` because the timeout is expected.
    const settle = (ms = 5_000) =>
      page.waitForLoadState('networkidle', { timeout: ms }).catch(() => undefined);

    await page.goto(url('jellyfin'), { waitUntil: 'domcontentloaded', timeout: 30_000 });
    await settle();

    // Click "Manual Login" if the user selection screen appears
    const manualLogin = page.getByText('Manual Login');
    if (await manualLogin.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await manualLogin.click();
      await settle();
    }

    // Fill login form when one is present. If it is not, the client either
    // remembered a session or runs with auth disabled -- both fine, and both
    // caught by the URL assertion below.
    const usernameInput = page.locator('input[id="txtManualName"], input[name="username"], input[placeholder*="ser"]').first();
    const passwordInput = page.locator('input[id="txtManualPassword"], input[type="password"]').first();

    if (await usernameInput.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await usernameInput.fill(username!);
      await passwordInput.fill(password!);
      await page.locator('button[type="submit"], button:has-text("Sign in")').first().click();
      await page.waitForFunction(() => !window.location.hash.includes('login'), { timeout: 20_000 });
      await settle();
    }

    // Verify we're NOT on a login page
    expect(page.url()).not.toContain('login');

    // The real proof that the library rendered, rather than a sleep followed by
    // a screenshot of whatever was there.
    //
    // `#indexPage` is the home screen's own wrapper: it exists as soon as the
    // client has authenticated and is what the carousels are built into. The
    // first attempt at this asserted `.itemsContainer` instead, because that is
    // the class the scroll step below loops over -- but `.first()` matched
    // `<div id="divUsers" class="itemsContainer ...">`, the user-selection list
    // on the login screen, which is still in the DOM and hidden once you are
    // through. The test then failed on a page that had loaded perfectly, with
    // "locator resolved to ... unexpected value hidden" and no hint that the
    // selector was the problem.
    await expect(page.locator('#indexPage')).toBeVisible({ timeout: 30_000 });

    // Remove lazy loading BEFORE scrolling so images load immediately when visible
    await page.evaluate(() => {
      document.querySelectorAll('img[loading="lazy"]').forEach(img => {
        (img as HTMLImageElement).loading = 'eager';
      });
    });

    // Scroll vertically through the page, and also scroll each horizontal carousel
    await page.evaluate(async () => {
      const delay = (ms: number) => new Promise(r => setTimeout(r, ms));

      // Vertical scroll to trigger section rendering
      const step = Math.max(200, window.innerHeight / 2);
      for (let y = 0; y < document.body.scrollHeight; y += step) {
        window.scrollTo(0, y);
        await delay(120);
      }
      window.scrollTo(0, document.body.scrollHeight);
      await delay(300);

      // Scroll each horizontal carousel to the end and back
      const scrollers = document.querySelectorAll('.itemsContainer, .scrollSlider, [class*="scroller"]');
      for (const scroller of scrollers) {
        if (scroller.scrollWidth > scroller.clientWidth) {
          scroller.scrollLeft = scroller.scrollWidth;
          await delay(300);
          scroller.scrollLeft = 0;
          await delay(120);
        }
      }
    });

    // Nudge images that are not loaded yet, then wait for the whole set against
    // ONE deadline instead of one timeout per image. The screenshot is taken
    // whatever the result: a poster that did not load is worth a slightly
    // incomplete screenshot, not a failed run.
    await page.evaluate(async () => {
      document.querySelectorAll('img').forEach(img => {
        if (!img.complete || img.naturalWidth === 0) {
          const src = img.src;
          img.src = '';
          img.src = src;
        }
      });
      const pending = Array.from(document.querySelectorAll('img'))
        .filter(img => img.src && !(img.complete && img.naturalWidth > 0));
      const done = Promise.all(pending.map(img => new Promise<void>(resolve => {
        img.addEventListener('load', () => resolve(), { once: true });
        img.addEventListener('error', () => resolve(), { once: true });
      })));
      await Promise.race([done, new Promise<void>(r => setTimeout(r, 20_000))]);
    });

    // Hide blurhash canvas overlays so actual loaded images show through
    await page.evaluate(() => {
      document.querySelectorAll('canvas').forEach(c => {
        (c as HTMLElement).style.opacity = '0';
      });
    });

    // Scroll back to top for screenshot
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(500);

    await page.screenshot({ path: screenshotPath('jellyfin'), fullPage: true });
  });

  test('Sonarr — screenshot dashboard', async ({ page }) => {
    // AuthenticationMethod may be None (no login page) or Forms (credentials required).
    // Handle both so this test keeps working if auth is enabled later.
    const username = process.env.SONARR_USERNAME;
    const password = process.env.SONARR_PASSWORD;

    await page.goto(url('sonarr', '/'));
    await page.waitForLoadState('networkidle');

    if (page.url().includes('login')) {
      test.skip(!username || !password, 'Sonarr requires login but SONARR_USERNAME / SONARR_PASSWORD not set');
      await page.fill('input[name="username"], input[id="username"]', username!);
      await page.fill('input[name="password"], input[id="password"]', password!);
      await page.click('button[type="submit"]');
      await page.waitForLoadState('networkidle');
    }

    expect(page.url()).not.toContain('login');
    await expect(page.locator('[class*="series"], [class*="Series"], nav').first()).toBeVisible({ timeout: 10_000 });
    await page.screenshot({ path: screenshotPath('sonarr'), fullPage: true });
  });

  test('Radarr — screenshot dashboard', async ({ page }) => {
    // AuthenticationMethod may be None (no login page) or Forms (credentials required).
    // Handle both so this test keeps working if auth is enabled later.
    const username = process.env.RADARR_USERNAME;
    const password = process.env.RADARR_PASSWORD;

    await page.goto(url('radarr', '/'));
    await page.waitForLoadState('networkidle');

    if (page.url().includes('login')) {
      test.skip(!username || !password, 'Radarr requires login but RADARR_USERNAME / RADARR_PASSWORD not set');
      await page.fill('input[name="username"], input[id="username"]', username!);
      await page.fill('input[name="password"], input[id="password"]', password!);
      await page.click('button[type="submit"]');
      await page.waitForLoadState('networkidle');
    }

    expect(page.url()).not.toContain('login');
    await expect(page.locator('[class*="movie"], [class*="Movie"], nav').first()).toBeVisible({ timeout: 10_000 });
    await page.screenshot({ path: screenshotPath('radarr'), fullPage: true });
  });

  test('Prowlarr — login and screenshot dashboard', async ({ page }) => {
    const username = process.env.PROWLARR_USERNAME;
    const password = process.env.PROWLARR_PASSWORD;
    test.skip(!username || !password, 'PROWLARR_USERNAME / PROWLARR_PASSWORD not set');

    await page.goto(url('prowlarr', '/login'));
    await page.waitForLoadState('networkidle');
    await page.fill('input[name="username"], input[id="username"]', username!);
    await page.fill('input[name="password"], input[id="password"]', password!);
    await page.click('button[type="submit"]');
    await page.waitForURL(/.*(?<!\/login)$/, { timeout: 15000 });
    await page.waitForLoadState('domcontentloaded');

    expect(page.url()).not.toContain('login');
    await page.screenshot({ path: screenshotPath('prowlarr'), fullPage: true });
  });

  test('qBittorrent — login and screenshot', async ({ page }) => {
    const username = process.env.QBIT_USERNAME;
    const password = process.env.QBIT_PASSWORD;
    test.skip(!username || !password, 'QBIT_USERNAME / QBIT_PASSWORD not set');

    // Authenticate via API — cookie is set automatically
    const loginRes = await page.request.post(url('qbittorrent', '/api/v2/auth/login'), {
      form: { username, password },
    });
    expect(loginRes.ok()).toBeTruthy();

    // Transfer cookies from API context to browser context
    const cookies = (await loginRes.headersArray())
      .filter((h) => h.name.toLowerCase() === 'set-cookie')
      .map((h) => {
        const [nameVal] = h.value.split(';');
        const [name, ...rest] = nameVal.split('=');
        return {
          name: name.trim(),
          value: rest.join('=').trim(),
          domain: HOST,
          path: '/',
        };
      });
    await page.context().addCookies(cookies);

    await page.goto(url('qbittorrent'));
    await page.waitForLoadState('networkidle');

    // Verify we see VueTorrent (not a login page)
    await expect(page.getByText('TORRENTS').or(page.getByText('VueTorrent')).first()).toBeVisible({ timeout: 10_000 });
    await page.screenshot({ path: screenshotPath('qbittorrent'), fullPage: true });
  });

  test('SABnzbd — screenshot dashboard', async ({ page }) => {
    const apiKey = process.env.SABNZBD_API_KEY;
    test.skip(!apiKey, 'SABNZBD_API_KEY not set');

    await page.goto(url('sabnzbd', `/?apikey=${apiKey}`));
    await page.waitForLoadState('networkidle');

    // Verify we see the SABnzbd interface (queue heading or history)
    await expect(page.locator('h2:has-text("Queue"), .main-header, .sabnzbd')).toBeVisible({ timeout: 10_000 });
    await page.screenshot({ path: screenshotPath('sabnzbd'), fullPage: true });
  });

  test('Seerr — login and screenshot discover page', async ({ page }) => {
    const username = process.env.JELLYFIN_USERNAME;
    const password = process.env.JELLYFIN_PASSWORD;
    test.skip(!username || !password, 'JELLYFIN_USERNAME / JELLYFIN_PASSWORD not set (Seerr uses Jellyfin SSO)');

    // Authenticate via Seerr's Jellyfin auth API
    const authRes = await page.request.post(url('seerr', '/api/v1/auth/jellyfin'), {
      data: { username, password },
    });
    expect(authRes.ok()).toBeTruthy();

    // Transfer session cookies to browser context
    const cookies = (await authRes.headersArray())
      .filter((h) => h.name.toLowerCase() === 'set-cookie')
      .map((h) => {
        const [nameVal] = h.value.split(';');
        const [name, ...rest] = nameVal.split('=');
        return {
          name: name.trim(),
          value: rest.join('=').trim(),
          domain: HOST,
          path: '/',
        };
      });
    if (cookies.length > 0) {
      await page.context().addCookies(cookies);
    }

    await page.goto(url('seerr', '/'));
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(2_000);

    expect(page.url()).not.toContain('login');
    await page.screenshot({ path: screenshotPath('seerr'), fullPage: true });
  });

  test('Bazarr — screenshot dashboard', async ({ page }) => {
    const apiKey = process.env.BAZARR_API_KEY;
    test.skip(!apiKey, 'BAZARR_API_KEY not set');

    // Bazarr uses X-API-KEY header for authentication
    await addHeaderToAllRequests(page, 'x-api-key', apiKey!);
    await page.goto(url('bazarr', '/'));
    await page.waitForLoadState('domcontentloaded');

    // Give the SPA time to render
    await page.waitForTimeout(3_000);

    const pageUrl = page.url();
    expect(pageUrl).not.toContain('login');
    await page.screenshot({ path: screenshotPath('bazarr'), fullPage: true });
  });

  test('Pi-hole — login and screenshot admin', async ({ page }) => {
    const password = process.env.PIHOLE_PASSWORD;
    test.skip(!password, 'PIHOLE_PASSWORD not set');

    // Pi-hole v6: authenticate via API to get SID cookie
    const loginRes = await page.request.post(url('pihole', '/api/auth'), {
      data: { password: password },
    });

    if (loginRes.ok()) {
      const body = await loginRes.json();
      if (body.session?.sid) {
        await page.context().addCookies([{
          name: 'sid',
          value: body.session.sid,
          domain: HOST,
          path: '/',
        }]);
      }
    }

    await page.goto(url('pihole', '/admin/'));
    await page.waitForLoadState('networkidle');

    // If API auth didn't work, fall back to form login
    const loginForm = page.locator('input[type="password"]');
    if (await loginForm.isVisible({ timeout: 2_000 }).catch(() => false)) {
      await loginForm.fill(password!);
      await page.locator('button:has-text("Log in"), button[type="submit"]').first().click();
      await page.waitForLoadState('networkidle');
    }

    // Verify we see the dashboard (Pi-hole shows query stats)
    await expect(
      page.locator('#queries-over-time, canvas, .card, [class*="dashboard"]').first()
    ).toBeVisible({ timeout: 10_000 });
    await page.screenshot({ path: screenshotPath('pihole'), fullPage: true });
  });
});
