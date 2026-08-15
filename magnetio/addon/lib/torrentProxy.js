import torrentStream from 'torrent-stream';
import { logger } from './logger.js';
import { getBestTrackers } from './magnetHelper.js';
import path from 'path';

const MAX_ENGINES = Math.max(1, parseInt(process.env.PROXY_MAX_ENGINES ?? '3', 10) || 3);
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const DOWNLOAD_PATH = process.env.PROXY_DOWNLOAD_PATH || '/tmp/magnetio-torrents';
const PROXY_SOCKS = process.env.TORRENT_PROXY || null;

const engines = new Map();

function buildMagnet(infoHash, trackers = []) {
  let uri = `magnet:?xt=urn:btih:${infoHash}`;
  for (const t of trackers) uri += `&tr=${encodeURIComponent(t)}`;
  return uri;
}

function buildEngineOpts(proxyUrl) {
  const opts = { path: DOWNLOAD_PATH, connections: 30, uploads: 0, verify: false };
  const socks = proxyUrl || PROXY_SOCKS;
  if (socks) {
    try {
      const url = new URL(socks);
      opts.tracker = {
        proxy: { host: url.hostname, port: parseInt(url.port, 10) || 1080 },
      };
    } catch {}
  }
  return opts;
}

function getOrCreateEngine(infoHash, trackers, proxyUrl) {
  const engineKey = proxyUrl ? `${infoHash}:${proxyUrl}` : infoHash;
  const existing = engines.get(engineKey);
  if (existing) {
    existing.lastAccess = Date.now();
    return { entry: existing, engineKey };
  }

  while (engines.size >= MAX_ENGINES) {
    let oldest = null;
    for (const [key, entry] of engines) {
      if (!oldest || entry.lastAccess < oldest.lastAccess) oldest = { key, entry };
    }
    if (oldest) destroyEngine(oldest.key);
  }

  const magnet = buildMagnet(infoHash, trackers);
  const engine = torrentStream(magnet, buildEngineOpts(proxyUrl));

  const entry = {
    engine,
    ready: false,
    readyPromise: null,
    lastAccess: Date.now(),
    idleTimer: null,
  };

  entry.readyPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Engine timeout')), 60_000);
    engine.on('ready', () => {
      clearTimeout(timeout);
      entry.ready = true;
      resolve();
    });
    engine.on('error', (err) => {
      clearTimeout(timeout);
      reject(err);
    });
  });

  resetIdleTimer(engineKey, entry);
  engines.set(engineKey, entry);
  logger.info(`Torrent engine started: ${infoHash} (${engines.size}/${MAX_ENGINES})`);
  return { entry, engineKey };
}

function resetIdleTimer(infoHash, entry) {
  if (entry.idleTimer) clearTimeout(entry.idleTimer);
  entry.idleTimer = setTimeout(() => destroyEngine(infoHash), IDLE_TIMEOUT_MS);
}

function destroyEngine(infoHash) {
  const entry = engines.get(infoHash);
  if (!entry) return;
  if (entry.idleTimer) clearTimeout(entry.idleTimer);
  try { entry.engine.destroy(); } catch {}
  engines.delete(infoHash);
  logger.info(`Torrent engine destroyed: ${infoHash} (${engines.size}/${MAX_ENGINES})`);
}

function selectFile(engine, fileIdx) {
  if (fileIdx != null && fileIdx < engine.files.length) {
    return engine.files[fileIdx];
  }
  const files = [...engine.files].sort((a, b) => b.length - a.length);
  const videoExts = ['.mp4', '.mkv', '.avi', '.m4v', '.webm', '.mov'];
  const video = files.find(f => videoExts.includes(path.extname(f.name).toLowerCase()));
  return video || files[0];
}

export async function streamTorrent(infoHash, fileIdx, req, res, proxyUrl) {
  const { entry, engineKey } = getOrCreateEngine(infoHash, getBestTrackers(), proxyUrl);
  try {
    await entry.readyPromise;
  } catch (err) {
    destroyEngine(engineKey);
    res.status(504).json({ error: 'Torrent engine failed to start' });
    return;
  }

  entry.lastAccess = Date.now();
  resetIdleTimer(engineKey, entry);

  const file = selectFile(entry.engine, fileIdx);
  if (!file) {
    res.status(404).json({ error: 'No suitable file found in torrent' });
    return;
  }

  const ext = path.extname(file.name).toLowerCase();
  const mimeMap = {
    '.mp4': 'video/mp4', '.mkv': 'video/x-matroska', '.avi': 'video/x-msvideo',
    '.m4v': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime',
  };
  const contentType = mimeMap[ext] || 'application/octet-stream';
  const total = file.length;

  const range = req.headers.range;
  if (range) {
    const parts = range.replace(/bytes=/, '').split('-');
    const start = parseInt(parts[0], 10) || 0;
    const end = parts[1] ? parseInt(parts[1], 10) : total - 1;

    if (start >= total || end >= total || start > end || start < 0) {
      res.writeHead(416, { 'Content-Range': `bytes */${total}` });
      res.end();
      return;
    }

    const chunkSize = end - start + 1;

    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${total}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': chunkSize,
      'Content-Type': contentType,
    });

    const stream = file.createReadStream({ start, end });
    stream.pipe(res);
    stream.on('error', () => res.end());
  } else {
    res.writeHead(200, {
      'Content-Length': total,
      'Content-Type': contentType,
      'Accept-Ranges': 'bytes',
    });

    const stream = file.createReadStream();
    stream.pipe(res);
    stream.on('error', () => res.end());
  }

  res.on('close', () => {
    entry.lastAccess = Date.now();
    resetIdleTimer(engineKey, entry);
  });
}

export function destroyAllEngines() {
  for (const key of [...engines.keys()]) destroyEngine(key);
}

export function getEngineCount() {
  return engines.size;
}
