/**
 * TorLock provider -- scrapes torlock2.com search results via HTML.
 * Verified torrents only (TorLock's USP).
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.torlock;

export const id   = 'torlock';
export const name = 'TorLock';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const cat   = meta.type === 'movie' ? 'movies' : 'television';

    const { data } = await tryDomains(DOMAINS, async (base) => {
      const url = `${base}/${cat}/torrents/${encodeURIComponent(query)}.html`;
      return get(url, { limiterKey: 'torlock' });
    }, 'TorLock');

    const $ = cheerio.load(data);
    const results = [];

    $('table tbody tr, div.table-striped article').each((_, row) => {
      const $row = $(row);
      const cells = $row.find('td');
      if (cells.length < 5) return;

      const titleEl = cells.eq(0).find('a').first();
      const title = titleEl.text().trim();
      if (!title) return;

      const detailHref = titleEl.attr('href') ?? '';
      const torrentId = detailHref.match(/\/torrent\/(\d+)\//)?.[1];
      if (!torrentId) return;

      const seeders  = parseInt(cells.eq(3).text().trim(), 10) || 0;
      const leechers = parseInt(cells.eq(4).text().trim(), 10) || 0;
      const sizeText = cells.eq(2).text().trim();
      const size     = parseSize(sizeText);

      const magnetEl = $row.find('a[href^="magnet:"]').first();
      const magnet = magnetEl.attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);
      if (!infoHash) return;

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider: 'TorLock',
        imdbId: meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[TorLock] ${err.message}`);
    return [];
  }
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
