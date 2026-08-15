import axios from 'axios';
import { cacheWrap } from './cache.js';
import { logger } from './logger.js';
import { toSubtitleLanguageCode } from './languages.js';
import { resolveSubtitleLanguages } from './subtitles.js';
import { translateText } from './translationProviders.js';

const REQUEST_TIMEOUT = 20_000;
const FILE_CACHE_TTL = 60 * 60 * 24 * 30;
const MAX_INPUT_BYTES = 768 * 1024;
const MAX_BATCH_CHARS = 4000;
const TRANSLATION_SEPARATOR = '\n\n@@~~@@\n\n';
const SOURCE_LANGUAGE = 'en';
const MAX_TRANSLATIONS = 2;

const BLOCKED_HOSTNAMES = new Set([
  'localhost', '127.0.0.1', '::1', '0.0.0.0',
  'metadata.google.internal', 'metadata.internal',
]);

const HTTP_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
};

export function attachTranslatedSubtitles(subtitles, config) {
  const languages = resolveSubtitleLanguages(config);
  const nonEnglish = languages.filter(code => code !== SOURCE_LANGUAGE);
  const target = nonEnglish[0];
  if (!target) return subtitles;

  const baseUrl = String(config?._publicBaseUrl || '').replace(/\/$/, '');
  if (!baseUrl) return subtitles;

  const englishSubs = subtitles.filter(sub => isEnglishCode(sub?.lang));
  if (!englishSubs.length) return subtitles;

  const targetSubtitleCode = toSubtitleLanguageCode(target);
  const alreadyTranslated = new Set(
    subtitles
      .filter(sub => sub?.lang === targetSubtitleCode)
      .map(sub => String(sub?.id || sub?.url || '')),
  );

  const additions = [];
  for (const source of englishSubs) {
    if (additions.length >= MAX_TRANSLATIONS) break;

    const sourceUrl = String(source?.url || '');
    if (!sourceUrl || !isHttpUrlSafe(sourceUrl)) continue;

    const payload = { url: sourceUrl, from: SOURCE_LANGUAGE, to: target };
    const proxyId = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const id = `translated-${target}-${source.id || hashString(sourceUrl)}`;
    if (alreadyTranslated.has(id)) continue;

    additions.push({
      id,
      lang: targetSubtitleCode,
      url: `${baseUrl}/proxy/translated/${proxyId}.srt`,
    });
  }

  return [...subtitles, ...additions];
}

export async function handleTranslatedSubtitleProxy(req, res) {
  try {
    const proxyId = String(req.params.id || '').trim();
    if (!proxyId) {
      res.status(400).json({ error: 'Missing subtitle id' });
      return;
    }

    let payload;
    try {
      payload = JSON.parse(Buffer.from(proxyId, 'base64url').toString('utf8'));
    } catch {
      res.status(400).json({ error: 'Invalid subtitle id' });
      return;
    }

    if (!payload?.url || !payload?.from || !payload?.to) {
      res.status(400).json({ error: 'Invalid subtitle payload' });
      return;
    }

    if (!isHttpUrlSafe(payload.url)) {
      res.status(400).json({ error: 'Invalid subtitle host' });
      return;
    }

    const cacheKey = `translated-subs:${proxyId}`;
    const content = await cacheWrap(
      cacheKey,
      () => downloadAndTranslate(payload),
      FILE_CACHE_TTL,
    );

    if (!content) {
      res.status(404).json({ error: 'Subtitle not available' });
      return;
    }

    res.setHeader('content-type', 'application/x-subrip; charset=utf-8');
    res.setHeader(
      'cache-control',
      'public, max-age=2592000, stale-while-revalidate=604800, stale-if-error=604800',
    );
    res.send(content);
  } catch (err) {
    logger.warn(`Translated subtitle proxy error: ${err.message}`);
    res.status(500).json({ error: 'Subtitle translation failed' });
  }
}

async function downloadAndTranslate(payload) {
  const srt = await fetchSourceSubtitle(payload.url);
  if (!srt) return null;
  return translateSrt(srt, payload.from, payload.to);
}

