import pLimit from 'p-limit';
import { fetchPopular } from './catalog.js';
import { getMetadata } from './cinemeta.js';
import { scrapeAll } from '../providers/index.js';
import { cacheWrap, cacheHas } from './cache.js';
import { logger } from './logger.js';

const MOVIE_LIMIT  = parseInt(process.env.PREWARM_MOVIE_LIMIT ?? '50', 10);
const SERIES_LIMIT = parseInt(process.env.PREWARM_SERIES_LIMIT ?? '20', 10);
const CACHE_TTL    = parseInt(process.env.PREWARM_CACHE_TTL ?? '14400', 10);

let lastRun = null;
let running = false;

export function getPrewarmStatus() {
  return { running, lastRun };
}

export async function runPrewarm() {
  if (running) {
    logger.warn('[Prewarm] Already running, skipping');
    return null;
  }

  running = true;
  const start = Date.now();
  const stats = { processed: 0, cached: 0, scraped: 0, failed: 0 };

  try {
    logger.info('[Prewarm] Starting cache prewarm...');

    const [movies, series] = await Promise.all([
      fetchPopular('movie', MOVIE_LIMIT),
      fetchPopular('series', SERIES_LIMIT),
    ]);

    const titles = [...movies, ...series];
    logger.info(`[Prewarm] ${movies.length} movies + ${series.length} series = ${titles.length} titles`);

    const concurrency = pLimit(2);

    await Promise.allSettled(
      titles.map(item => concurrency(async () => {
        stats.processed++;
        try {
          await prewarmTitle(item, stats);
        } catch (err) {
          stats.failed++;
          logger.warn(`[Prewarm] Failed ${item.id}: ${err.message}`);
        }
      }))
    );

    const elapsed = ((Date.now() - start) / 1000).toFixed(1);
    lastRun = { ...stats, elapsed: `${elapsed}s`, timestamp: new Date().toISOString() };
    logger.info(`[Prewarm] Done in ${elapsed}s: ${JSON.stringify(stats)}`);
    return lastRun;
  } finally {
    running = false;
  }
}

async function prewarmTitle(item, stats) {
  const { type, id } = item;
  const cacheKey = `streams:${type}:${id}:all`;

  const alreadyCached = await cacheHas(cacheKey);
  if (alreadyCached) {
    stats.cached++;
    return;
  }

  const meta = await getMetadata(type, id);
  if (!meta) {
    stats.failed++;
    return;
  }

  const label = meta.year ? `"${meta.name}" (${meta.year})` : `"${meta.name}"`;
  logger.debug(`[Prewarm] Scraping ${label}`);

  const streams = await scrapeAll(type, meta);
  if (!streams.length) {
    stats.failed++;
    logger.debug(`[Prewarm] No streams found for ${id}, skipping cache write`);
    return;
  }
  await cacheWrap(cacheKey, () => streams, CACHE_TTL);
  stats.scraped++;
}
