/**
 * Bitsearch provider, scrapes search result cards with direct magnet links.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'https://bitsearch.eu';

export const id   = 'bitsearch';
export const name = 'Bitsearch';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const { data } = await get(`${BASE}/search`, {
      limiterKey: 'bitsearch',
      params: { q: query, sort: 'seeders' },
      timeout: 10000,
      retries: 1,
    });

    const $ = cheerio.load(data);
    const results = [];

    $('a[href^="magnet:"]').each((_, magnetLink) => {
      const $card = $(magnetLink).closest('div.bg-white');
      if (!$card.length) return;

      const magnet = $(magnetLink).attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);
      if (!infoHash || results.some(result => result.infoHash === infoHash)) return;

      const title = $card.find('a[href^="/torrent/"]').first().text().replace(/\s+/g, ' ').trim();
      if (!title) return;

      const text = $card.text().replace(/\s+/g, ' ').trim();

      results.push({
        infoHash,
        title,
        seeders: parseLabeledInteger(text, 'seeders'),
        leechers: parseLabeledInteger(text, 'leechers'),
        size: parseSize(text),
        provider: 'Bitsearch',
        imdbId: meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results.slice(0, 30);
  } catch (err) {
    logger.warn(`[Bitsearch] ${err.message}`);
    return [];
  }
}

function extractInfoHash(magnet) {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function parseLabeledInteger(text, label) {
  const match = text.match(new RegExp(`([\\d,]+)\\s+${label}`, 'i'));
  return match ? parseInt(match[1].replace(/,/g, ''), 10) || 0 : 0;
}

function parseSize(text) {
  const matches = Array.from(text.matchAll(/([\d.]+)\s*(KB|MB|GB|TB|B)\b/gi));
  const match = matches.at(-1);
  if (!match) return 0;
  const value = parseFloat(match[1]);
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(value * (units[match[2].toLowerCase()] ?? 1));
}
