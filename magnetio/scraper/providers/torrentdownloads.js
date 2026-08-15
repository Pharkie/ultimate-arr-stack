/**
 * TorrentDownloads provider -- scrapes torrentdownload.info search results via HTML.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.torrentdownloads;

export const id   = 'torrentdownloads';
export const name = 'TorrentDownloads';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const cat   = meta.type === 'movie' ? '4' : '8';

    const { data } = await tryDomains(DOMAINS, async (base) => {
      return get(`${base}/search/`, {
        limiterKey: 'torrentdownloads',
        params: { search: query, cat },
      });
    }, 'TorrentDownloads');

    const $ = cheerio.load(data);
    const results = [];

    $('table.table2 tr, div.grey_bar3').each((i, row) => {
      if (i === 0) return;
      const $row = $(row);
      const cells = $row.find('td');
      if (cells.length < 4) return;

      const titleEl = cells.eq(0).find('a').first();
      const title = titleEl.text().trim();
      if (!title) return;

      const magnetEl = $row.find('a[href^="magnet:"]').first();
      const magnet = magnetEl.attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);

      const detailHref = titleEl.attr('href') ?? '';
      const hashFromUrl = detailHref.match(/([a-fA-F0-9]{40})/)?.[1]?.toLowerCase();

      const hash = infoHash ?? hashFromUrl;
      if (!hash) return;

      const seeders  = parseInt(cells.eq(2).text().trim(), 10) || 0;
      const leechers = parseInt(cells.eq(3).text().trim(), 10) || 0;
      const sizeText = cells.eq(1).text().trim();
      const size     = parseSize(sizeText);

      results.push({
        infoHash: hash,
        title,
        seeders,
        leechers,
        size,
        provider: 'TorrentDownloads',
        imdbId: meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[TorrentDownloads] ${err.message}`);
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
