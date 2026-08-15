import axios from 'axios';
import { isValidToken, blacklistToken, selectVideoFile, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const TB_BASE = 'https://api.torbox.app/v1/api';

// ─── Public API ───────────────────────────────────────────────────────────────

export async function getCachedStreams(streams, apiKey) {
  if (!isValidToken(apiKey)) return new Map();

  const hashes = streams.map(s => s.infoHash).filter(Boolean);
  if (!hashes.length) return new Map();

  try {
    const { data } = await tbPost(`${TB_BASE}/torrents/checkcached`, apiKey, { hash: hashes });
    if (!data.success) return new Map();

    const result = new Map();
    for (const [hash, isCached] of Object.entries(data.data ?? {})) {
      if (isCached) result.set(hash.toLowerCase(), true);
    }
    return result;
  } catch (err) {
    handleTbError(err, apiKey);
    return new Map();
  }
}

export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `tb:resolve:${stream.infoHash}:${stream.fileIdx ?? 0}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

export async function prewarm(stream, apiKey) {
  if (!isValidToken(apiKey)) return false;

  try {
    const { data } = await tbPost(`${TB_BASE}/torrents/createtorrent`, apiKey, {
      magnet: `magnet:?xt=urn:btih:${stream.infoHash}`,
    });

    return !!(data.success && data.data?.torrent_id);
  } catch (err) {
    handleTbError(err, apiKey);
    return false;
  }
}

export async function getCatalog(apiKey, type, skip = 0) {
  if (!isValidToken(apiKey)) return [];

  try {
    const { data } = await tbGet(`${TB_BASE}/torrents/mylist`, apiKey, { limit: 25, offset: skip });
    if (!data.success) return [];
    return (data.data ?? []).map(t => ({
      id:          `tb:${t.id}`,
      type,
      name:        t.name,
      poster:      null,
      description: `Size: ${(t.size / 1024 ** 3).toFixed(1)} GB | Status: ${t.download_state}`,
    }));
  } catch (err) {
    handleTbError(err, apiKey);
    return [];
  }
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    // Create or locate the torrent
    const { data: addData } = await tbPost(`${TB_BASE}/torrents/createtorrent`, apiKey, {
      magnet: `magnet:?xt=urn:btih:${stream.infoHash}`,
    });

    if (!addData.success) return null;

    const torrentId = addData.data?.torrent_id;
    if (!torrentId) return null;

    // Wait for ready state
    const info = await _waitForReady(torrentId, apiKey);
    if (!info) return null;

    const files = info.files ?? [];
    const video = selectVideoFile(files.map(f => ({
      name: f.short_name ?? f.name,
      size: f.size,
      id:   f.id,
    })));

    const fileId = video?.id ?? files[0]?.id;
    if (!fileId) return null;

    // Request direct download URL
    const { data: dlData } = await tbGet(`${TB_BASE}/torrents/requestdl`, apiKey, {
      torrent_id: torrentId,
      file_id:    fileId,
      zip_link:   false,
    });

    return dlData.data ?? null;
  } catch (err) {
    handleTbError(err, apiKey);
    return null;
  }
}

async function _waitForReady(torrentId, apiKey, retries = 10, delayMs = 2000) {
  for (let i = 0; i < retries; i++) {
    const { data } = await tbGet(`${TB_BASE}/torrents/mylist`, apiKey, { id: torrentId });
    const torrent  = data.data?.[0];
    if (!torrent) return null;
    if (torrent.download_state === 'completed') return torrent;
    if (['error', 'dead'].includes(torrent.download_state)) return null;
    await sleep(delayMs);
  }
  return null;
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function tbGet(url, apiKey, params = {}) {
  return axios.get(url, {
    headers: { Authorization: `Bearer ${apiKey}` },
    params,
    timeout: 15_000,
  });
}

function tbPost(url, apiKey, data = {}) {
  return axios.post(url, data, {
    headers: { Authorization: `Bearer ${apiKey}` },
    timeout: 15_000,
  });
}

function handleTbError(err, apiKey) {
  if ([401, 403].includes(err.response?.status)) blacklistToken(apiKey);
  logger.warn(`TorBox error: ${err.message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
