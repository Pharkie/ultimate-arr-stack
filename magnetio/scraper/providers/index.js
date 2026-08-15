/**
 * Provider aggregator -- runs all enabled scrapers in parallel
 * and returns a unified, deduplicated list of torrent records.
 */
import pLimit from 'p-limit';
import * as yts              from './yts.js';
import * as eztv             from './eztv.js';
import * as thepiratebay     from './thepiratebay.js';
import * as torrentgalaxy    from './torrentgalaxy.js';
import * as leetx            from './leetx.js';
import * as kickasstorrents  from './kickasstorrents.js';
import * as nyaa             from './nyaa.js';
import * as animesaturn      from './animesaturn.js';
import * as rutor            from './rutor.js';
import * as rutracker        from './rutracker.js';
import * as limetorrents     from './limetorrents.js';
import * as bitsearch        from './bitsearch.js';
import * as bt4g             from './bt4g.js';
import * as btdig            from './btdig.js';
import * as glotorrents      from './glotorrents.js';
import * as torlock          from './torlock.js';
import * as torrentdownloads from './torrentdownloads.js';
import * as therarbg         from './therarbg.js';
import * as subsplease       from './subsplease.js';
import * as animetosho       from './animetosho.js';
import * as nekobt           from './nekobt.js';
import * as torznab          from './torznab.js';
import { logger } from '../lib/logger.js';

const ALL_PROVIDERS = [
  yts,
  eztv,
  thepiratebay,
  torrentgalaxy,
  leetx,
  kickasstorrents,
  nyaa,
  animesaturn,
  rutor,
  rutracker,
  limetorrents,
  bitsearch,
  bt4g,
  btdig,
  glotorrents,
  torlock,
  torrentdownloads,
  therarbg,
  subsplease,
  animetosho,
  nekobt,
  torznab,
];

const limit = pLimit(Math.max(1, parseInt(process.env.SCRAPER_CONCURRENCY ?? '12', 10) || 12));
const PROVIDER_TIMEOUT_MS = parseInt(process.env.SCRAPER_PROVIDER_TIMEOUT_MS ?? '15000', 10);
const HARD_TIMEOUT_MS     = parseInt(process.env.SCRAPER_HARD_TIMEOUT_MS     ?? String(PROVIDER_TIMEOUT_MS + 2000), 10);
const EARLY_RETURN_MS     = parseInt(process.env.SCRAPER_EARLY_RETURN_MS     ?? '3000', 10);
const MIN_EARLY_RESULTS   = parseInt(process.env.SCRAPER_MIN_EARLY_RESULTS   ?? '3', 10);

/**
 * Scrape all (or a subset of) providers for a given content item.
 * Uses early-return: responds after EARLY_RETURN_MS if enough results
 * are collected, without waiting for slow providers.
 *
 * @param {string}   type        'movie' | 'series' | 'anime'
 * @param {object}   meta        From cinemeta: { name, year, imdbId, season, episode }
 * @param {string[]} providerIds Optional whitelist of provider IDs
 * @param {object}   context     Optional per-request context (e.g. { torznabUrl, torznabApiKey })
 * @returns {Promise<TorrentRecord[]>}
 */
