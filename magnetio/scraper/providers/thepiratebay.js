/**
 * The Pirate Bay provider -- uses the apibay.org JSON API.
 */
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.thepiratebay;

export const id   = 'thepiratebay';
export const name = 'ThePirateBay';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);

    const { data } = await tryDomains(DOMAINS, async (base) => {
      return get(`${base}/q.php`, {
        limiterKey: 'thepiratebay',
        responseType: 'json',
        params: { q: query, cat: meta.type === 'movie' ? '207' : '205' },
      });
    }, 'TPB');

    if (!Array.isArray(data) || data[0]?.id === '0') return [];

    return data.map(t => normalise(t, meta));
  } catch (err) {
    logger.warn(`[TPB] ${err.message}`);
    return [];
  }
}

function normalise(t, meta) {
  const parsed = parseTitle(t.name);
  return {
    infoHash:  t.info_hash?.toLowerCase(),
    title:     t.name,
    seeders:   parseInt(t.seeders ?? '0', 10),
    leechers:  parseInt(t.leechers ?? '0', 10),
    size:      parseInt(t.size ?? '0', 10),
    provider:  'ThePirateBay',
    imdbId:    meta.imdbId,
    ...parsed,
  };
}
