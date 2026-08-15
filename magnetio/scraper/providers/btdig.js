/**
 * BTDig provider -- scrapes btdig.com search results via HTML.
 * DHT search engine, good for finding less common torrents.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'https://btdig.com';

export const id   = 'btdig';
export const name = 'BTDig';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const url   = `${BASE}/search`;

    const { data } = await get(url, {
      limiterKey: 'btdig',
      params: { q: query, order: 0 },
    });

    const $ = cheerio.load(data);
    const results = [];

    $('div.one_result').each((_, el) => {
      const $el = $(el);

      const titleEl = $el.find('div.torrent_name a').first();
      const title = titleEl.text().trim();
      if (!title) return;

      const href = titleEl.attr('href') ?? '';
      const infoHash = extractHashFromUrl(href);
      if (!infoHash) return;

      const statsText = $el.find('div.torrent_stats, span.torrent_size').text();
      const size = parseSize(statsText);

      const magnetEl = $el.find('a[href^="magnet:"]').first();
      const magnet = magnetEl.attr('href') ?? '';
      const magnetHash = extractInfoHash(magnet) ?? infoHash;

      results.push({
        infoHash: magnetHash,
        title,
        seeders: 0,
        leechers: 0,
        size,
        provider: 'BTDig',
        imdbId: meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[BTDig] ${err.message}`);
    return [];
  }
}

function extractHashFromUrl(url) {
  const match = url.match(/([a-fA-F0-9]{40})/i);
  return match ? match[1].toLowerCase() : null;
}

function extractInfoHash(magnet) {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function parseSize(str) {
  if (!str) return 0;
  const m = str.match(/([\d.]+)\s*(B|KB|MB|GB|TB)/i);
  if (!m) return 0;
  const val   = parseFloat(m[1]);
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(val * (units[m[2].toLowerCase()] ?? 1));
}
