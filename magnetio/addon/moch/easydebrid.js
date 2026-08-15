import axios from 'axios';
import { isValidToken, blacklistToken, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const ED_BASE = 'https://easydebrid.com/api/v1';

// ─── Public API ───────────────────────────────────────────────────────────────

export async function getCachedStreams(streams, apiKey) {
  if (!isValidToken(apiKey)) return new Map();

  const hashes = streams.map(s => s.infoHash).filter(Boolean);
  if (!hashes.length) return new Map();

  try {
    const { data } = await axios.post(
      `${ED_BASE}/link/lookup`,
      { urls: hashes.map(h => `magnet:?xt=urn:btih:${h}`) },
      { headers: { Authorization: `Bearer ${apiKey}` }, timeout: 15_000 }
    );

    const result = new Map();
    (data.cached ?? []).forEach((cached, i) => {
      if (cached) result.set(hashes[i].toLowerCase(), true);
    });
    return result;
  } catch (err) {
    handleEdError(err, apiKey);
    return new Map();
  }
}

export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `ed:resolve:${stream.infoHash}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    const { data } = await axios.post(
      `${ED_BASE}/link/generate`,
      { url: `magnet:?xt=urn:btih:${stream.infoHash}` },
      { headers: { Authorization: `Bearer ${apiKey}` }, timeout: 20_000 }
    );
    return data.url ?? null;
  } catch (err) {
    handleEdError(err, apiKey);
    return null;
  }
}

// ─── Error handling ───────────────────────────────────────────────────────────

function handleEdError(err, apiKey) {
  if (err.response?.status === 401) blacklistToken(apiKey);
  logger.warn(`EasyDebrid error: ${err.message}`);
}
