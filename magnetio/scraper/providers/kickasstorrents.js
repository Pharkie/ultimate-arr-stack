/**
 * KickassTorrents provider -- scrapes search results via HTML.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.kickasstorrents;

export const id   = 'kickasstorrents';
export const name = 'KickassTorrents';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);

    const { data } = await tryDomains(DOMAINS, async (base) => {
      const url = `${base}/usearch/${encodeURIComponent(query)}/`;
      return get(url, { limiterKey: 'kickasstorrents' });
    }, 'KAT');

    const $ = cheerio.load(data);
    const results = [];

    $('tr.odd, tr.even').each((_, row) => {
      const $row    = $(row);
      const title   = $row.find('a.cellMainLink').first().text().trim();
      const magnet  = $row.find('a[href^="magnet:"]').first().attr('href') ?? '';
      const infoHash = extractInfoHash(magnet);

      if (!infoHash || !title) return;

      const seeders  = parseInt($row.find('td.green.center').first().text().trim(), 10) || 0;
      const leechers = parseInt($row.find('td.red.center').first().text().trim(), 10) || 0;
      const sizeText = $row.find('td').eq(1).text().trim();
      const size     = parseSize(sizeText);

      results.push({
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider: 'KickassTorrents',
        imdbId:   meta.imdbId,
        ...parseTitle(title),
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[KAT] ${err.message}`);
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
