import axios from 'axios';
import { isValidToken, blacklistToken, selectVideoFile, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const PM_BASE = 'https://www.premiumize.me/api';

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Check cached availability for a list of infoHashes on Premiumize.
 * Returns a Map<infoHash, true>.
 */
export async function getCachedStreams(streams, apiKey) {
  if (!isValidToken(apiKey)) return new Map();

  const hashes = streams.map(s => s.infoHash).filter(Boolean);
  if (!hashes.length) return new Map();

  try {
    const params = new URLSearchParams({ apikey: apiKey });
    hashes.forEach(h => params.append('items[][src]', `magnet:?xt=urn:btih:${h}`));

    const { data } = await axios.post(`${PM_BASE}/cache/check`, params.toString(), {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      timeout: 15_000,
    });

    if (data.status !== 'success') return new Map();

    const result = new Map();
    (data.response ?? []).forEach((cached, i) => {
      if (cached) result.set(hashes[i].toLowerCase(), true);
    });
    return result;
  } catch (err) {
    handlePmError(err, apiKey);
    return new Map();
  }
}

/**
 * Resolve a torrent to a direct Premiumize download URL.
 */
export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `pm:resolve:${stream.infoHash}:${stream.fileIdx ?? 0}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

/**
 * Fetch the user's Premiumize transfers/downloads for catalog display.
 */
export async function getCatalog(apiKey, type, skip = 0) {
  if (!isValidToken(apiKey)) return [];

  try {
    const { data } = await pmGet(`${PM_BASE}/transfer/list`, apiKey);
    if (data.status !== 'success') return [];

    const transfers = (data.transfers ?? []).slice(skip, skip + 25);
    return transfers.map(t => ({
      id:          `pm:${t.id}`,
      type,
      name:        t.name,
      poster:      null,
      description: `Status: ${t.status}`,
    }));
  } catch (err) {
    handlePmError(err, apiKey);
    return [];
  }
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data } = await pmPost(`${PM_BASE}/transfer/directdl`, apiKey, { src: magnet });

    if (data.status !== 'success') return null;

    const content = data.content ?? [];
    const video   = selectVideoFile(content.map(f => ({ name: f.path, size: f.size, url: f.link })));
    return video?.url ?? content[0]?.link ?? null;
  } catch (err) {
    handlePmError(err, apiKey);
    return null;
  }
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function pmGet(url, apiKey, params = {}) {
  return axios.get(url, {
    params:  { apikey: apiKey, ...params },
    timeout: 15_000,
  });
}

function pmPost(url, apiKey, data = {}) {
  const form = new URLSearchParams({ apikey: apiKey, ...data });
  return axios.post(url, form.toString(), {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    timeout: 15_000,
  });
}

function handlePmError(err, apiKey) {
  if (err.response?.status === 401 || err.response?.data?.status === 'error') {
    logger.warn(`Premiumize auth error – blacklisting token`);
    blacklistToken(apiKey);
  } else {
    logger.warn(`Premiumize error: ${err.message}`);
  }
}
