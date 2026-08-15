/**
 * YTS provider -- uses the official YTS JSON API.
 * Supports movies only (no series).
 */
import { get } from '../lib/httpClient.js';
import { parseTitle } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS.yts;

export const id   = 'yts';
export const name = 'YTS';

export async function scrape(meta) {
  if (meta.type !== 'movie') return [];

  try {
    const { data } = await tryDomains(DOMAINS, async (base) => {
      return get(`${base}/api/v2/list_movies.json`, {
        limiterKey: 'yts',
        responseType: 'json',
        params: {
          query_term: meta.imdbId,
          limit: 50,
          sort_by: 'seeds',
        },
      });
    }, 'YTS');

    const movies = data?.data?.movies ?? [];
    return movies.flatMap(movie =>
      (movie.torrents ?? []).map(t => normalise(movie, t))
    );
  } catch (err) {
    logger.warn(`[YTS] ${err.message}`);
    return [];
  }
}

function normalise(movie, t) {
  const titleStr = `${movie.title} ${t.quality} ${t.type}`;
  return {
    infoHash:  t.hash?.toLowerCase(),
    title:     `${movie.title_long} [${t.quality}] [${t.type}]`,
    seeders:   t.seeds ?? 0,
    leechers:  t.peers ?? 0,
    size:      t.size_bytes ?? 0,
    provider:  'YTS',
    quality:   t.quality,
    languages: ['en'],
    imdbId:    movie.imdb_code,
    trackers: [
      'udp://open.demonii.com:1337/announce',
      'udp://tracker.openbittorrent.com:80',
      'udp://tracker.coppersurfer.tk:6969',
      'udp://glotorrents.pw:6969/announce',
      'udp://tracker.opentrackr.org:1337/announce',
      'udp://torrent.gresille.org:80/announce',
      'udp://p4p.arenabg.com:1337',
      'udp://tracker.leechers-paradise.org:6969',
    ],
    ...parseTitle(titleStr),
  };
}
