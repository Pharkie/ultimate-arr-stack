import axios from 'axios';
import { cacheWrap } from './cache.js';
import { logger } from './logger.js';
import { toSubtitleLanguageCode } from './languages.js';

const OPENSUBTITLES_BASE_URL = 'https://api.opensubtitles.com/api/v1';
const OPENSUBTITLES_TIMEOUT = 12_000;
const SUBTITLE_CACHE_TTL = 60 * 60 * 6;
const SUBTITLE_LINK_CACHE_TTL = 60 * 30;
const MAX_SUBTITLES = 8;
const MAX_SUBTITLES_PER_LANGUAGE = 2;

let authState = {
  token: null,
  expiresAt: 0,
  inflight: null,
};

let missingConfigWarningShown = false;

export async function getSubtitles(args, config) {
  if (!process.env.OPENSUBTITLES_API_KEY) {
    logMissingConfig('Subtitles disabled: OPENSUBTITLES_API_KEY is not configured');
    return [];
  }

  const params = buildSubtitleSearchParams(args, config);
  if (!params) return [];

  const cacheKey = `subtitles:${stableStringify(params)}`;
  return cacheWrap(cacheKey, async () => {
    try {
      const { data } = await axios.get(`${OPENSUBTITLES_BASE_URL}/subtitles`, {
        headers: getBaseHeaders(),
        params,
        timeout: OPENSUBTITLES_TIMEOUT,
      });

      const candidates = pickSubtitleCandidates(data?.data ?? []);
      if (!candidates.length) return [];

      const token = await getAuthToken();
      const settled = await Promise.allSettled(
        candidates.map(item => resolveSubtitleCandidate(item, token))
      );

      return settled
        .filter(result => result.status === 'fulfilled' && result.value)
        .map(result => result.value);
    } catch (err) {
      logger.warn(`Subtitle lookup failed [${args.id}]: ${err.message}`);
      return [];
    }
  }, SUBTITLE_CACHE_TTL);
}

export function buildSubtitleSearchParams(args, config) {
  const languages = resolveSubtitleLanguages(config);
  const parsedId = parseStremioVideoId(args?.id);
  const filename = normalizeFilename(args?.extra?.filename);

  const params = {
    order_by: 'download_count',
    order_direction: 'desc',
    languages: languages.join(','),
    page: 1,
  };

  if (parsedId.imdbId) {
    if (parsedId.season != null && parsedId.episode != null) {
      params.parent_imdb_id = parsedId.imdbId;
      params.season_number = parsedId.season;
      params.episode_number = parsedId.episode;
      params.type = 'episode';
    } else {
      params.imdb_id = parsedId.imdbId;
      params.type = 'movie';
    }
  }

  if (args?.extra?.videoHash) {
    params.moviehash = args.extra.videoHash;
    params.moviehash_match = 'include';
  }

  if (filename) {
    params.query = stripVideoExtension(filename);
  }

  if (!params.imdb_id && !params.parent_imdb_id && !params.moviehash && !params.query) {
    return null;
  }

  return params;
}

export function resolveSubtitleLanguages(config) {
  const preferred = config?.subtitleLanguages?.length
    ? config.subtitleLanguages
    : (config?.languages?.length ? config.languages : ['en']);

  return [...new Set(preferred
    .map(code => String(code || '').trim().toLowerCase())
    .filter(code => code && code !== 'multi' && code !== 'dubbed'))];
}

export function parseStremioVideoId(id) {
  const [rawId, season, episode] = String(id || '').split(':');
  const imdbId = rawId?.startsWith('tt') ? rawId.replace(/^tt/i, '') : null;

  return {
    rawId,
    imdbId,
    season: season != null ? parseInteger(season) : null,
    episode: episode != null ? parseInteger(episode) : null,
  };
}

function pickSubtitleCandidates(items) {
  const seenPerLanguage = new Map();
  const picked = [];

  for (const item of items) {
    const language = normalizeLanguage(item?.attributes?.language);
    const fileId = item?.attributes?.files?.[0]?.file_id;
    if (!language || !fileId) continue;

    const seen = seenPerLanguage.get(language) ?? 0;
    if (seen >= MAX_SUBTITLES_PER_LANGUAGE) continue;

    picked.push(item);
    seenPerLanguage.set(language, seen + 1);

    if (picked.length >= MAX_SUBTITLES) break;
  }

  return picked;
}

