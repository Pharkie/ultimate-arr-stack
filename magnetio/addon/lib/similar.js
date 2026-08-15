/**
 * Similar content recommendations via TMDB API.
 *
 * Converts IMDb IDs to TMDB IDs, fetches recommendations,
 * and returns Stremio-compatible meta objects.
 */
import axios from 'axios';
import { cacheWrap } from './cache.js';
import { logger } from './logger.js';

const TMDB_BASE = 'https://api.themoviedb.org/3';
const POSTER_BASE = 'https://image.tmdb.org/t/p/w500';
const BACKDROP_BASE = 'https://image.tmdb.org/t/p/w780';

const CACHE_TTL_ID_MAP = 604800;    // 7 days for IMDb-to-TMDB mapping
const CACHE_TTL_RECS   = 86400;     // 24 hours for recommendations
const REQUEST_TIMEOUT  = 8000;

/**
 * Get similar content recommendations for a given IMDb ID.
 *
 * @param {string} imdbId    IMDb ID (e.g. 'tt1234567')
 * @param {string} type      'movie' or 'series'
 * @param {string} apiKey    TMDB API key
 * @returns {Promise<StremioMeta[]>}
 */
export async function getSimilarContent(imdbId, type, apiKey) {
  if (!apiKey || !imdbId) return [];

  const cacheKey = `similar:${type}:${imdbId}`;

  return cacheWrap(cacheKey, async () => {
    try {
      const tmdbId = await imdbToTmdb(imdbId, type, apiKey);
      if (!tmdbId) {
        logger.warn(`[Similar] No TMDB ID found for ${imdbId}`);
        return [];
      }

      const recs = await fetchRecommendations(tmdbId, type, apiKey);
      const metas = await Promise.all(
        recs.map(r => enrichWithImdb(r, type, apiKey))
      );

      const valid = metas.filter(m => m && m.id);
      logger.info(`[Similar] ${valid.length} recommendations for ${imdbId}`);
      return valid;
    } catch (err) {
      logger.warn(`[Similar] ${err.message}`);
      return [];
    }
  }, CACHE_TTL_RECS);
}

/**
 * Convert an IMDb ID to a TMDB ID using the /find endpoint.
 */
async function imdbToTmdb(imdbId, type, apiKey) {
  const cacheKey = `tmdb-id:${imdbId}`;

  return cacheWrap(cacheKey, async () => {
    const { data } = await axios.get(`${TMDB_BASE}/find/${imdbId}`, {
      timeout: REQUEST_TIMEOUT,
      params: { api_key: apiKey, external_source: 'imdb_id' },
    });

    if (type === 'series' || type === 'anime') {
      const tv = data.tv_results?.[0];
      return tv?.id || null;
    }

    const movie = data.movie_results?.[0];
    return movie?.id || null;
  }, CACHE_TTL_ID_MAP);
}

/**
 * Fetch recommendations from TMDB for a given TMDB ID.
 */
async function fetchRecommendations(tmdbId, type, apiKey) {
  const endpoint = (type === 'series' || type === 'anime') ? 'tv' : 'movie';

  const { data } = await axios.get(
    `${TMDB_BASE}/${endpoint}/${tmdbId}/recommendations`,
    {
      timeout: REQUEST_TIMEOUT,
      params: { api_key: apiKey, page: 1 },
    }
  );

  return data.results || [];
}

/**
 * Enrich a TMDB result with its IMDb ID and convert to Stremio meta format.
 */
async function enrichWithImdb(tmdbResult, type, apiKey) {
  const endpoint = (type === 'series' || type === 'anime') ? 'tv' : 'movie';
  const tmdbId = tmdbResult.id;

  try {
    const cacheKey = `tmdb-external:${endpoint}:${tmdbId}`;
    const imdbId = await cacheWrap(cacheKey, async () => {
      const { data } = await axios.get(
        `${TMDB_BASE}/${endpoint}/${tmdbId}/external_ids`,
        { timeout: REQUEST_TIMEOUT, params: { api_key: apiKey } }
      );
      return data.imdb_id || null;
    }, CACHE_TTL_ID_MAP);

    if (!imdbId) return null;

    return toStremioMeta(tmdbResult, type, imdbId);
  } catch {
    return toStremioMeta(tmdbResult, type, null);
  }
}

/**
 * Convert a TMDB result object to a Stremio meta preview.
 */
function toStremioMeta(item, type, imdbId) {
  const title = item.title || item.name || '';
  const releaseDate = item.release_date || item.first_air_date || '';
  const year = releaseDate ? releaseDate.substring(0, 4) : '';
  const rating = item.vote_average ? String(Math.round(item.vote_average * 10) / 10) : '';

  if (!imdbId) return null;

  const meta = {
    id: imdbId,
    type: (type === 'anime') ? 'series' : type,
    name: title,
  };

  if (item.poster_path) {
    meta.poster = `${POSTER_BASE}${item.poster_path}`;
  }

  if (item.backdrop_path) {
    meta.background = `${BACKDROP_BASE}${item.backdrop_path}`;
  }

  if (item.overview) {
    meta.description = item.overview;
  }

  if (year) {
    meta.releaseInfo = year;
  }

  if (rating) {
    meta.imdbRating = rating;
  }

  return meta;
}
