/**
 * TorrentGalaxy provider -- scrapes search results via HTML.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.torrentgalaxy;

export const id   = 'torrentgalaxy';
export const name = 'TorrentGalaxy';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);

    // torrents.php?search= is a legacy route that now 302s to the homepage
    // (confirmed live 2026-08-16) - the site's own search bar calls
    // /get-posts/keywords:<query> via JS (searchKeyword() in the homepage
    // markup). No category param on this route; relevance is enforced by
    // the addon's own content filter downstream instead.
    const { data } = await tryDomains(DOMAINS, async (base) => {
      return get(`${base}/get-posts/keywords:${encodeURIComponent(query)}`, {
        limiterKey: 'torrentgalaxy',
      });
    }, 'TorrentGalaxy');

    const $ = cheerio.load(data);
    const results = [];

    $('div.tgxtablerow').each((_, row) => {
      const $row = $(row);

      const titleEl = $row.find('a.txlight').first();
      const title   = titleEl.text().trim();
      if (!title) return;

      const magnetEl = $row.find('a[href^="magnet:"]').first();
      const magnet   = magnetEl.attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);
      if (!infoHash) return;

      const seeders  = parseInt($row.find('span.badge-success').first().text().trim(), 10) || 0;
      const leechers = parseInt($row.find('span.badge-danger').first().text().trim(), 10) || 0;

      const sizeText = $row.find('span.badge-secondary').first().text().trim();
      const size     = parseSize(sizeText);

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider: 'TorrentGalaxy',
        imdbId:   meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[TorrentGalaxy] ${err.message}`);
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