async function resolveSubtitleCandidate(item, token) {
  const language = normalizeLanguage(item?.attributes?.language);
  const file = item?.attributes?.files?.[0];
  if (!language || !file?.file_id) return null;

  let url = getDirectSubtitleUrl(item?.attributes?.url);
  if (!url && token) {
    url = await getDownloadLink(file.file_id, token);
  }

  if (!url) return null;

  return {
    id: String(item.id ?? file.file_id),
    lang: toSubtitleLanguageCode(language),
    url,
  };
}

async function getDownloadLink(fileId, token) {
  const cacheKey = `subtitles:download:${fileId}`;
  return cacheWrap(cacheKey, async () => {
    try {
      const { data } = await axios.post(
        `${OPENSUBTITLES_BASE_URL}/download`,
        { file_id: Number(fileId) },
        {
          headers: {
            ...getBaseHeaders(),
            Authorization: `Bearer ${token}`,
          },
          timeout: OPENSUBTITLES_TIMEOUT,
        }
      );

      return data?.link ?? null;
    } catch (err) {
      if (err.response?.status === 401) {
        authState.token = null;
        authState.expiresAt = 0;
      }
      logger.warn(`Subtitle download link failed [${fileId}]: ${err.message}`);
      return null;
    }
  }, SUBTITLE_LINK_CACHE_TTL);
}

async function getAuthToken() {
  const { OPENSUBTITLES_USERNAME, OPENSUBTITLES_PASSWORD } = process.env;
  if (!OPENSUBTITLES_USERNAME || !OPENSUBTITLES_PASSWORD) {
    logMissingConfig(
      'Subtitle downloads require OPENSUBTITLES_USERNAME and OPENSUBTITLES_PASSWORD; search results without direct URLs are skipped'
    );
    return null;
  }

  if (authState.token && Date.now() < authState.expiresAt - 60_000) {
    return authState.token;
  }

  if (authState.inflight) {
    return authState.inflight;
  }

  authState.inflight = axios.post(
    `${OPENSUBTITLES_BASE_URL}/login`,
    {
      username: OPENSUBTITLES_USERNAME,
      password: OPENSUBTITLES_PASSWORD,
    },
    {
      headers: getBaseHeaders(),
      timeout: OPENSUBTITLES_TIMEOUT,
    }
  ).then(({ data }) => {
    authState.token = data?.token ?? null;
    authState.expiresAt = getTokenExpiry(authState.token);
    return authState.token;
  }).catch(err => {
    logger.warn(`Subtitle auth failed: ${err.message}`);
    return null;
  }).finally(() => {
    authState.inflight = null;
  });

  return authState.inflight;
}

function getBaseHeaders() {
  return {
    'Api-Key': process.env.OPENSUBTITLES_API_KEY,
    'Content-Type': 'application/json',
    'User-Agent': process.env.OPENSUBTITLES_USER_AGENT || 'Magnetio v1.0.0',
  };
}

function getTokenExpiry(token) {
  if (!token) return 0;

  try {
    const payload = token.split('.')[1];
    const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return decoded?.exp ? decoded.exp * 1000 : Date.now() + (1000 * 60 * 30);
  } catch {
    return Date.now() + (1000 * 60 * 30);
  }
}

function getDirectSubtitleUrl(url) {
  const value = String(url || '').trim();
  if (!/^https?:\/\//i.test(value)) return null;
  return /\.(srt|vtt|ass|ssa|sub)(?:$|[?#])/i.test(value) ? value : null;
}

function stripVideoExtension(filename) {
  return filename.replace(/\.(mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$/i, '');
}

function normalizeFilename(filename) {
  if (!filename) return '';
  return String(filename).split('/').pop().trim();
}

function normalizeLanguage(language) {
  return String(language || '').trim().toLowerCase();
}

function parseInteger(value) {
  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function stableStringify(value) {
  return JSON.stringify(sortValue(value));
}

function sortValue(value) {
  if (Array.isArray(value)) {
    return value.map(sortValue);
  }

  if (value && typeof value === 'object') {
    return Object.keys(value).sort().reduce((acc, key) => {
      acc[key] = sortValue(value[key]);
      return acc;
    }, {});
  }

  return value;
}

function logMissingConfig(message) {
  if (missingConfigWarningShown) return;
  missingConfigWarningShown = true;
  logger.info(message);
}