export async function scrapeAll(type, meta, providerIds = null, context = {}) {
  const providers = ALL_PROVIDERS.filter(p =>
    !providerIds || providerIds.includes(p.id)
  );

  const collected = [];
  let resolved = false;
  let completedCount = 0;

  return new Promise((resolve) => {
    const finalize = () => {
      if (resolved) return;
      resolved = true;
      clearTimeout(earlyTimer);
      clearTimeout(hardTimer);

      logger.info(`Scrape totals: ${collected.length} raw, ${completedCount}/${providers.length} providers responded`);
      const deduped = deduplicate(collected);
      const matched = filterByContent(deduped, meta);
      if (deduped.length !== matched.length) {
        logger.info(`Content filter: ${deduped.length} -> ${matched.length} (dropped ${deduped.length - matched.length} unrelated)`);
      }
      resolve(matched);
    };

    // Early return: after EARLY_RETURN_MS, return if we have enough results
    const earlyTimer = setTimeout(() => {
      if (!resolved && collected.length >= MIN_EARLY_RESULTS) {
        logger.info(`Early return: ${collected.length} results from ${completedCount}/${providers.length} providers after ${EARLY_RETURN_MS}ms`);
        finalize();
      }
    }, EARLY_RETURN_MS);

    // Hard deadline: cut off after HARD_TIMEOUT_MS even if providers are still pending
    const hardTimer = setTimeout(() => {
      if (!resolved) {
        logger.info(`Hard timeout: ${collected.length} results from ${completedCount}/${providers.length} providers after ${HARD_TIMEOUT_MS}ms`);
        finalize();
      }
    }, HARD_TIMEOUT_MS);

    // Launch all providers in parallel (concurrency-limited)
    const tasks = providers.map(p =>
      limit(async () => {
        if (resolved) return;
        const start = Date.now();
        try {
          const results = await withTimeout(
            p.scrape({ ...meta, ...context, type }),
            PROVIDER_TIMEOUT_MS,
            `${p.name} timed out`
          );
          logger.info(`[${p.name}] ${results.length} results in ${Date.now() - start}ms`);
          collected.push(...results);
        } catch (err) {
          logger.warn(`[${p.name}] ${err.message} (${Date.now() - start}ms)`);
        } finally {
          completedCount++;
          // If all providers finished, return immediately
          if (completedCount >= providers.length) finalize();
        }
      })
    );

    // Safety: if Promise.all somehow resolves before timers
    Promise.allSettled(tasks).then(finalize);
  });
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
 * Deduplicate by infoHash, keeping the entry with the highest seeder count.
 */
function deduplicate(records) {
  const map = new Map();
  for (const r of records) {
    if (!r.infoHash) continue;
    const existing = map.get(r.infoHash);
    if (!existing || (r.seeders ?? 0) > (existing.seeders ?? 0)) {
      map.set(r.infoHash, r);
    }
  }
  return Array.from(map.values());
}

/**
 * Filter out torrents whose title does not match the requested content.
 * For series: title must contain a season/episode marker matching the request.
 * For movies: title must contain at least part of the movie name.
 */
function filterByContent(records, meta) {
  if (!meta?.name) return records;

  const nameWords = normalizeTitle(meta.name).split(/\s+/).filter(w => w.length > 1);
  if (!nameWords.length) return records;

  const phrasePattern = nameWords.map(escapeRegex).join('\\s+');
  const phraseRegex = new RegExp(`\\b${phrasePattern}\\b`);

  return records.filter(r => {
    if (!r.title) return false;
    const norm = normalizeTitle(r.title);

    if (nameWords.length <= 2) {
      const match = phraseRegex.exec(norm);
      if (!match) return false;
      const after = norm.slice(match.index + match[0].length).trim();
      const nextWord = after.match(/^([a-z0-9]+)/);
      if (nextWord && !isTorrentMetadata(nextWord[1])) return false;
    } else {
      const matchCount = nameWords.filter(w =>
        new RegExp(`\\b${escapeRegex(w)}\\b`).test(norm)
      ).length;
      if (matchCount < Math.max(1, Math.ceil(nameWords.length * 0.5))) return false;
    }

    if (meta.type === 'series' && meta.season != null) {
      const s = meta.season;
      const e = meta.episode;
      const hasSeasonEp = new RegExp(
        e != null
          ? `s0*${s}\\s*e0*${e}\\b`
          : `s0*${s}(e\\d|\\b)`,
        'i'
      ).test(r.title);
      const hasLooseEp = e != null && new RegExp(
        `\\b${s}x0*${e}\\b`, 'i'
      ).test(r.title);
      const hasSeasonPack = new RegExp(
        `\\bseason\\s*0*${s}\\b|\\bcomplete\\b.*\\bs0*${s}\\b`,
        'i'
      ).test(r.title);
      if (!hasSeasonEp && !hasLooseEp && !hasSeasonPack) return false;
    }

    return true;
  });
}

function isTorrentMetadata(word) {
  return /^(s\d|season|episode|ep\d|web|hdtv|bluray|bdrip|dvd|hdrip|cam|x26|h26|hevc|avc|xvid|aac|ac3|dts|multi|dual|repack|proper|internal|extended|unrated|complete|full|part|the)/.test(word)
    || /^\d/.test(word);
}

function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeTitle(str) {
  return str
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * List all available provider IDs.
 */
export function listProviders() {
  return ALL_PROVIDERS.map(p => ({ id: p.id, name: p.name }));
}
