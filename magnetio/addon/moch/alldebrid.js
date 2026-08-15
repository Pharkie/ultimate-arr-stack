import axios from 'axios';
import { isValidToken, blacklistToken, selectVideoFile, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const AD_BASE  = 'https://api.alldebrid.com/v4';
const APP_NAME = 'magnetio';

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Check which infoHashes are cached on AllDebrid.
 * Returns a Map<infoHash, true>.
 */
export async function getCachedStreams(streams, apiKey) {
  if (!isValidToken(apiKey)) return new Map();

  const hashes = streams.map(s => s.infoHash).filter(Boolean);
  if (!hashes.length) return new Map();

  try {
    const params = new URLSearchParams({ agent: APP_NAME, apikey: apiKey });
    hashes.forEach(h => params.append('magnets[]', `magnet:?xt=urn:btih:${h}`));

    const { data } = await axios.post(`${AD_BASE}/magnet/instant`, params.toString(), {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      timeout: 15_000,
    });

    if (data.status !== 'success') return new Map();

    const result = new Map();
    (data.data?.magnets ?? []).forEach(m => {
      if (m.instant) result.set(m.hash?.toLowerCase(), true);
    });
    return result;
  } catch (err) {
    handleAdError(err, apiKey);
    return new Map();
  }
}

/**
 * Resolve a torrent to a direct AllDebrid download URL.
 */
export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `ad:resolve:${stream.infoHash}:${stream.fileIdx ?? 0}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

export async function prewarm(stream, apiKey) {
  if (!isValidToken(apiKey)) return false;

  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data } = await adGet(`${AD_BASE}/magnet/upload`, apiKey, { magnet });
    return data.status === 'success';
  } catch (err) {
    handleAdError(err, apiKey);
    return false;
  }
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data } = await adGet(`${AD_BASE}/magnet/upload`, apiKey, { magnet });

    if (data.status !== 'success') return null;

    const magnetId = data.data?.magnets?.[0]?.id;
    if (!magnetId) return null;

    // Wait for it to be processed
    const info = await _waitForReady(magnetId, apiKey);
    if (!info?.links?.length) return null;

    const videoLink = selectVideoFile(info.links.map(l => ({ name: l.filename, size: l.size, url: l.link })));
    const targetLink = videoLink?.url ?? info.links[0]?.link;

    if (!targetLink) return null;

    // Unrestrict the link
    const { data: unlockData } = await adGet(`${AD_BASE}/link/unlock`, apiKey, { link: targetLink });
    return unlockData.data?.link ?? null;
  } catch (err) {
    handleAdError(err, apiKey);
    return null;
  }
}

async function _waitForReady(magnetId, apiKey, retries = 8, delayMs = 2500) {
  for (let i = 0; i < retries; i++) {
    const { data } = await adGet(`${AD_BASE}/magnet/status`, apiKey, { id: magnetId });
    const magnet   = data.data?.magnets?.[0];
    if (!magnet) return null;
    if (magnet.status === 'Ready') return magnet;
    if (['Error', 'Deleted'].includes(magnet.status)) return null;
    await sleep(delayMs);
  }
  return null;
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function adGet(url, apiKey, params = {}) {
  return axios.get(url, {
    params:  { agent: APP_NAME, apikey: apiKey, ...params },
    timeout: 15_000,
  });
}

function handleAdError(err, apiKey) {
  const errCode = err.response?.data?.error?.code;
  if (['AUTH_BAD_APIKEY', 'AUTH_BLOCKED', 'AUTH_USER_BANNED'].includes(errCode)) {
    blacklistToken(apiKey);
  }
  logger.warn(`AllDebrid error (${errCode ?? 'unknown'}): ${err.message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