async function fetchSourceSubtitle(url) {
  try {
    const response = await axios.get(url, {
      responseType: 'text',
      timeout: REQUEST_TIMEOUT,
      maxContentLength: MAX_INPUT_BYTES,
      maxBodyLength: MAX_INPUT_BYTES,
      headers: HTTP_HEADERS,
      validateStatus: status => status >= 200 && status < 400,
      transformResponse: [value => value],
    });

    const text = typeof response.data === 'string' ? response.data : String(response.data ?? '');
    if (!text.trim()) return null;
    if (Buffer.byteLength(text, 'utf8') > MAX_INPUT_BYTES) return null;
    return text.replace(/\r\n/g, '\n');
  } catch (err) {
    logger.warn(`Translated subtitle source fetch failed: ${err.message}`);
    return null;
  }
}

export async function translateSrt(srtText, from, to) {
  const blocks = parseSrt(srtText);
  if (!blocks.length) return null;

  const texts = blocks.map(block => block.text);
  const batches = batchTexts(texts, MAX_BATCH_CHARS);
  const translations = [];

  for (const batch of batches) {
    const translated = await translateBatch(batch, from, to);
    if (!translated || translated.length !== batch.length) {
      for (const original of batch) translations.push(original);
      continue;
    }
    translations.push(...translated);
  }

  for (let i = 0; i < blocks.length; i++) {
    blocks[i].text = translations[i] ?? blocks[i].text;
  }

  return serializeSrt(blocks);
}

async function translateBatch(texts, from, to) {
  if (!texts.length) return [];

  if (texts.length === 1) {
    const single = await callTranslateApi(texts[0], from, to);
    return single == null ? null : [single];
  }

  const joined = texts.join(TRANSLATION_SEPARATOR);
  const result = await callTranslateApi(joined, from, to);
  if (result == null) return null;

  const parts = result.split(TRANSLATION_SEPARATOR);
  if (parts.length === texts.length) return parts.map(part => part.trim());

  const fallback = [];
  for (const text of texts) {
    const translated = await callTranslateApi(text, from, to);
    fallback.push(translated ?? text);
  }
  return fallback;
}

async function callTranslateApi(text, from, to) {
  if (!text.trim()) return text;
  try {
    return await translateText(text, from, to);
  } catch (err) {
    logger.debug(`Translation call failed: ${err.message}`);
    return null;
  }
}

export function batchTexts(texts, maxChars) {
  const batches = [];
  let current = [];
  let currentSize = 0;
  const separatorSize = TRANSLATION_SEPARATOR.length;

  for (const text of texts) {
    const size = text.length;
    if (current.length && currentSize + separatorSize + size > maxChars) {
      batches.push(current);
      current = [];
      currentSize = 0;
    }
    current.push(text);
    currentSize += size + (current.length > 1 ? separatorSize : 0);
  }

  if (current.length) batches.push(current);
  return batches;
}

export function parseSrt(text) {
  const blocks = [];
  const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
  let i = 0;

  while (i < lines.length) {
    while (i < lines.length && !lines[i].trim()) i++;
    if (i >= lines.length) break;

    let indexValue = null;
    const indexCandidate = lines[i].trim();
    if (/^\d+$/.test(indexCandidate)) {
      indexValue = Number(indexCandidate);
      i++;
    }

    if (i >= lines.length) break;
    const timestamp = lines[i];
    if (!timestamp.includes('-->')) {
      i++;
      continue;
    }
    i++;

    const textLines = [];
    while (i < lines.length && lines[i].trim()) {
      textLines.push(lines[i]);
      i++;
    }

    blocks.push({
      index: indexValue ?? blocks.length + 1,
      timestamp: timestamp.trim(),
      text: textLines.join('\n'),
    });
  }

  return blocks;
}

export function serializeSrt(blocks) {
  return blocks
    .map((block, idx) => `${idx + 1}\n${block.timestamp}\n${block.text}\n`)
    .join('\n');
}

function isEnglishCode(value) {
  const code = String(value || '').toLowerCase();
  return code === 'eng' || code === 'en' || code === 'english';
}

function isHttpUrlSafe(url) {
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

function hashString(value) {
  let hash = 0;
  const str = String(value || '');
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash) + str.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}
