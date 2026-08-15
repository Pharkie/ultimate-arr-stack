import axios from 'axios';
import { isValidToken, blacklistToken, selectVideoFile, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const DL_BASE = 'https://debrid-link.com/api/v2';

// ─── Public API ───────────────────────────────────────────────────────────────

export async function getCachedStreams(streams, apiKey) {
  if (!isValidToken(apiKey)) return new Map();
  // DebridLink does not provide a bulk instant-availability endpoint;
  // we return an empty map and rely on on-demand resolution.
  return new Map();
}

export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `dl:resolve:${stream.infoHash}:${stream.fileIdx ?? 0}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

export async function prewarm(stream, apiKey) {
  if (!isValidToken(apiKey)) return false;

  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data } = await dlPost(`${DL_BASE}/seedbox/add`, apiKey, { url: magnet, async: true });
    return !!(data.success && data.value?.id);
  } catch (err) {
    handleDlError(err, apiKey);
    return false;
  }
}

export async function getCatalog(apiKey, type, skip = 0) {
  if (!isValidToken(apiKey)) return [];

  try {
    const { data } = await dlGet(`${DL_BASE}/seedbox/list`, apiKey, { perPage: 25, page: Math.floor(skip / 25) + 1 });
    return (data.value ?? []).map(t => ({
      id:          `dl:${t.id}`,
      type,
      name:        t.name,
      poster:      null,
      description: `Size: ${(t.totalSize / 1024 ** 3).toFixed(1)} GB`,
    }));
  } catch (err) {
    handleDlError(err, apiKey);
    return [];
  }
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data: addData } = await dlPost(`${DL_BASE}/seedbox/add`, apiKey, { url: magnet, async: false });

    if (!addData.success) return null;

    const torrentId = addData.value?.id;
    if (!torrentId) return null;

    const info  = await _waitForReady(torrentId, apiKey);
    const files = info?.files ?? [];

    const video = selectVideoFile(files.map(f => ({ name: f.name, size: f.size, url: f.downloadUrl })));
    return video?.url ?? files[0]?.downloadUrl ?? null;
  } catch (err) {
    handleDlError(err, apiKey);
    return null;
  }
}

async function _waitForReady(torrentId, apiKey, retries = 10, delayMs = 2000) {
  for (let i = 0; i < retries; i++) {
    const { data } = await dlGet(`${DL_BASE}/seedbox/${torrentId}/files`, apiKey);
    if (data.success && data.value?.files?.length) return data.value;
    await sleep(delayMs);
  }
  return null;
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function dlGet(url, apiKey, params = {}) {
  return axios.get(url, {
    headers: { Authorization: `Bearer ${apiKey}` },
    params,
    timeout: 15_000,
  });
}

function dlPost(url, apiKey, data = {}) {
  return axios.post(url, data, {
    headers: { Authorization: `Bearer ${apiKey}` },
    timeout: 15_000,
  });
}

function handleDlError(err, apiKey) {
  if (err.response?.status === 401) blacklistToken(apiKey);
  logger.warn(`DebridLink error: ${err.message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
