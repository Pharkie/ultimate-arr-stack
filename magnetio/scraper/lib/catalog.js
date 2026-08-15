import { get } from './httpClient.js';
import { logger } from './logger.js';

const CINEMETA_BASE = 'https://v3-cinemeta.strem.io';

export async function fetchPopular(type, limit = 50) {
  try {
    const { data } = await get(`${CINEMETA_BASE}/catalog/${type}/top.json`, {
      limiterKey: 'cinemeta',
      responseType: 'json',
      timeout: 15000,
    });

    const metas = data?.metas ?? [];

    return metas.slice(0, limit).map(m => ({
      // Series prewarm targets S01E01 only; other episodes get scraped on demand
      id: type === 'series' ? `${m.imdb_id}:1:1` : m.imdb_id,
      name: m.name,
      type,
    }));
  } catch (err) {
    logger.error(`[Catalog] Failed to fetch popular ${type}: ${err.message}`);
    return [];
  }
}
