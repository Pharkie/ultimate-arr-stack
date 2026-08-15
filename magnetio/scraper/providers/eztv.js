/**
 * EZTV provider -- uses the official EZTV JSON API.
 * Supports series only (no movies).
 */
import { get } from '../lib/httpClient.js';
import { parseTitle } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.eztv;

export const id   = 'eztv';
export const name = 'EZTV';

export async function scrape(meta) {
  if (meta.type !== 'series') return [];

  const imdbNumeric = meta.imdbId?.replace('tt', '');
  if (!imdbNumeric) return [];

  try {
    let page = 1;
    const results = [];

    while (true) {
      const { data } = await tryDomains(DOMAINS, async (base) => {
        return get(`${base}/api/get-torrents`, {
          limiterKey: 'eztv',
          responseType: 'json',
          params: { imdb_id: imdbNumeric, limit: 100, page },
        });
      }, 'EZTV');

      const torrents = data?.torrents ?? [];
      results.push(...torrents.map(normalise));

      if (torrents.length < 100) break;
      page++;
      if (page > 5) break;
    }

    return filterBySeason(results, meta.season, meta.episode);
  } catch (err) {
    logger.warn(`[EZTV] ${err.message}`);
    return [];
  }
}

function normalise(t) {
  const parsed = parseTitle(t.title);
  return {
    infoHash:  t.hash?.toLowerCase(),
    title:     t.title,
    seeders:   t.seeds ?? 0,
    leechers:  t.peers ?? 0,
    size:      parseInt(t.size_bytes ?? '0', 10),
    provider:  'EZTV',
    imdbId:    t.imdb_id ? `tt${t.imdb_id}` : null,
    season:    t.season  ? parseInt(t.season, 10)  : null,
    episode:   t.episode ? parseInt(t.episode, 10) : null,
    ...parsed,
  };
}

function filterBySeason(torrents, season, episode) {
  if (season == null) return torrents;
  return torrents.filter(t => {
    if (t.season !== season) return false;
    if (episode != null && t.episode !== episode) return false;
    return true;
  });
}
