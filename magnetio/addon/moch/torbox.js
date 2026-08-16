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
    // checkcached is a GET with a comma-joined hash= query param and
    // format=list (confirmed live 2026-08-16 - the previous POST with a
    // {hash: [...]} body 422'd, TorBox's schema requires "hashes" via GET,
    // not a POST body). Response data is a list of cached torrents, not a
    // hash->bool map - absence from the list means not cached.
    const { data } = await tbGet(`${TB_BASE}/torrents/checkcached`, apiKey, {
      hash: hashes.join(','),
      format: 'list',
    });
    if (!data.success) return new Map();

    const result = new Map();
    for (const entry of data.data ?? []) {
      if (entry.hash) result.set(entry.hash.toLowerCase(), true);
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
    const { data } = await tbCreateTorrent(apiKey, stream.infoHash);
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
    const { data: addData } = await tbCreateTorrent(apiKey, stream.infoHash);
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
    if (fileId == null) return null;

    // Request direct download URL - requestdl needs the key both as the
    // usual Authorization header AND as a "token" query param (confirmed
    // live 2026-08-16: without token it 422s with "field required").
    const { data: dlData } = await tbGet(`${TB_BASE}/torrents/requestdl`, apiKey, {
      token:      apiKey,
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
    // mylist?id=<id> returns a single torrent object, not a list (only the
    // no-id "list everything" mode returns an array - confirmed live
    // 2026-08-16).
    const { data } = await tbGet(`${TB_BASE}/torrents/mylist`, apiKey, { id: torrentId });
    const torrent  = data.data;
    if (!torrent) return null;
    // A torrent already on TorBox's servers reports "cached", not
    // "completed" - "completed" never actually occurs (confirmed live
    // 2026-08-16, this previously made every resolve() time out).
    if (['cached', 'completed'].includes(torrent.download_state)) return torrent;
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

// createtorrent rejects a JSON body ("must provide either a file or magnet
// link" even when magnet is present) - it needs form-encoded data instead
// (confirmed live 2026-08-16). axios sets the right Content-Type
// automatically for a URLSearchParams body.
function tbCreateTorrent(apiKey, infoHash) {
  const body = new URLSearchParams({ magnet: `magnet:?xt=urn:btih:${infoHash}` });
  return axios.post(`${TB_BASE}/torrents/createtorrent`, body, {
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
