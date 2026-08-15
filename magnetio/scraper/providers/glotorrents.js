/**
 * GloTorrents provider -- scrapes glodls.to search results via HTML.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.glotorrents;

export const id   = 'glotorrents';
export const name = 'GloTorrents';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const cat   = meta.type === 'movie' ? '1' : '41';

    const { data } = await tryDomains(DOMAINS, async (base) => {
      return get(`${base}/search_results.php`, {
        limiterKey: 'glotorrents',
        params: {
          search: query,
          cat,
          incldead: 0,
          inclexternal: 0,
          lang: 0,
          sort: 'seeders',
          order: 'desc',
        },
      });
    }, 'GloTorrents');

    const $ = cheerio.load(data);
    const results = [];

    $('table tr').each((i, row) => {
      if (i === 0) return;
      const $row = $(row);
      const cells = $row.find('td');
      if (cells.length < 6) return;

      const titleEl = cells.eq(1).find('a').first();
      const title = titleEl.text().trim();
      if (!title) return;

      const magnetEl = $row.find('a[href^="magnet:"]').first();
      const magnet = magnetEl.attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);
      if (!infoHash) return;

      const seeders  = parseInt(cells.eq(4).text().trim(), 10) || 0;
      const leechers = parseInt(cells.eq(5).text().trim(), 10) || 0;
      const sizeText = cells.eq(3).text().trim();
      const size     = parseSize(sizeText);

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider: 'GloTorrents',
        imdbId: meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[GloTorrents] ${err.message}`);
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
