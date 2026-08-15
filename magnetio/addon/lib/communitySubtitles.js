import axios from 'axios';
import { cacheWrap } from './cache.js';
import { logger } from './logger.js';
import { toSubtitleLanguageCode } from './languages.js';
import { parseStremioVideoId, resolveSubtitleLanguages } from './subtitles.js';
import { extractSrtFromZip } from './subtitleZip.js';

const API_BASE_URL = (process.env.COMMUNITY_SUBS_API_URL || 'https://api.subsource.net/api').replace(/\/$/, '');
const HOST_ALLOWLIST = /^https:\/\/(?:[a-z0-9-]+\.)?subsource\.net\//i;
const CINEMETA_BASE_URL = (process.env.CINEMETA_BASE_URL || 'https://v3-cinemeta.strem.io').replace(/\/$/, '');
const REQUEST_TIMEOUT = 15_000;
const LISTING_CACHE_TTL = 60 * 60 * 6;
const MAPPING_CACHE_TTL = 60 * 60 * 24 * 30;
const FILE_CACHE_TTL = 60 * 60 * 24 * 7;
const MAX_PER_LANGUAGE = 3;
const MAX_TOTAL = 10;
const MAX_ZIP_BYTES = 4 * 1024 * 1024;

const HTTP_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Origin': 'https://subsource.net',
  'Referer': 'https://subsource.net/',
};

const CODE_TO_NAME = {
  en: 'English',
  es: 'Spanish',
  fr: 'French',
  de: 'German',
  it: 'Italian',
  pt: 'Portuguese',
  el: 'Greek',
  ru: 'Russian',
  pl: 'Polish',
  tr: 'Turkish',
  ja: 'Japanese',
  zh: 'Chinese',
  ko: 'Korean',
  ar: 'Arabic',
  he: 'Hebrew',
  ro: 'Romanian',
  nl: 'Dutch',
  sv: 'Swedish',
  da: 'Danish',
  no: 'Norwegian',
  fi: 'Finnish',
  bg: 'Bulgarian',
  uk: 'Ukrainian',
  sr: 'Serbian',
  hr: 'Croatian',
  sl: 'Slovenian',
  sq: 'Albanian',
  fa: 'Farsi/Persian',
  hi: 'Hindi',
  id: 'Indonesian',
  vi: 'Vietnamese',
  th: 'Thai',
  cs: 'Czech',
  sk: 'Slovak',
  hu: 'Hungarian',
  ms: 'Malay',
  ml: 'Malayalam',
  ta: 'Tamil',
  te: 'Telugu',
  bn: 'Bengali',
  ur: 'Urdu',
  is: 'Icelandic',
  et: 'Estonian',
  lv: 'Latvian',
  lt: 'Lithuanian',
  mk: 'Macedonian',
  bs: 'Bosnian',
};

const NAME_TO_CODE = (() => {
  const map = {};
  for (const [code, name] of Object.entries(CODE_TO_NAME)) {
    map[name.toLowerCase()] = code;
  }
  // Common aliases the upstream uses.
  map['brazilian portuguese'] = 'pt';
  map['big 5 code'] = 'zh';
  map['chinese bg code'] = 'zh';
  map['farsi'] = 'fa';
  map['persian'] = 'fa';
  return map;
})();

export async function getCommunitySubtitles(args, config) {
  const parsed = parseStremioVideoId(args?.id);
  if (!parsed.imdbId) return [];

  const languages = resolveSubtitleLanguages(config);
  if (!languages.length) return [];

  const baseUrl = String(config?._publicBaseUrl || '').replace(/\/$/, '');
  if (!baseUrl) return [];

  const imdbId = `tt${parsed.imdbId}`;
  const kind = parsed.season != null ? 'series' : 'movie';

  try {
    const moviePath = await resolveMoviePath(imdbId, kind);
    if (!moviePath) return [];

    const langNames = languages
      .map(code => CODE_TO_NAME[code])
      .filter(Boolean);
    if (!langNames.length) return [];

    const requestPath = kind === 'series'
      ? `${moviePath}/season-${parsed.season}`
      : moviePath;

    const subs = await fetchSubsListing(requestPath, langNames);
    const filtered = kind === 'series' ? filterByEpisode(subs, parsed.episode) : subs;
    return pickSubtitles(filtered, languages, moviePath, baseUrl);
  } catch (err) {
    logger.warn(`Community subtitle lookup failed [${imdbId}]: ${err.message}`);
    return [];
  }
}

