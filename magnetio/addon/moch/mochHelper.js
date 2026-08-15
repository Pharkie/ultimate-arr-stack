import { cacheWrap } from '../lib/cache.js';
import { logger } from '../lib/logger.js';

// Token blacklist: keys that have previously returned auth-failure errors
const _blacklist = new Set();

/**
 * Wrap a debrid resolution call in a timeout + cache layer.
 *
 * @param {string}   cacheKey
 * @param {Function} resolver   async () => url | null
 * @param {number}   ttl        cache TTL in seconds
 * @param {number}   timeoutMs
 */
export async function resolveWithCache(cacheKey, resolver, ttl = 3600, timeoutMs = 120_000) {
  return cacheWrap(cacheKey, () => raceTimeout(resolver, timeoutMs), ttl);
}

/**
 * Run an async function with a hard timeout.
 * Returns null on timeout instead of throwing.
 */
export async function raceTimeout(fn, ms = 120_000) {
  return Promise.race([
    fn(),
    new Promise(resolve => setTimeout(() => resolve(null), ms)),
  ]);
}

/** Mark an API key as invalid so we skip it for future requests. */
export function blacklistToken(token) {
  _blacklist.add(token);
  logger.warn(`Debrid token blacklisted (too many errors or auth failure)`);
}

/** Returns true if the token has been blacklisted. */
export function isTokenBlacklisted(token) {
  return _blacklist.has(token);
}

/**
 * Validate an API key string.
 * Keys must be a non-empty string of at least 15 characters and not blacklisted.
 */
export function isValidToken(token, minLength = 15) {
  return (
    typeof token === 'string' &&
    token.length >= minLength &&
    !isTokenBlacklisted(token)
  );
}

/**
 * Select video files from a list of torrent file entries.
 * Returns the file most likely to be the main video (largest video file).
 */
export function selectVideoFile(files) {
  const VIDEO_EXTS = /\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$/i;

  const videos = files.filter(f => VIDEO_EXTS.test(f.name ?? f.path ?? ''));
  if (!videos.length) return null;

  // Pick the largest video file
  return videos.reduce((a, b) => (a.size ?? 0) >= (b.size ?? 0) ? a : b);
}

/**
 * Build a standardised stream object for a resolved debrid URL.
 */
export function buildDebridStream(baseStream, url, serviceName) {
  const title = `${baseStream.title ?? ''}\n🔗 Direct link via ${serviceName}`.trim();
  const behaviorHints = {
    ...(baseStream.behaviorHints ?? {}),
    notWebReady: !isWebReadyUrl(url),
  };

  return {
    url,
    name:  `${baseStream.name ?? '⚡ Magnetio'}\n[${serviceName}]`,
    title,
    behaviorHints,
  };
}

function isWebReadyUrl(url) {
  if (!/^https:\/\//i.test(url)) return false;
  return /\.(mp4|m4v)(?:$|[?#])/i.test(url);
}
