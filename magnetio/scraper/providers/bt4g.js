/**
 * BT4G provider -- scrapes bt4gprx.com search results via HTML.
 * Supports movies and series.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'https://bt4gprx.com';

export const id   = 'bt4g';
export const name = 'BT4G';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const url   = `${BASE}/search/${encodeURIComponent(query)}/byseeders/1`;

    const { data } = await get(url, { limiterKey: 'bt4g' });
    const $ = cheerio.load(data);
    const results = [];

    $('div.search-ret-item, div.one-result').each((_, el) => {
      const $el = $(el);

      const titleEl = $el.find('h5 a, a.item-title').first();
      const title = titleEl.text().trim();
      if (!title) return;

      const magnetEl = $el.find('a[href^="magnet:"]').first();
      const magnet = magnetEl.attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);
      if (!infoHash) return;

      const statsText = $el.text();
      const seeders  = extractNumber(statsText, /(\d+)\s*seeder/i);
      const leechers = extractNumber(statsText, /(\d+)\s*leecher/i);
      const sizeText = $el.find('span:contains("B")').first().text().trim()
                    || extractSizeText(statsText);
      const size = parseSize(sizeText);

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider: 'BT4G',
        imdbId: meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[BT4G] ${err.message}`);
    return [];
  }
}

function extractInfoHash(magnet) {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function extractNumber(text, pattern) {
  const m = text.match(pattern);
  return m ? parseInt(m[1], 10) : 0;
}

function extractSizeText(text) {
  const m = text.match(/([\d.]+)\s*(B|KB|MB|GB|TB)/i);
  return m ? m[0] : '';
}

function parseSize(str) {
  if (!str) return 0;
  const m = str.match(/([\d.]+)\s*(B|KB|MB|GB|TB)/i);
  if (!m) return 0;
  const val   = parseFloat(m[1]);
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(val * (units[m[2].toLowerCase()] ?? 1));
}