export async function handleCommunitySubtitlesProxy(req, res) {
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

    if (!payload || (!payload.id && !payload.fullLink)) {
      res.status(400).json({ error: 'Invalid subtitle payload' });
      return;
    }

    const cacheKey = `community-subs:srt:${proxyId}`;
    const content = await cacheWrap(
      cacheKey,
      () => downloadAndExtract(payload),
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
    logger.warn(`Community subtitle proxy error: ${err.message}`);
    res.status(500).json({ error: 'Subtitle proxy failed' });
  }
}

async function resolveMoviePath(imdbId, kind) {
  return cacheWrap(`community-subs:path:${imdbId}:${kind}`, async () => {
    const meta = await fetchCinemetaMeta(imdbId, kind);
    const title = meta?.name?.trim();
    if (!title) return null;

    const year = parseYear(meta?.releaseInfo) ?? parseYear(meta?.year);
    const results = await searchMovies(title);
    if (!results.length) return null;

    const targetKind = kind === 'series' ? 'tv' : 'movie';
    const typed = results.filter(item => matchesKind(item, targetKind));
    const pool = typed.length ? typed : results;

    if (year) {
      const yearMatch = pool.find(item => Number(item.year) === year);
      if (yearMatch) return extractFullName(yearMatch);
    }

    const target = normalizeTitle(title);
    const titleMatch = pool.find(item => normalizeTitle(item.title) === target);
    return extractFullName(titleMatch ?? pool[0]);
  }, MAPPING_CACHE_TTL);
}

async function fetchCinemetaMeta(imdbId, kind) {
  try {
    const segment = kind === 'series' ? 'series' : 'movie';
    const { data } = await axios.get(`${CINEMETA_BASE_URL}/meta/${segment}/${imdbId}.json`, {
      timeout: REQUEST_TIMEOUT,
    });
    return data?.meta || null;
  } catch (err) {
    logger.debug(`Cinemeta lookup failed [${imdbId}]: ${err.message}`);
    return null;
  }
}

async function searchMovies(query) {
  try {
    const { data } = await axios.post(
      `${API_BASE_URL}/searchMovieSimple`,
      { query },
      {
        timeout: REQUEST_TIMEOUT,
        headers: { ...HTTP_HEADERS, 'Content-Type': 'application/json' },
        validateStatus: status => status === 200,
      },
    );
    return normalizeSearchResults(data);
  } catch (err) {
    logger.debug(`Community search failed [${query}]: ${err.message}`);
    return [];
  }
}

export function normalizeSearchResults(data) {
  if (Array.isArray(data)) return data;
  if (Array.isArray(data?.found)) return data.found;
  if (Array.isArray(data?.success)) return data.success;
  if (Array.isArray(data?.results)) return data.results;
  return [];
}

async function fetchSubsListing(moviePath, langNames) {
  const cacheKey = `community-subs:listing:${moviePath}:${langNames.slice().sort().join(',')}`;
  return cacheWrap(cacheKey, async () => {
    try {
      const { data } = await axios.post(
        `${API_BASE_URL}/getMovie`,
        { langs: langNames, movieName: moviePath },
        {
          timeout: REQUEST_TIMEOUT,
          headers: { ...HTTP_HEADERS, 'Content-Type': 'application/json' },
          validateStatus: status => status === 200,
        },
      );
      return Array.isArray(data?.subs) ? data.subs : [];
    } catch (err) {
      logger.debug(`Community getMovie failed [${moviePath}]: ${err.message}`);
      return [];
    }
  }, LISTING_CACHE_TTL);
}

