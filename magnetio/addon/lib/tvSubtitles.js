import axios from 'axios';
import { cacheWrap } from './cache.js';
import { logger } from './logger.js';
import { toSubtitleLanguageCode } from './languages.js';
import { parseStremioVideoId, resolveSubtitleLanguages } from './subtitles.js';
import { extractSrtFromZip } from './subtitleZip.js';

const BASE_URL = (process.env.TVSUBTITLES_BASE_URL || 'https://www.tvsubtitles.net').replace(/\/$/, '');
const HOST_ALLOWLIST = /^https?:\/\/(?:www\.|gr\.)?tvsubtitles\.net\//i;
const CINEMETA_BASE_URL = (process.env.CINEMETA_BASE_URL || 'https://v3-cinemeta.strem.io').replace(/\/$/, '');
const REQUEST_TIMEOUT = 12_000;
const LISTING_CACHE_TTL = 60 * 60 * 6;
const SHOW_MAPPING_TTL = 60 * 60 * 24 * 30;
const FILE_CACHE_TTL = 60 * 60 * 24 * 7;
const MAX_PER_LANGUAGE = 2;
const MAX_TOTAL = 8;
const MAX_ZIP_BYTES = 4 * 1024 * 1024;
const MAX_SEARCH_VERIFY = 5;

const HTTP_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'en-US,en;q=0.9',
};

// tvsubtitles uses flag icons named after country/language codes. Map to
// our internal two-letter codes so the same language preferences work.
const FLAG_TO_LANGUAGE_CODE = {
  en: 'en',
  es: 'es',
  fr: 'fr',
  de: 'de',
  it: 'it',
  pt: 'pt',
  br: 'pt',
  pl: 'pl',
  tr: 'tr',
  ru: 'ru',
  el: 'el',
  gr: 'el',
  hu: 'hu',
  cz: 'cs',
  sk: 'sk',
  ja: 'ja',
  jp: 'ja',
  zh: 'zh',
  cn: 'zh',
  ko: 'ko',
  kr: 'ko',
  ar: 'ar',
  he: 'he',
  ro: 'ro',
  nl: 'nl',
  sv: 'sv',
  se: 'sv',
  da: 'da',
  dk: 'da',
  no: 'no',
  fi: 'fi',
  bg: 'bg',
  ua: 'uk',
  uk: 'uk',
  hr: 'hr',
  sr: 'sr',
  sl: 'sl',
  sq: 'sq',
  fa: 'fa',
  hi: 'hi',
  id: 'id',
  vi: 'vi',
  th: 'th',
};

export async function getTvSubtitles(args, config) {
  const parsed = parseStremioVideoId(args?.id);
  if (!parsed.imdbId || parsed.season == null || parsed.episode == null) return [];

  const languages = resolveSubtitleLanguages(config);
  if (!languages.length) return [];

  const baseUrl = String(config?._publicBaseUrl || '').replace(/\/$/, '');
  if (!baseUrl) return [];

  const imdbId = `tt${parsed.imdbId}`;

  try {
    const showId = await resolveShowId(imdbId);
    if (!showId) return [];

    const candidates = await getEpisodeSubtitleList(showId, parsed.season, parsed.episode);
    return pickCandidates(candidates, languages, baseUrl);
  } catch (err) {
    logger.warn(`tvsubtitles lookup failed [${imdbId} S${parsed.season}E${parsed.episode}]: ${err.message}`);
    return [];
  }
}

export async function handleTvSubtitlesProxy(req, res) {
  try {
    const proxyId = String(req.params.id || '').trim();
    if (!proxyId) {
      res.status(400).json({ error: 'Missing subtitle id' });
      return;
    }

    let zipUrl;
    try {
      zipUrl = Buffer.from(proxyId, 'base64url').toString('utf8');
    } catch {
      res.status(400).json({ error: 'Invalid subtitle id' });
      return;
    }

    if (!HOST_ALLOWLIST.test(zipUrl)) {
      res.status(400).json({ error: 'Invalid subtitle host' });
      return;
    }

    const cacheKey = `tvsubs:srt:${proxyId}`;
    const content = await cacheWrap(
      cacheKey,
      () => downloadAndExtract(zipUrl),
      FILE_CACHE_TTL,
    );

    if (!content) {
      res.status(404).json({ error: 'Subtitle not available' });
      return;
    }

    res.setHeader('content-type', 'application/x-subrip; charset=utf-8');
    res.setHeader(
      'cache-control',
      'public, max-age=604800, stale-while-revalidate=604800, stale-if-error=604800',
    );
    res.send(content);
  } catch (err) {
    logger.warn(`tvsubtitles proxy error: ${err.message}`);
    res.status(500).json({ error: 'Subtitle proxy failed' });
  }
}

async function resolveShowId(imdbId) {
  return cacheWrap(`tvsubs:show:${imdbId}`, async () => {
    const meta = await fetchCinemetaSeries(imdbId);
    const title = meta?.name?.trim();
    if (!title) return null;

    const results = await searchShows(title);
    if (!results.length) return null;

    for (const candidate of results.slice(0, MAX_SEARCH_VERIFY)) {
      const showImdb = await getShowImdbId(candidate.id);
      if (showImdb && showImdb.toLowerCase() === imdbId.toLowerCase()) {
        return candidate.id;
      }
    }

    const targetTitle = normalizeTitle(title);
    const titleMatch = results.find(result => normalizeTitle(result.name) === targetTitle);
    return titleMatch?.id || null;
  }, SHOW_MAPPING_TTL);
}

