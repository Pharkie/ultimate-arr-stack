/**
 * LimeTorrents provider -- scrapes search results and detail pages via HTML.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.limetorrents;

export const id   = 'limetorrents';
export const name = 'LimeTorrents';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);
    const type  = meta.type === 'movie' ? 'movies' : 'tv';

    const { data, base } = await tryDomains(DOMAINS, async (base) => {
      const url = `${base}/search/${type}/${encodeURIComponent(query)}/seeds/1/`;
      const res = await get(url, { limiterKey: 'limetorrents' });
      return { data: res.data, base };
    }, 'LimeTorrents');

    const $ = cheerio.load(data);
    const rows = [];

    $('table.table2 tr').each((_, row) => {
      const cells = $(row).find('td');
      if (cells.length < 5) return;

      const title = cells.eq(0).find('a[href*="-torrent-"]').first().text().trim();
      const detailHref = cells.eq(0).find('a[href*="-torrent-"]').first().attr('href');
      const torrentHref = cells.eq(0).find('a[href*="itorrents.net/torrent/"]').first().attr('href');
      const infoHash = extractHashFromTorrentUrl(torrentHref);
      if (!title || !detailHref || !infoHash) return;

      rows.push({
        infoHash,
        title,
        detailUrl: detailHref.startsWith('http') ? detailHref : `${base}${detailHref}`,
        seeders: parseInteger(cells.eq(3).text()),
        leechers: parseInteger(cells.eq(4).text()),
        size: parseSize(cells.eq(2).text()),
      });
    });

    const settled = await Promise.allSettled(
      rows.slice(0, 12).map(row => fetchDetail(row, meta))
    );

    return settled.flatMap(result =>
      result.status === 'fulfilled' && result.value ? [result.value] : []
    );
  } catch (err) {
    logger.warn(`[LimeTorrents] ${err.message}`);
    return [];
  }
}

async function fetchDetail(row, meta) {
  try {
    const { data } = await get(row.detailUrl, { limiterKey: 'limetorrents' });
    const magnet = data.match(/magnet:\?[^"']+/i)?.[0] ?? '';
    const infoHash = extractInfoHash(magnet) ?? row.infoHash;

    return {
      infoHash,
      title: row.title,
      seeders: row.seeders,
      leechers: row.leechers,
      size: row.size,
      provider: 'LimeTorrents',
      imdbId: meta.imdbId,
      ...parseTitle(row.title),
    };
  } catch {
    return null;
  }
}

function extractHashFromTorrentUrl(url = '') {
  const match = url.match(/\/torrent\/([a-fA-F0-9]{40})\.torrent/i);
  return match ? match[1].toLowerCase() : null;
}

function extractInfoHash(magnet) {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function parseInteger(value) {
  return parseInt(String(value ?? '').replace(/,/g, '').trim(), 10) || 0;
}

function parseSize(str) {
  if (!str) return 0;
  const match = str.match(/([\d.]+)\s*(KB|MB|GB|TB|B)\b/i);
  if (!match) return 0;
  const value = parseFloat(match[1]);
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(value * (units[match[2].toLowerCase()] ?? 1));
}
