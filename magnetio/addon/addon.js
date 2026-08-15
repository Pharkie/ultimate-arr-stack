import StremioAddonSdk from 'stremio-addon-sdk';
import { manifest } from './lib/manifest.js';
import { getStreams } from './lib/repository.js';
import { applyMochs, getMochCatalog, getMochItemMeta } from './moch/moch.js';
import { applyFilters } from './lib/filter.js';
import { sortStreams } from './lib/sort.js';
import { toStreamInfo } from './lib/streamInfo.js';
import { getSubtitles } from './lib/subtitles.js';
import { getYifySubtitles } from './lib/yifySubtitles.js';
import { getTvSubtitles } from './lib/tvSubtitles.js';
import { getCommunitySubtitles } from './lib/communitySubtitles.js';
import { attachTranslatedSubtitles } from './lib/translatedSubtitles.js';
import { toStaticStream } from './moch/static.js';
import { getSimilarContent } from './lib/similar.js';
import NamedQueue from './lib/namedQueue.js';
import pLimit from 'p-limit';
import { logger } from './lib/logger.js';

const ADDON_NAME = 'Magnetio';
const MAX_CONCURRENT_REQUESTS = 200;
const STREAM_LIMIT = 50;
const { addonBuilder } = StremioAddonSdk;

const requestQueue = new NamedQueue(MAX_CONCURRENT_REQUESTS);
const streamLimit = pLimit(STREAM_LIMIT);

// Cache TTLs (seconds)
const CACHE_TTL_OK     = 60 * 60;       // 1 hour on success
const CACHE_TTL_EMPTY  = 60;            // 60 s on empty
const CACHE_TTL_ERROR  = 30;            // 30 s on error

/**
 * Build and return an Express router for a specific addon configuration.
 */
export async function getAddonInterface(config) {
  const addonManifest = manifest(config);
  const builder = new addonBuilder(addonManifest);

  // ─── STREAM HANDLER ────────────────────────────────────────────────────────
  builder.defineStreamHandler(async ({ type, id }) => {
    if (!id.match(/^(tt\d+|kitsu:\d+)(:\d+:\d+)?$/)) {
      return { streams: [], cacheMaxAge: CACHE_TTL_EMPTY };
    }

    return new Promise((resolve) => {
      requestQueue.wrap({ id: `stream:${id}` }, async (done) => {
        try {
          const streams = await streamLimit(async () => {
            // 1. Fetch raw torrent records
            const records = await getStreams(type, id, config);

            // 2. Sort by seeders / quality
            const sorted = sortStreams(records, config);

            // 3. Apply provider / quality / language filters
            const filtered = applyFilters(sorted, config);

            // 4. Map to stream objects
            const baseStreams = filtered.map(r => toStreamInfo(r, config));

            // 5. Apply debrid service enhancements (moch)
            const enhanced = await applyMochs(baseStreams, config, { type, id });

            // 6. Inject any static streams
            const statics = toStaticStream(id, config);

            const finalStreams = applyFinalStreamLimit([...statics, ...enhanced], config);
            logStreamSummary({ type, id, config, records, filtered, baseStreams, finalStreams });
            return finalStreams;
          });

          const hasStreams = streams.length > 0;
          resolve({
            streams,
            cacheMaxAge: hasStreams ? CACHE_TTL_OK : CACHE_TTL_EMPTY,
            staleRevalidate: hasStreams ? 3600 : 0,
            staleError: hasStreams ? 14400 : 0,
          });
        } catch (err) {
          logger.error(`Stream handler error [${id}]: ${err.message}`);
          resolve({ streams: [], cacheMaxAge: CACHE_TTL_ERROR });
        } finally {
          done();
        }
      });
    });
  });

  // ─── CATALOG HANDLER ───────────────────────────────────────────────────────
  builder.defineCatalogHandler(async ({ type, id, extra }) => {
    try {
      // Similar content recommendations (TMDB)
      if (id.startsWith('magnetio_similar_')) {
        const imdbId = extra?.genre || null;
        if (!imdbId || !config.tmdbApiKey) {
          return { metas: [], cacheMaxAge: CACHE_TTL_EMPTY };
        }
        const metas = await getSimilarContent(imdbId, type, config.tmdbApiKey);
        return {
          metas,
          cacheMaxAge: metas.length ? 86400 : CACHE_TTL_EMPTY,
        };
      }

      // Debrid library catalogs
      const skip = extra?.skip ? parseInt(extra.skip, 10) : 0;
      const metas = await getMochCatalog(id, type, config, skip);
      return { metas, cacheMaxAge: CACHE_TTL_OK };
    } catch (err) {
      logger.error(`Catalog handler error [${id}]: ${err.message}`);
      return { metas: [], cacheMaxAge: CACHE_TTL_ERROR };
    }
  });

  // ─── META HANDLER ──────────────────────────────────────────────────────────
  builder.defineMetaHandler(async ({ type, id }) => {
    try {
      const meta = await getMochItemMeta(id, type, config);
      return { meta, cacheMaxAge: CACHE_TTL_OK };
    } catch (err) {
      logger.error(`Meta handler error [${id}]: ${err.message}`);
      return { meta: null, cacheMaxAge: CACHE_TTL_ERROR };
    }
  });

  // ─── SUBTITLES HANDLER ─────────────────────────────────────────────────────
  builder.defineSubtitlesHandler(async ({ type, id, extra = {} }) => {
    try {
      const args = { type, id, extra };
      const [opensubtitles, yify, tvsubs, community] = await Promise.all([
        getSubtitles(args, config).catch(err => {
          logger.warn(`Primary subtitle source failed [${id}]: ${err.message}`);
          return [];
        }),
        getYifySubtitles(args, config).catch(err => {
          logger.warn(`Movie subtitle source failed [${id}]: ${err.message}`);
          return [];
        }),
        getTvSubtitles(args, config).catch(err => {
          logger.warn(`Series subtitle source failed [${id}]: ${err.message}`);
          return [];
        }),
        getCommunitySubtitles(args, config).catch(err => {
          logger.warn(`Community subtitle source failed [${id}]: ${err.message}`);
          return [];
        }),
      ]);

      const merged = mergeSubtitles(opensubtitles, yify, tvsubs, community);
      const subtitles = attachTranslatedSubtitles(merged, config);
      const cacheAge = subtitles.length ? CACHE_TTL_OK : CACHE_TTL_EMPTY;
      return {
        subtitles,
        cacheMaxAge: cacheAge,
        staleRevalidate: 3600,
        staleError: 14400,
      };
    } catch (err) {
      logger.error(`Subtitle handler error [${id}]: ${err.message}`);
      return { subtitles: [], cacheMaxAge: CACHE_TTL_ERROR };
    }
  });

  return builder.getInterface();
}

