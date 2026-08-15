import cron from 'node-cron';
import { runPrewarm } from './prewarm.js';
import { logger } from './logger.js';

const ENABLED  = (process.env.PREWARM_ENABLED ?? 'true') === 'true';
const SCHEDULE = process.env.PREWARM_SCHEDULE ?? '0 4 * * *';

export function startCronJobs() {
  if (!ENABLED) {
    logger.info('[Cron] Prewarm disabled (PREWARM_ENABLED=false)');
    return;
  }

  if (!cron.validate(SCHEDULE)) {
    logger.error(`[Cron] Invalid schedule: "${SCHEDULE}"`);
    return;
  }

  cron.schedule(SCHEDULE, async () => {
    try {
      await runPrewarm();
    } catch (err) {
      logger.error(`[Cron] Prewarm failed: ${err.message}`);
    }
  });

  logger.info(`[Cron] Prewarm scheduled: "${SCHEDULE}"`);
}
