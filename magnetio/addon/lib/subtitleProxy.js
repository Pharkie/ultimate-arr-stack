import crypto from 'crypto';
import fs from 'fs/promises';
import os from 'os';
import path from 'path';
import { spawn } from 'child_process';
import { cacheGet, cacheSet, cacheWrap } from './cache.js';
import { logger } from './logger.js';
import { getSubtitles, resolveSubtitleLanguages } from './subtitles.js';
import { toSubtitleLanguageCode } from './languages.js';

const BLOCKED_HOSTNAMES = new Set([
  'localhost', '127.0.0.1', '::1', '0.0.0.0',
  'metadata.google.internal', 'metadata.internal',
]);

function isUrlSafe(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
    const host = parsed.hostname;
    if (BLOCKED_HOSTNAMES.has(host)) return false;
    if (host.startsWith('10.')) return false;
    if (host.startsWith('192.168.')) return false;
    if (host.startsWith('169.254.')) return false;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(host)) return false;
    if (host.endsWith('.local') || host.endsWith('.internal')) return false;
    return true;
  } catch {
    return false;
  }
}

const PROXY_PAYLOAD_TTL = 60 * 60 * 12;
const PROXY_RESULT_TTL = 60 * 60 * 24;
const OPENSUBTITLES_HASH_CHUNK_SIZE = 64 * 1024;
const MAX_STREAM_SUBTITLE_LANGUAGES = 3;
const SYNC_TIMEOUT_MS = 1000 * 60 * 4;
const TOOL_CHECK_TIMEOUT_MS = 8_000;

let syncToolCache;

export async function createStreamSubtitleProxies(requestContext, stream, config) {
  if (!stream?.url || !process.env.OPENSUBTITLES_API_KEY) return [];

  const languages = resolveSubtitleLanguages(config).slice(0, MAX_STREAM_SUBTITLE_LANGUAGES);
  if (!languages.length) return [];

  const baseUrl = String(config?._publicBaseUrl || '').replace(/\/$/, '');
  const subtitles = [];

  for (const language of languages) {
    const proxyId = crypto.randomUUID();
    await cacheSet(`subtitle-proxy:${proxyId}`, {
      type: requestContext.type,
      id: requestContext.id,
      language,
      mediaUrl: stream.url,
      filename: stream.behaviorHints?.filename || null,
      videoSize: stream.behaviorHints?.videoSize || null,
    }, PROXY_PAYLOAD_TTL);

    subtitles.push({
      lang: toSubtitleLanguageCode(language),
      url: `${baseUrl}/proxy/subtitle/${proxyId}.srt`,
    });
  }

  return subtitles;
}

export async function handleSubtitleProxyRequest(req, res) {
  const payload = await cacheGet(`subtitle-proxy:${req.params.id}`);
  if (!payload) {
    res.status(404).json({ error: 'Subtitle proxy payload not found or expired' });
    return;
  }

  try {
    const cacheKey = `subtitle-proxy:result:${hashValue(payload)}`;
    const content = await cacheWrap(cacheKey, () => buildSyncedSubtitle(payload), PROXY_RESULT_TTL);

    if (!content) {
      res.status(404).json({ error: 'No subtitles available for this stream' });
      return;
    }

    res.setHeader('content-type', 'application/x-subrip; charset=utf-8');
    res.setHeader('cache-control', 'public, max-age=86400, stale-while-revalidate=604800, stale-if-error=604800');
    res.send(content);
  } catch (err) {
    logger.error(`Subtitle proxy error [${req.params.id}]: ${err.message}`);
    res.status(500).json({ error: 'Subtitle proxy failed' });
  }
}

