// Fails a FULL-SUITE run that executed almost nothing.
//
// Why this exists: 55 of the 58 collected tests in this suite call test.skip()
// when a gate is unmet (DOCKER_AVAILABLE, an API key, a credential,
// TRAEFIK_LAN_IP). Playwright exits 0 when tests skip, so an absent or rotted
// .env.e2e turns a 56-executed run into a 3-executed run that still reports
// success -- the same "a skip reads as a clean run" trap that
// tests/backup-volume-resolution.bats:398 and tests/toolkit/pytest.sh's exit 77
// exist to prevent everywhere else in this repo.
//
// Scope: single-spec runs (documented in README.md) collect 5-15 tests and are
// deliberately exempt; the floor only applies to runs that collected the whole
// suite. Override with E2E_EXECUTED_FLOOR to watch this guard fire.
import type { Reporter, TestCase, TestResult } from '@playwright/test/reporter';

const FULL_SUITE_MIN_COLLECTED = 50; // full suite collects 58; a single spec collects 5-15

class ExecutedFloorReporter implements Reporter {
  private executed = 0;
  private skipped = 0;
  private failed = 0;

  constructor(private readonly options: { floor?: number } = {}) {}

  onTestEnd(test: TestCase, result: TestResult): void {
    if (result.status === 'skipped') {
      this.skipped += 1;
      return;
    }
    this.executed += 1;
    if (result.status !== 'passed') this.failed += 1;
  }

  onEnd(): void {
    const total = this.executed + this.skipped;
    const floor = Number(process.env.E2E_EXECUTED_FLOOR ?? this.options.floor ?? 30);
    console.log(
      `\n[executed-floor] executed=${this.executed} skipped=${this.skipped} ` +
        `failed=${this.failed} collected=${total} floor=${floor}`,
    );
    if (total < FULL_SUITE_MIN_COLLECTED) {
      console.log('[executed-floor] partial run (single spec or -g filter) - floor not applied');
      return;
    }
    if (this.executed < floor) {
      const msg =
        `[executed-floor] only ${this.executed} of ${total} collected tests executed, ` +
        `below the floor of ${floor}. This is a configuration failure, not a pass: ` +
        `check that .env.e2e exists and sets NAS_HOST plus the per-service API keys and ` +
        `credentials (see .env.e2e.example), and that the stack is reachable.`;
      console.error(`\n${msg}`);
      process.exitCode = 1;
      throw new Error(msg);
    }
  }
}

export default ExecutedFloorReporter;
