import axios from 'axios';
import { isValidToken, blacklistToken, selectVideoFile, resolveWithCache } from './mochHelper.js';
import { logger } from '../lib/logger.js';

const PU_BASE = 'https://api.put.io/v2';

// ─── Public API ───────────────────────────────────────────────────────────────

export async function getCachedStreams(streams, apiKey) {
  // Put.io doesn't expose a cache-check endpoint; use on-demand resolution.
  return new Map();
}

export async function resolve(stream, apiKey) {
  if (!isValidToken(apiKey)) return null;

  const cacheKey = `pu:resolve:${stream.infoHash}:${stream.fileIdx ?? 0}`;
  return resolveWithCache(cacheKey, () => _resolve(stream, apiKey));
}

export async function prewarm(stream, apiKey) {
  if (!isValidToken(apiKey)) return false;

  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data } = await puPost(`${PU_BASE}/transfers/add`, apiKey, { url: magnet });
    return !!data.transfer;
  } catch (err) {
    handlePuError(err, apiKey);
    return false;
  }
}

export async function getCatalog(apiKey, type, skip = 0) {
  if (!isValidToken(apiKey)) return [];

  try {
    const { data } = await puGet(`${PU_BASE}/transfers/list`, apiKey);
    const transfers = (data.transfers ?? []).slice(skip, skip + 25);
    return transfers.map(t => ({
      id:          `pu:${t.id}`,
      type,
      name:        t.name,
      poster:      null,
      description: `Size: ${(t.size / 1024 ** 3).toFixed(1)} GB | Status: ${t.status}`,
    }));
  } catch (err) {
    handlePuError(err, apiKey);
    return [];
  }
}

// ─── Internal ─────────────────────────────────────────────────────────────────

async function _resolve(stream, apiKey) {
  try {
    const magnet = `magnet:?xt=urn:btih:${stream.infoHash}`;
    const { data: addData } = await puPost(`${PU_BASE}/transfers/add`, apiKey, { url: magnet });

    if (!addData.transfer) return null;

    const transferId = addData.transfer.id;
    const fileId     = await _waitForFile(transferId, stream.fileIdx, apiKey);
    if (!fileId) return null;

    const { data: urlData } = await puGet(`${PU_BASE}/files/${fileId}/url`, apiKey);
    return urlData.url ?? null;
  } catch (err) {
    handlePuError(err, apiKey);
    return null;
  }
}

async function _waitForFile(transferId, fileIdx, apiKey, retries = 12, delayMs = 2500) {
  for (let i = 0; i < retries; i++) {
    const { data } = await puGet(`${PU_BASE}/transfers/${transferId}`, apiKey);
    const transfer = data.transfer;

    if (transfer?.status === 'SEEDING' || transfer?.status === 'COMPLETED') {
      const folderId = transfer.file_id;
      if (!folderId) return null;

      const { data: filesData } = await puGet(`${PU_BASE}/files/list`, apiKey, { parent_id: folderId });
      const files = filesData.files ?? [];

      const video = fileIdx != null && files[fileIdx]
        ? files[fileIdx]
        : selectVideoFile(files.map(f => ({ name: f.name, size: f.size, id: f.id })));

      return video?.id ?? null;
    }

    if (['ERROR', 'IN_QUEUE', 'CANCELLED'].includes(transfer?.status ?? '')) return null;
    await sleep(delayMs);
  }
  return null;
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function puGet(url, apiKey, params = {}) {
  return axios.get(url, {
    params:  { oauth_token: apiKey, ...params },
    timeout: 15_000,
  });
}

function puPost(url, apiKey, data = {}) {
  const form = new URLSearchParams({ oauth_token: apiKey, ...data });
  return axios.post(url, form.toString(), {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    timeout: 20_000,
  });
}

function handlePuError(err, apiKey) {
  if (err.response?.status === 401) blacklistToken(apiKey);
  logger.warn(`Put.io error: ${err.message}`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}
