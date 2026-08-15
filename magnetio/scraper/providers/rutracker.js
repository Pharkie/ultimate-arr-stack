/**
 * Rutracker provider — scrapes rutracker.org (requires no login for search).
 * Focused on Russian-language and multi-audio releases.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'https://rutracker.org/forum';

export const id   = 'rutracker';
export const name = 'Rutracker';

export async function scrape(meta) {
  if (!meta?.name) return [];

  try {
    const query = buildSearchQuery(meta);

    const { data } = await get(`${BASE}/tracker.php`, {
      limiterKey: 'rutracker',
      params: {
        nm: query,
      },
      headers: {
        'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
      },
    });

    const $       = cheerio.load(data);
    const results = [];

    $('tr.tCenter.hl-tr').each((_, row) => {
      const $row = $(row);

      const titleEl = $row.find('a.tLink').first();
      const title   = titleEl.text().trim();
      const topicUrl= titleEl.attr('href') ?? '';
      const topicId = topicUrl.match(/t=(\d+)/)?.[1];

      if (!title || !topicId) return;

      // Rutracker magnet links are at a predictable URL
      const infoHash = $row.find('a[data-topic_id]').attr('data-topic_id') ?? null;
      // Rutracker provides magnet links via separate call; we build the hash from topic id
      // as a placeholder — real impl would follow topic page to get the actual hash
      const magnet = `https://rutracker.org/forum/viewtopic.php?t=${topicId}`;

      const seeders  = parseInt($row.find('b.seedmed, b.seedmed').text().trim(), 10) || 0;
      const sizeText = $row.find('td.tor-size').text().trim();
      const size     = parseSize(sizeText);

      // We store the topic ID as a proxy infoHash; real infoHash resolved lazily
      if (!topicId) return;

      results.push({
        infoHash:  null, // resolved from topic page
        topicId,
        title,
        seeders,
        leechers:  0,
        size,
        provider:  'Rutracker',
        imdbId:    meta.imdbId,
        languages: ['ru'],
        ...parseTitle(title),
      });
    });

    // Resolve infoHashes for top results (by seeders)
    const top = results.sort((a, b) => b.seeders - a.seeders).slice(0, 10);
    const resolved = await Promise.allSettled(top.map(r => resolveInfoHash(r)));

    return resolved
      .filter(r => r.status === 'fulfilled' && r.value?.infoHash)
      .map(r => r.value);
  } catch (err) {
    logger.warn(`[Rutracker] ${err.message}`);
    return [];
  }
}

async function resolveInfoHash(record) {
  try {
    const { data } = await get(
      `https://rutracker.org/forum/viewtopic.php?t=${record.topicId}`,
      { limiterKey: 'rutracker' }
    );
    const $ = cheerio.load(data);

    // Magnet link on topic page
    const magnet   = $('a[href^="magnet:"]').first().attr('href') ?? '';
    const infoHash = extractInfoHash(magnet);
    if (!infoHash) return null;

    return { ...record, infoHash };
  } catch {
    return null;
  }
}

function extractInfoHash(magnet = '') {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function parseSize(str) {
  if (!str) return 0;
  const m = str.match(/([\d.,]+)\s*(B|KB|MB|GB|TB|ГБ|МБ)/i);
  if (!m) return 0;
  const val = parseFloat(m[1].replace(',', '.'));
  const map = { b: 1, kb: 1024, mb: 1024**2, gb: 1024**3, tb: 1024**4, гб: 1024**3, мб: 1024**2 };
  return Math.round(val * (map[m[2].toLowerCase()] ?? 1));
}
