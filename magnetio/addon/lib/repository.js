import axios from 'axios';
import { cacheWrap } from './cache.js';
import { logger } from './logger.js';

const SCRAPER_BASE_URL = process.env.SCRAPER_URL || 'http://localhost:8080';
const REQUEST_TIMEOUT  = 20_000;

function simpleHash(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) {
    h = ((h << 5) - h + str.charCodeAt(i)) | 0;
  }
  return Math.abs(h).toString(36);
}

/**
 * Fetch torrent stream records from the scraper back-end.
 *
 * The scraper is responsible for querying configured torrent providers and
 * returning a normalised list of torrent records.
 *
 * @param {'movie'|'series'|'anime'} type
 * @param {string}                   id     IMDb or Kitsu ID
 * @param {object}                   config Addon configuration
 * @returns {Promise<TorrentRecord[]>}
 */
export async function getStreams(type, id, config) {
  const providerKey = config?.providers?.length ? config.providers.join(',') : 'all';
  const torznabSuffix = config.torznabUrl
    ? `:tz-${simpleHash(config.torznabUrl + (config.torznabApiKey || ''))}`
    : '';
  const cacheKey = `streams:${type}:${id}:${providerKey}${torznabSuffix}`;

  return cacheWrap(cacheKey, async () => {
    const params = { providers: config.providers?.join(',') };
    if (config.torznabUrl) {
      params.torznabUrl = config.torznabUrl;
      params.torznabApiKey = config.torznabApiKey || '';
    }

    const fetchOnce = async () => {
      const { data } = await axios.get(`${SCRAPER_BASE_URL}/streams/${type}/${id}`, {
        timeout: REQUEST_TIMEOUT,
        params,
      });
      return Array.isArray(data.streams) ? data.streams : [];
    };

    try {
      const results = await fetchOnce();
      if (results.length === 0) {
        await new Promise(r => setTimeout(r, 1000));
        return fetchOnce();
      }
      return results;
    } catch (err) {
      logger.warn(`Repository fetch failed [${id}]: ${err.message}`);
      return [];
    }
  }, 3600);
}
