import { MochOptions, MIN_API_KEY_LENGTH } from './options.js';
import { isValidToken, buildDebridStream } from './mochHelper.js';
import { createStreamSubtitleProxies } from '../lib/subtitleProxy.js';
import { cacheGet, cacheSet } from '../lib/cache.js';
import NamedQueue from '../lib/namedQueue.js';
import pLimit from 'p-limit';
import * as RealDebrid  from './realdebrid.js';
import * as Premiumize  from './premiumize.js';
import * as AllDebrid   from './alldebrid.js';
import * as DebridLink  from './debridlink.js';
import * as EasyDebrid  from './easydebrid.js';
import * as Offcloud    from './offcloud.js';
import * as TorBox      from './torbox.js';
import * as Putio       from './putio.js';
import { logger } from '../lib/logger.js';

// Map MochOptions key → module
const MOCH_MODULES = {
  realdebrid:  RealDebrid,
  premiumize:  Premiumize,
  alldebrid:   AllDebrid,
  debridlink:  DebridLink,
  easydebrid:  EasyDebrid,
  offcloud:    Offcloud,
  torbox:      TorBox,
  putio:       Putio,
};

const PREWARM_CACHE_TTL = 60 * 60 * 6;
const PREWARM_QUEUE = new NamedQueue(4);
const RESOLVE_TIMEOUT_MS = 8_000;
const resolveLimit = pLimit(4);

/**
 * Enhance a list of streams using all configured debrid services.
 *
 * For each enabled service:
 *   1. Check which infoHashes are instantly available (cached).
 *   2. Re-emit cached streams as direct-download streams.
 *   3. Return direct streams only. Users without debrid keys get raw P2P torrents instead.
 *
 * @param {StreamObject[]} streams         Raw stream objects from repository
 * @param {object}         config          Addon configuration
 * @param {object}         requestContext  Current stream request context
 * @returns {Promise<StreamObject[]>}
 */
export async function applyMochs(streams, config, requestContext) {
  const enabled = getEnabledMochs(config);
  if (!enabled.length) return streams;

  const directStreams = [];

  await Promise.allSettled(
    enabled.map(async ({ key, moch, module }) => {
      const apiKey = config[moch.configKey];
      if (!isValidToken(apiKey, MIN_API_KEY_LENGTH)) return;

      try {
        const cachedMap = await module.getCachedStreams(streams, apiKey);
        schedulePrewarm(streams, cachedMap, apiKey, moch, module, config);

        const debridResults = await Promise.allSettled(
          streams
            .filter(stream => stream.infoHash && cachedMap.has(stream.infoHash?.toLowerCase()))
            .map(stream => resolveLimit(async () => {
              const url = await withTimeout(
                module.resolve(stream, apiKey),
                RESOLVE_TIMEOUT_MS,
                `${moch.name} resolve timed out`
              );
              return { stream, url };
            }))
        );

        for (const settled of debridResults) {
          if (settled.status !== 'fulfilled') {
            logger.warn(`Moch resolve skipped [${moch.name}]: ${settled.reason?.message}`);
            continue;
          }

          const { stream, url } = settled.value;
          if (!url) continue;

          const debridStream = buildDebridStream(stream, url, moch.name);
          const proxySubtitles = await createStreamSubtitleProxies(requestContext, debridStream, config);
          if (proxySubtitles.length) {
            debridStream.subtitles = proxySubtitles;
          }
          directStreams.push(debridStream);
        }
      } catch (err) {
        logger.error(`Moch error [${moch.name}]: ${err.message}`);
      }
    })
  );

  if (directStreams.length) {
    return directStreams;
  }

  logger.warn(`No debrid streams resolved, returning raw P2P (${streams.length} streams)`);
  return streams;
}

async function withTimeout(promise, timeoutMs, message) {
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error(message)), timeoutMs);
  });

  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

/**
 * Fetch the catalog for a specific debrid service ID (e.g. "rd_movie").
 */
export async function getMochCatalog(catalogId, type, config, skip = 0) {
  const [mochId] = catalogId.split('_');
  const entry    = findMochByShortId(mochId);
  if (!entry) return [];

  const { moch, module } = entry;
  const apiKey = config[moch.configKey];

  if (!isValidToken(apiKey, MIN_API_KEY_LENGTH) || !module.getCatalog) return [];
  return module.getCatalog(apiKey, type, skip);
}

/**
 * Fetch metadata for an item with a debrid-prefixed ID (e.g. "rd:abc123").
 */
export async function getMochItemMeta(id, type, config) {
  const [prefix, itemId] = id.split(':');
  const entry            = findMochByShortId(prefix);
  if (!entry) return null;

  const { moch, module } = entry;
  const apiKey = config[moch.configKey];

  if (!isValidToken(apiKey, MIN_API_KEY_LENGTH)) return null;

  // Basic meta – extend individual modules if richer data is needed
  return { id, type, name: `${moch.name} item ${itemId}` };
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getEnabledMochs(config) {
  return Object.entries(MochOptions)
    .filter(([, moch]) => isValidToken(config?.[moch.configKey], MIN_API_KEY_LENGTH))
    .map(([key, moch]) => ({ key, moch, module: MOCH_MODULES[key] }))
    .filter(({ module }) => !!module);
}

function findMochByShortId(shortId) {
  const entry = Object.entries(MochOptions).find(([, m]) => m.id === shortId);
  if (!entry) return null;
  const [key, moch] = entry;
  return { key, moch, module: MOCH_MODULES[key] };
}

function schedulePrewarm(streams, cachedMap, apiKey, moch, module, config) {
  if (!config?.prewarmDebrid) return;
  if (typeof module.prewarm !== 'function') return;

  const limit = Math.max(0, Math.min(config.prewarmLimit ?? 3, 10));
  if (!limit) return;

  const candidates = pickPrewarmCandidates(streams, cachedMap, limit);
  for (const stream of candidates) {
    const queueId = `prewarm:${moch.id}:${stream.infoHash}:${stream.fileIdx ?? 0}`;
    setTimeout(() => {
      PREWARM_QUEUE.wrap({ id: queueId }, async () => {
        const cacheKey = `prewarm:${moch.id}:${stream.infoHash}:${stream.fileIdx ?? 0}`;
        if (await cacheGet(cacheKey)) return true;

        const warmed = await module.prewarm(stream, apiKey);
        if (warmed) {
          await cacheSet(cacheKey, true, PREWARM_CACHE_TTL);
          logger.info(`Prewarmed ${moch.name} torrent ${stream.infoHash}`);
        }

        return warmed;
      }).catch(err => {
        logger.warn(`Prewarm failed [${moch.name} ${stream.infoHash}]: ${err.message}`);
      });
    }, 0);
  }
}

export function pickPrewarmCandidates(streams, cachedMap, limit) {
  const picked = [];
  const seen = new Set();

  for (const stream of streams) {
    const infoHash = stream.infoHash?.toLowerCase();
    if (!infoHash) continue;
    if (cachedMap.has(infoHash)) continue;

    const key = `${infoHash}:${stream.fileIdx ?? 0}`;
    if (seen.has(key)) continue;

    picked.push(stream);
    seen.add(key);

    if (picked.length >= limit) break;
  }

  return picked;
}
