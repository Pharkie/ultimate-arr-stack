import { defineConfig } from '@playwright/test';
import * as dotenv from 'dotenv';
import * as path from 'path';

dotenv.config({ path: path.resolve(__dirname, '../../.env.e2e') });

export default defineConfig({
  testDir: '.',
  timeout: 30_000,
  retries: 0,
  workers: 1,
  reporter: [
    ['list'],
    ['./executed-floor-reporter.ts', { floor: 30 }],
  ],
  // A committed test.only would silently shrink the suite to that one test, and a
  // green "1 passed" is exactly the failure mode the floor reporter exists for.
  forbidOnly: true,
  use: {
    headless: true,
    ignoreHTTPSErrors: true,
    screenshot: 'off',
    viewport: { width: 1920, height: 1080 },
  },
  projects: [
    {
      name: 'chromium',
      use: { browserName: 'chromium' },
    },
  ],
});