export function filterByEpisode(subs, episode) {
  if (episode == null) return subs;
  const padded = String(episode).padStart(2, '0');
  const matchRegex = new RegExp(`e(?:p(?:isode)?\\s*)?(?:${padded}|${episode})(?!\\d)`, 'i');
  const anyEpisodeRegex = /e(?:p(?:isode)?\s*)?\d{1,3}(?!\d)/i;

  return subs.filter(sub => {
    const declared = sub.episode != null ? Number(sub.episode) : null;
    if (declared === episode) return true;
    if (declared != null && declared !== episode) return false;

    const release = String(sub.releaseName || sub.ri || sub.release || '').toLowerCase();
    if (!release) return true;
    if (matchRegex.test(release)) return true;
    if (anyEpisodeRegex.test(release)) return false;
    return true;
  });
}

function pickSubtitles(subs, languages, moviePath, baseUrl) {
  const langSet = new Set(languages);
  const perLanguage = new Map();
  const picked = [];

  for (const sub of subs) {
    const langName = String(sub.lang || sub.language || sub.languageName || '').toLowerCase().trim();
    const code = NAME_TO_CODE[langName];
    if (!code || !langSet.has(code)) continue;

    const count = perLanguage.get(code) || 0;
    if (count >= MAX_PER_LANGUAGE) continue;

    const subId = sub.sub_id || sub.id || sub.subtitle_id || sub.subId;
    const fullLink = sub.fullLink || sub.full_link || null;
    if (!subId && !fullLink) continue;

    const payload = {
      movie: sub.movie || moviePath,
      lang: sub.lang || sub.language || langName,
      id: subId || null,
      fullLink,
    };

    const proxyId = Buffer.from(JSON.stringify(payload)).toString('base64url');
    picked.push({
      id: `community-${subId || hashString(fullLink || '')}`,
      lang: toSubtitleLanguageCode(code),
      url: `${baseUrl}/proxy/community/${proxyId}.srt`,
    });
    perLanguage.set(code, count + 1);
    if (picked.length >= MAX_TOTAL) break;
  }

  return picked;
}

async function downloadAndExtract(payload) {
  const token = await fetchDownloadToken(payload);
  if (!token) return null;

  const downloadUrl = `${API_BASE_URL}/downloadSub/${encodeURIComponent(token)}`;
  if (!HOST_ALLOWLIST.test(downloadUrl)) return null;

  const response = await axios.get(downloadUrl, {
    responseType: 'arraybuffer',
    timeout: REQUEST_TIMEOUT,
    maxContentLength: MAX_ZIP_BYTES,
    maxBodyLength: MAX_ZIP_BYTES,
    headers: HTTP_HEADERS,
    validateStatus: status => status >= 200 && status < 400,
  });

  const buffer = Buffer.from(response.data);
  if (!buffer.length || buffer.length > MAX_ZIP_BYTES) return null;
  return extractSrtFromZip(buffer);
}

async function fetchDownloadToken(payload) {
  try {
    const body = {
      movie: payload.movie,
      lang: payload.lang,
      id: payload.id,
    };
    if (payload.fullLink) body.fullLink = payload.fullLink;

    const { data } = await axios.post(`${API_BASE_URL}/getSub`, body, {
      timeout: REQUEST_TIMEOUT,
      headers: { ...HTTP_HEADERS, 'Content-Type': 'application/json' },
      validateStatus: status => status === 200,
    });

    return (
      data?.sub?.download
      || data?.sub?.downloadToken
      || data?.downloadToken
      || data?.token
      || null
    );
  } catch (err) {
    logger.debug(`Community getSub failed: ${err.message}`);
    return null;
  }
}

function matchesKind(item, kind) {
  const candidates = [item?.type, item?.kind, item?.category]
    .map(value => String(value || '').toLowerCase());
  if (kind === 'series') {
    return candidates.some(value => value.includes('tv') || value.includes('series') || value.includes('show'));
  }
  return candidates.some(value => value.includes('movie') || value.includes('film'));
}

function extractFullName(item) {
  if (!item) return null;
  return item.fullName || item.full_name || item.linkName || item.link || null;
}

function parseYear(value) {
  const match = String(value || '').match(/(19|20)\d{2}/);
  return match ? Number(match[0]) : null;
}

function normalizeTitle(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '');
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
