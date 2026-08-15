/**
 * AnimeSaturn provider — scrapes animesaturn.cx for Italian-dubbed anime.
 * Returns magnet links extracted from torrent detail pages.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

const BASE = 'https://www.animesaturn.cx';

export const id   = 'animesaturn';
export const name = 'AnimeSaturn';

export async function scrape(meta) {
  if (meta.type !== 'series' && meta.type !== 'anime') return [];

  try {
    const query = buildSearchQuery(meta);

    const { data } = await get(`${BASE}/animelist`, {
      limiterKey: 'animesaturn',
      params: { search: query },
    });

    const $ = cheerio.load(data);
    const results = [];

    // Collect anime page links from search results
    const animeLinks = [];
    $('a.badge-archivio, div.anime-card-container a').each((_, a) => {
      const href = $(a).attr('href');
      if (href && href.includes('/anime/')) {
        animeLinks.push(href.startsWith('http') ? href : `${BASE}${href}`);
      }
    });

    for (const link of animeLinks.slice(0, 3)) {
      const episodes = await scrapeEpisodes(link, meta);
      results.push(...episodes);
    }

    return results;
  } catch (err) {
    logger.warn(`[AnimeSaturn] ${err.message}`);
    return [];
  }
}

async function scrapeEpisodes(animeUrl, meta) {
  try {
    const { data } = await get(animeUrl, { limiterKey: 'animesaturn' });
    const $ = cheerio.load(data);
    const results = [];

    const episodeLinks = [];
    $('a[href*="/ep/"]').each((_, a) => {
      const href = $(a).attr('href');
      if (href) episodeLinks.push(href.startsWith('http') ? href : `${BASE}${href}`);
    });

    // If requesting a specific episode, filter
    const targetLinks = meta.episode != null
      ? episodeLinks.filter(l => l.includes(`Ep-${meta.episode}-`))
      : episodeLinks.slice(0, 5);

    for (const epLink of targetLinks) {
      const item = await scrapeEpisodeTorrent(epLink, meta);
      if (item) results.push(item);
    }

    return results;
  } catch {
    return [];
  }
}

async function scrapeEpisodeTorrent(epUrl, meta) {
  try {
    const { data } = await get(epUrl, { limiterKey: 'animesaturn' });
    const $ = cheerio.load(data);

    const magnet    = $('a[href^="magnet:"]').first().attr('href') ?? '';
    const infoHash  = extractInfoHash(magnet);
    if (!infoHash) return null;

    const title = $('h1.anime-title, h1').first().text().trim() || epUrl;

    return {
      infoHash,
      title,
      seeders:   0,
      leechers:  0,
      size:      0,
      provider:  'AnimeSaturn',
      imdbId:    meta.imdbId,
      languages: ['it', 'ja'],
      quality:   null,
    };
  } catch {
    return null;
  }
}

function extractInfoHash(magnet = '') {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}