export async function buildSyncedSubtitle(payload) {
  const mediaMeta = await getMediaMetadata(payload.mediaUrl, payload.videoSize, payload.filename);
  const args = {
    type: payload.type,
    id: payload.id,
    extra: {
      filename: mediaMeta.filename,
      videoHash: mediaMeta.videoHash,
      videoSize: mediaMeta.videoSize,
    },
  };

  const subtitles = await getSubtitles(args, {
    subtitleLanguages: [payload.language],
    languages: [payload.language],
  });

  if (!subtitles.length) return null;

  for (const subtitle of subtitles) {
    const raw = await downloadSubtitleText(subtitle.url);
    if (!raw) continue;

    const synced = await syncSubtitleToMedia(raw, payload.mediaUrl);
    if (synced) return synced;
    return raw;
  }

  return null;
}

export async function getMediaMetadata(mediaUrl, fallbackSize, fallbackFilename) {
  if (!isUrlSafe(mediaUrl)) throw new Error('Blocked unsafe media URL');
  const filename = fallbackFilename || inferFilenameFromUrl(mediaUrl);
  const videoSize = fallbackSize || await getRemoteContentLength(mediaUrl);
  let videoHash = null;

  if (videoSize && videoSize >= OPENSUBTITLES_HASH_CHUNK_SIZE * 2) {
    try {
      const first = await fetchRange(mediaUrl, 0, OPENSUBTITLES_HASH_CHUNK_SIZE - 1);
      const last = await fetchRange(mediaUrl, videoSize - OPENSUBTITLES_HASH_CHUNK_SIZE, videoSize - 1);
      if (first && last) {
        videoHash = computeOpenSubtitlesHashFromBuffers(first, last, videoSize);
      }
    } catch (err) {
      logger.debug(`Could not compute OpenSubtitles hash: ${err.message}`);
    }
  }

  return {
    filename,
    videoSize,
    videoHash,
  };
}

export function computeOpenSubtitlesHashFromBuffers(firstChunk, lastChunk, fileSize) {
  const MOD = 0xffffffffffffffffn;
  let hash = BigInt(fileSize);

  for (const chunk of [firstChunk, lastChunk]) {
    const limit = chunk.length - (chunk.length % 8);
    for (let offset = 0; offset < limit; offset += 8) {
      hash = (hash + chunk.readBigUInt64LE(offset)) & MOD;
    }
  }

  return hash.toString(16).padStart(16, '0');
}

async function syncSubtitleToMedia(subtitleContent, mediaUrl) {
  if (!isUrlSafe(mediaUrl)) return subtitleContent;
  const toolchain = await getSyncToolchain();
  if (!toolchain.length) return subtitleContent;

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'magnetio-subsync-'));
  const inputPath = path.join(tempDir, 'input.srt');
  const outputPath = path.join(tempDir, 'output.srt');

  try {
    await fs.writeFile(inputPath, subtitleContent, 'utf8');

    for (const tool of toolchain) {
      const synced = await tool.sync(mediaUrl, inputPath, outputPath);
      if (!synced) continue;

      const content = await fs.readFile(outputPath, 'utf8');
      if (content.trim()) return content;
    }
  } catch (err) {
    logger.warn(`Subtitle sync failed: ${err.message}`);
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }

  return subtitleContent;
}

async function getSyncToolchain() {
  if (syncToolCache !== undefined) return syncToolCache;

  const tools = [];

  const ffsubsync = await resolveCommand([
    explicitCommand(process.env.FFSUBSYNC_PATH),
    ['ffsubsync'],
    ['subsync'],
    ['ffs'],
    ['python3', '-m', 'ffsubsync'],
  ]);

  if (ffsubsync) {
    tools.push({
      name: 'ffsubsync',
      sync: (mediaUrl, inputPath, outputPath) =>
        runCommand(ffsubsync, [
          mediaUrl,
          '-i', inputPath,
          '-o', outputPath,
          '--max-offset-seconds', process.env.SUBTITLE_SYNC_MAX_OFFSET_SECONDS || '300',
        ]).catch(async () => runCommand(ffsubsync, [
          mediaUrl,
          '-i', inputPath,
          '-o', outputPath,
          '--max-offset-seconds', process.env.SUBTITLE_SYNC_MAX_OFFSET_SECONDS || '300',
          '--gss',
        ])),
    });
  }

  const alass = await resolveCommand([
    explicitCommand(process.env.ALASS_PATH),
    ['alass'],
    ['alass-cli'],
  ]);

  if (alass) {
    tools.push({
      name: 'alass',
      sync: (mediaUrl, inputPath, outputPath) =>
        runCommand(alass, [
          mediaUrl,
          inputPath,
          outputPath,
          '--split-penalty',
          process.env.ALASS_SPLIT_PENALTY || '10',
        ]),
    });
  }

  if (!tools.length) {
    logger.info('Subtitle sync tooling not found; subtitle proxy will serve unsynced subtitle files as fallback');
  } else {
    logger.info(`Subtitle sync tooling enabled: ${tools.map(tool => tool.name).join(', ')}`);
  }

  syncToolCache = tools;
  return tools;
}