export function applyFinalStreamLimit(streams, config = {}) {
  const limit = Math.max(0, parseInt(config.limit, 10) || 10);
  return streams.slice(0, limit);
}

export function mergeSubtitles(...sources) {
  const merged = [];
  const seenIds = new Set();
  const seenUrls = new Set();
  const perLanguageCount = new Map();
  const PER_LANGUAGE_CAP = 4;
  const TOTAL_CAP = 12;

  for (const subtitle of sources.flat()) {
    if (!subtitle?.url) continue;
    const id = String(subtitle.id || subtitle.url);
    const url = String(subtitle.url);
    if (seenIds.has(id) || seenUrls.has(url)) continue;

    const lang = subtitle.lang || 'eng';
    const count = perLanguageCount.get(lang) || 0;
    if (count >= PER_LANGUAGE_CAP) continue;

    merged.push(subtitle);
    seenIds.add(id);
    seenUrls.add(url);
    perLanguageCount.set(lang, count + 1);
    if (merged.length >= TOTAL_CAP) break;
  }

  return merged;
}

function logStreamSummary({ type, id, config, records, filtered, baseStreams, finalStreams }) {
  const direct = finalStreams.filter(stream => stream.url).length;
  const p2p = finalStreams.filter(stream => stream.infoHash && !stream.url).length;
  const debridCount = [
    config.realDebridApiKey,
    config.premiumizeApiKey,
    config.allDebridApiKey,
    config.debridLinkApiKey,
    config.easyDebridApiKey,
    config.offcloudApiKey,
    config.torboxApiKey,
    config.putioApiKey,
  ].filter(Boolean).length;

  logger.info(
    `Stream ${type}/${id}: providers=${(config.providers || []).join(',') || 'default'} ` +
    `qualities=${(config.qualities || []).join(',') || 'all'} ` +
    `languages=${(config.languages || []).join(',') || 'all'} ` +
    `limit=${config.limit ?? 10} debrid_count=${debridCount} ` +
    `records=${records.length} filtered=${filtered.length} base=${baseStreams.length} ` +
    `final=${finalStreams.length} direct=${direct} p2p=${p2p}`
  );
}
