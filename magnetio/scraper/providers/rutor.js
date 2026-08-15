/**
 * Rutor provider — scrapes rutor.info for Russian-language torrents.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'http://rutor.info';

export const id   = 'rutor';
export const name = 'Rutor';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const cat   = meta.type === 'movie' ? '0' : '0';

    const { data } = await get(`${BASE}/search/0/${cat}/0/${encodeURIComponent(query)}`, {
      limiterKey: 'rutor',
    });

    const $       = cheerio.load(data);
    const results = [];

    $('tr').each((_, row) => {
      const $row  = $(row);
      const title = $row.find('a.downgif').next('a').text().trim()
                 || $row.find('td.nam a').last().text().trim();
      if (!title) return;

      const magnet   = $row.find('a[href^="magnet:"]').first().attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);
      if (!infoHash) return;

      const seeders  = parseInt($row.find('td.s').first().text().trim(), 10) || 0;
      const leechers = parseInt($row.find('td.l').first().text().trim(), 10) || 0;
      const sizeText = $row.find('td').last().text().trim();
      const size     = parseSize(sizeText);

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider:  'Rutor',
        imdbId:    meta.imdbId,
        languages: ['ru'],
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[Rutor] ${err.message}`);
    return [];
  }
}

function extractInfoHash(magnet = '') {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function parseSize(str) {
  if (!str) return 0;
  const m = str.match(/([\d.,]+)\s*(B|KB|MB|GB|TB)/i);
  if (!m) return 0;
  const val   = parseFloat(m[1].replace(',', '.'));
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(val * (units[m[2].toLowerCase()] ?? 1));
}
