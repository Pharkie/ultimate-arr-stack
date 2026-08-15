/**
 * AnimeTosho provider -- uses the Atom/RSS feed for anime torrents.
 * Aggregates results from Nyaa, TokyoTosho, and other anime trackers.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { extractInfoHash, parseSize } from '../lib/magnetHelper.js';
import { logger } from '../lib/logger.js';

const FEED_BASE = 'https://feed.animetosho.org';

export const id   = 'animetosho';
export const name = 'AnimeTosho';

export async function scrape(meta) {
  if (meta.type !== 'series' && meta.type !== 'anime') return [];
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);

    const { data } = await get(`${FEED_BASE}/rss2`, {
      limiterKey: 'animetosho',
      params: {
        q:  query,
        qx: 1,
        only_tor: 1,
      },
    });

    const $ = cheerio.load(data, { xmlMode: true });
    const results = [];

    $('item').each((_, item) => {
      const $item = $(item);
      const title = $item.find('title').text().trim();
      if (!title) return;

      // Extract infoHash from the magnet link in the description or link
      const desc = $item.find('description').text() || '';
      const link = $item.find('link').text().trim() || '';

      let infoHash = null;

      // Try magnet link extraction from description or link
      const magnetMatch = desc.match(/magnet:\?[^\s"<]+/i)
        || link.match(/magnet:\?[^\s"<]+/i);

      if (magnetMatch) {
        infoHash = extractInfoHash(magnetMatch[0]);
      }

      // Try torrent filename hash (animetosho stores torrents as /storage/torrent/{hash}/...)
      if (!infoHash) {
        const torrentMatch = desc.match(/\/storage\/torrent\/([a-fA-F0-9]{40})\//i);
        if (torrentMatch) infoHash = torrentMatch[1].toLowerCase();
      }

      if (!infoHash) return;

      // Parse seeders/leechers from description brackets like [515/59]
      let seeders = 0;
      let leechers = 0;
      const statsMatch = desc.match(/\[(\d+)[^\/]*\/(\d+)/);
      if (statsMatch) {
        seeders  = parseInt(statsMatch[1], 10) || 0;
        leechers = parseInt(statsMatch[2], 10) || 0;
      }

      // Parse size from enclosure or description
      let size = 0;
      const encLength = $item.find('enclosure').attr('length');
      if (encLength) {
        size = parseInt(encLength, 10) || 0;
      }
      if (!size) {
        const sizeMatch = desc.match(/([\d.]+)\s*(GB|MB|TB|KB)/i);
        if (sizeMatch) {
          size = parseSize(`${sizeMatch[1]} ${sizeMatch[2]}`);
        }
      }

      results.push({
        ...parseTitle(title),
        infoHash,
        title,
        seeders,
        leechers,
        size,
        provider:  'AnimeTosho',
        imdbId:    meta.imdbId,
        languages: ['ja'],
      });
    });

    return results;
  } catch (err) {
    logger.warn(`[AnimeTosho] ${err.message}`);
    return [];
  }
}