async function resolveCommand(candidates) {
  for (const candidate of candidates.filter(Boolean)) {
    if (await commandExists(candidate)) return candidate;
  }
  return null;
}

function explicitCommand(command) {
  return command ? [command] : null;
}

async function commandExists(command) {
  try {
    await runCommand(command, ['--version'], { timeoutMs: TOOL_CHECK_TIMEOUT_MS });
    return true;
  } catch {
    return false;
  }
}

function runCommand(command, args, { timeoutMs = SYNC_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], [...command.slice(1), ...args], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stderr = '';
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`Command timed out: ${command.join(' ')}`));
    }, timeoutMs);

    child.stderr.on('data', chunk => {
      stderr += chunk.toString();
    });

    child.on('error', err => {
      clearTimeout(timeout);
      reject(err);
    });

    child.on('close', code => {
      clearTimeout(timeout);
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(stderr.trim() || `Command failed with exit code ${code}`));
    });
  });
}

async function downloadSubtitleText(url) {
  try {
    const response = await fetch(url, {
      headers: { 'User-Agent': process.env.OPENSUBTITLES_USER_AGENT || 'Magnetio v1.0.0' },
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    return response.text();
  } catch (err) {
    logger.warn(`Subtitle download failed: ${err.message}`);
    return null;
  }
}

async function getRemoteContentLength(url) {
  try {
    const response = await fetch(url, { method: 'HEAD' });
    const size = parseContentLength(response.headers.get('content-length'));
    if (size) return size;
  } catch (err) {
    logger.debug(`HEAD size lookup failed: ${err.message}`);
  }

  try {
    const response = await fetch(url, { headers: { Range: 'bytes=0-0' } });
    const contentRange = response.headers.get('content-range');
    const match = contentRange?.match(/\/(\d+)$/);
    if (match) return parseInt(match[1], 10);
  } catch (err) {
    logger.debug(`Range size lookup failed: ${err.message}`);
  }

  return null;
}

async function fetchRange(url, start, end) {
  const response = await fetch(url, {
    headers: {
      Range: `bytes=${start}-${end}`,
    },
  });

  if (!response.ok) {
    throw new Error(`Range request failed with HTTP ${response.status}`);
  }

  const contentLength = parseContentLength(response.headers.get('content-length'));
  if (response.status !== 206 && contentLength && contentLength > OPENSUBTITLES_HASH_CHUNK_SIZE + 8) {
    await response.body?.cancel();
    throw new Error('Remote server ignored byte-range request');
  }

  const buffer = Buffer.from(await response.arrayBuffer());
  if (!buffer.length) {
    throw new Error('Empty byte-range response');
  }

  return buffer;
}

function parseContentLength(value) {
  const parsed = parseInt(String(value || ''), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function inferFilenameFromUrl(url) {
  try {
    const pathname = new URL(url).pathname;
    const filename = decodeURIComponent(path.basename(pathname)).trim();
    return filename || null;
  } catch {
    return null;
  }
}

function hashValue(value) {
  return crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
}