async function fetchCinemetaSeries(imdbId) {
  try {
    const { data } = await axios.get(`${CINEMETA_BASE_URL}/meta/series/${imdbId}.json`, {
      timeout: REQUEST_TIMEOUT,
    });
    return data?.meta || null;
  } catch (err) {
    logger.debug(`Cinemeta lookup failed [${imdbId}]: ${err.message}`);
    return null;
  }
}

async function searchShows(title) {
  try {
    const { data } = await axios.get(`${BASE_URL}/search.php`, {
      params: { q: title },
      timeout: REQUEST_TIMEOUT,
      headers: HTTP_HEADERS,
      validateStatus: status => status === 200,
    });
    if (typeof data !== 'string') return [];
    return parseSearchResults(data);
  } catch (err) {
    logger.debug(`tvsubtitles search failed [${title}]: ${err.message}`);
    return [];
  }
}

export function parseSearchResults(html) {
  const results = [];
  const seen = new Set();
  const regex = /<a\b[^>]*href="\/?(?:tvshow-(\d+)(?:-\d+)?\.html)"[^>]*>([^<]+)<\/a>/gi;

  let match;
  while ((match = regex.exec(html)) !== null) {
    const id = match[1];
    if (seen.has(id)) continue;
    seen.add(id);
    results.push({ id, name: decodeHtmlEntities(match[2].trim()) });
  }

  return results;
}

async function getShowImdbId(showId) {
  try {
    const { data } = await axios.get(`${BASE_URL}/tvshow-${showId}.html`, {
      timeout: REQUEST_TIMEOUT,
      headers: HTTP_HEADERS,
      validateStatus: status => status === 200,
    });
    if (typeof data !== 'string') return null;
    const match = data.match(/imdb\.com\/title\/(tt\d+)/i);
    return match ? match[1] : null;
  } catch (err) {
    logger.debug(`tvsubtitles show metadata failed [${showId}]: ${err.message}`);
    return null;
  }
}

async function getEpisodeSubtitleList(showId, season, episode) {
  const cacheKey = `tvsubs:episode:${showId}:s${season}e${episode}`;
  return cacheWrap(cacheKey, async () => {
    const seasonHtml = await fetchHtml(`${BASE_URL}/tvshow-${showId}-${season}.html`);
    if (!seasonHtml) return [];

    const episodeId = findEpisodeId(seasonHtml, season, episode);
    if (!episodeId) return [];

    const episodeHtml = await fetchHtml(`${BASE_URL}/episode-${episodeId}.html`);
    if (!episodeHtml) return [];

    return parseEpisodeSubtitles(episodeHtml);
  }, LISTING_CACHE_TTL);
}

export function findEpisodeId(html, season, episode) {
  const paddedEpisode = String(episode).padStart(2, '0');
  const patterns = [
    new RegExp(`href="\\/?episode-(\\d+)\\.html"[^>]*>[^<]*\\b${season}x${paddedEpisode}\\b`, 'i'),
    new RegExp(`\\b${season}x${paddedEpisode}\\b[\\s\\S]{0,160}?href="\\/?episode-(\\d+)\\.html"`, 'i'),
  ];
  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (match) return match[1];
  }
  return null;
}

export function parseEpisodeSubtitles(html) {
  const subs = [];
  const seen = new Set();
  const regex = /href="\/?subtitle-(\d+)\.html"[\s\S]{0,600}?images\/flags\/([a-z]{2})\.gif/gi;

  let match;
  while ((match = regex.exec(html)) !== null) {
    const id = match[1];
    if (seen.has(id)) continue;

    const flagCode = match[2].toLowerCase();
    const language = FLAG_TO_LANGUAGE_CODE[flagCode];
    if (!language) continue;

    seen.add(id);
    subs.push({ id, language });
  }

  return subs;
}

function pickCandidates(candidates, languages, baseUrl) {
  const langSet = new Set(languages);
  const perLanguage = new Map();
  const picked = [];

  for (const candidate of candidates) {
    if (!langSet.has(candidate.language)) continue;
    const count = perLanguage.get(candidate.language) || 0;
    if (count >= MAX_PER_LANGUAGE) continue;

    const zipUrl = `${BASE_URL}/download-${candidate.id}.html`;
    const proxyId = Buffer.from(zipUrl).toString('base64url');

    picked.push({
      id: `tvsubs-${candidate.id}`,
      lang: toSubtitleLanguageCode(candidate.language),
      url: `${baseUrl}/proxy/tvsubs/${proxyId}.srt`,
    });
    perLanguage.set(candidate.language, count + 1);
    if (picked.length >= MAX_TOTAL) break;
  }

  return picked;
}

async function downloadAndExtract(zipUrl) {
  const response = await axios.get(zipUrl, {
    responseType: 'arraybuffer',
    timeout: REQUEST_TIMEOUT,
    maxContentLength: MAX_ZIP_BYTES,
    maxBodyLength: MAX_ZIP_BYTES,
    headers: {
      ...HTTP_HEADERS,
      Referer: `${BASE_URL}/`,
    },
    validateStatus: status => status >= 200 && status < 400,
  });

  const buffer = Buffer.from(response.data);
  if (!buffer.length || buffer.length > MAX_ZIP_BYTES) return null;
  return extractSrtFromZip(buffer);
}

async function fetchHtml(url) {
  try {
    const { data } = await axios.get(url, {
      timeout: REQUEST_TIMEOUT,
      headers: HTTP_HEADERS,
      validateStatus: status => status === 200,
    });
    return typeof data === 'string' ? data : null;
  } catch (err) {
    logger.debug(`tvsubtitles fetch failed [${url}]: ${err.message}`);
    return null;
  }
}

function normalizeTitle(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '');
}

function decodeHtmlEntities(value) {
  return String(value || '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_, code) => {
      const num = parseInt(code, 10);
      return Number.isFinite(num) ? String.fromCharCode(num) : '';
    });
}
