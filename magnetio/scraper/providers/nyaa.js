/**
 * Nyaa provider — uses Nyaa.si RSS/JSON for anime torrents.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'https://nyaa.si';

export const id   = 'nyaa';
export const name = 'Nyaa';

export async function scrape(meta) {
  // Nyaa is anime-only
  if (meta.type !== 'series' && meta.type !== 'anime') return [];

  try {
    const query = buildSearchQuery(meta);

    // Nyaa exposes an Atom feed we can parse easily
    const { data } = await get(`${BASE}/?page=rss`, {
      limiterKey: 'nyaa',
      params: {
        q:   query,
        c:   '1_2', // category: Anime – English-translated
        f:   '0',
        s:   'seeders',
        o:   'desc',
      },
    });

    const $ = cheerio.load(data, { xmlMode: true });
    const results = [];

    $('item').each((_, item) => {
      const $item   = $(item);
      const title   = $item.find('title').text().trim();
      const magnet  = $item.find('link').text().trim() || $item.find('nyaa\\:infoHash').text().trim();
      const infoHash = $item.find('nyaa\\:infoHash').text().trim().toLowerCase()
        || extractInfoHash($item.find('link').text());

      if (!infoHash || !title) return;

      const seeders  = parseInt($item.find('nyaa\\:seeders').text().trim(), 10) || 0;
      const leechers = parseInt($item.find('nyaa\\:leechers').text().trim(), 10) || 0;
      const size     = parseInt($item.find('nyaa\\:size').text().trim(), 10) || 0;

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider:  'Nyaa',
        imdbId:    meta.imdbId,
        languages: ['ja'],
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[Nyaa] ${err.message}`);
    return [];
  }
}

function extractInfoHash(magnet = '') {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}
