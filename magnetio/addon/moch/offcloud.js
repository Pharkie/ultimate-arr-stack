import axios from 'axios';
import { isValidToken, blacklistToken, selectVideoFile, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const OC_BASE = 'https://offcloud.com/api';

// ─── Public API ───────────────────────────────────────────────────────────────

export async function getCachedStreams(streams, apiKey) {
  if (!isValidToken(apiKey)) return new Map();
  // Offcloud does not expose a bulk cache-check; return empty.
  return new Map();
}

export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `oc:resolve:${stream.infoHash}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

export async function prewarm(stream, apiKey) {
  if (!isValidToken(apiKey)) return false;

  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data } = await axios.post(
      `${OC_BASE}/cloud`,
      { url: magnet },
      { params: { key: apiKey }, timeout: 20_000 }
    );

    return !!data.requestId;
  } catch (err) {
    handleOcError(err, apiKey);
    return false;
  }
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data: addData } = await axios.post(
      `${OC_BASE}/cloud`,
      { url: magnet },
      { params: { key: apiKey }, timeout: 20_000 }
    );

    if (!addData.requestId) return null;

    const requestId = addData.requestId;
    const info      = await _waitForReady(requestId, apiKey);
    const files     = info?.files ?? [];

    const video = selectVideoFile(files.map(f => ({ name: f.fileName, size: f.size, url: f.url })));
    return video?.url ?? files[0]?.url ?? null;
  } catch (err) {
    handleOcError(err, apiKey);
    return null;
  }
}

async function _waitForReady(requestId, apiKey, retries = 12, delayMs = 3000) {
  for (let i = 0; i < retries; i++) {
    const { data } = await axios.get(
      `${OC_BASE}/cloud/status`,
      { params: { key: apiKey, requestId }, timeout: 15_000 }
    );
    if (data.status === 'downloaded') return data;
    if (data.status === 'error') return null;
    await sleep(delayMs);
  }
  return null;
}

// ─── Error handling ───────────────────────────────────────────────────────────

function handleOcError(err, apiKey) {
  if (err.response?.status === 403) blacklistToken(apiKey);
  logger.warn(`Offcloud error: ${err.message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
