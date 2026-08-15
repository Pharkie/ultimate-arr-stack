import axios from 'axios';
import { logger } from './logger.js';

const REQUEST_TIMEOUT = 20_000;
const BING_SESSION_TTL_MS = 30 * 60 * 1000;
const DEFAULT_PROVIDER_ORDER = 'google,bing,deepl,kagi';

const HTTP_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept': '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
};

export async function translateText(text, from, to) {
  if (text == null) return null;
  if (typeof text !== 'string') text = String(text);
  if (!text.trim()) return text;

  const providers = getActiveProviders();
  if (!providers.length) return null;

  for (const provider of providers) {
    try {
      const result = await provider.translate(text, from, to);
      if (typeof result === 'string' && result.trim()) return result;
    } catch (err) {
      logger.debug(`Translation provider [${provider.name}] failed: ${err.message}`);
    }
  }

  return null;
}

export function getActiveProviders() {
  const env = String(process.env.TRANSLATION_PROVIDERS || DEFAULT_PROVIDER_ORDER);
  const seen = new Set();
  const ordered = [];
  for (const raw of env.split(',')) {
    const name = raw.trim().toLowerCase();
    if (!name || seen.has(name) || !PROVIDERS[name]) continue;
    seen.add(name);
    ordered.push(PROVIDERS[name]);
  }
  return ordered;
}

// ─── Google Translate (free, no account) ─────────────────────────────────────

async function translateViaGoogle(text, from, to) {
  const { data } = await axios.get('https://translate.googleapis.com/translate_a/single', {
    params: { client: 'gtx', sl: from, tl: to, dt: 't', q: text },
    timeout: REQUEST_TIMEOUT,
    headers: HTTP_HEADERS,
    validateStatus: status => status === 200,
  });

  if (!Array.isArray(data) || !Array.isArray(data[0])) return null;
  return data[0]
    .map(chunk => (Array.isArray(chunk) ? String(chunk[0] ?? '') : ''))
    .join('');
}

// ─── Bing Translate (free, scrapes anonymous session params) ─────────────────

const BING_LANGUAGE_MAP = {
  zh: 'zh-Hans',
  he: 'iw',
  pt: 'pt-pt',
  nb: 'nb',
  sr: 'sr-Cyrl',
};

let bingSession = null;
let bingSessionExpiresAt = 0;
let bingSessionPromise = null;

async function getBingSession() {
  const now = Date.now();
  if (bingSession && now < bingSessionExpiresAt) return bingSession;
  if (bingSessionPromise) return bingSessionPromise;

  bingSessionPromise = bootstrapBingSession()
    .then(session => {
      bingSession = session;
      bingSessionExpiresAt = Date.now() + BING_SESSION_TTL_MS;
      return session;
    })
    .finally(() => {
      bingSessionPromise = null;
    });

  return bingSessionPromise;
}

async function bootstrapBingSession() {
  const { data: html } = await axios.get('https://www.bing.com/translator', {
    timeout: REQUEST_TIMEOUT,
    headers: HTTP_HEADERS,
    validateStatus: status => status === 200,
  });

  if (typeof html !== 'string') {
    throw new Error('Bing translator landing page returned non-text');
  }

  const ig = html.match(/IG:"([^"]+)"/)?.[1];
  const iid = html.match(/data-iid="([^"]+)"/)?.[1] || 'translator.5023';
  const helper = html.match(/var\s+params_AbusePreventionHelper\s*=\s*\[([^\]]+)\]/);
  if (!ig || !helper) throw new Error('Bing session parameters not found');

  const parts = helper[1].split(',').map(part => part.trim().replace(/^"|"$/g, ''));
  const key = parts[0];
  const token = parts[1];
  if (!key || !token) throw new Error('Bing key/token missing');

  return { ig, iid, key, token };
}

async function translateViaBing(text, from, to) {
  const session = await getBingSession();
  const fromLang = BING_LANGUAGE_MAP[from] || from;
  const toLang = BING_LANGUAGE_MAP[to] || to;

  const body = new URLSearchParams({
    fromLang,
    text,
    to: toLang,
    token: session.token,
    key: session.key,
  });

  let response;
  try {
    response = await axios.post(
      `https://www.bing.com/ttranslatev3?isVertical=1&&IG=${session.ig}&IID=${session.iid}`,
      body.toString(),
      {
        timeout: REQUEST_TIMEOUT,
        headers: {
          ...HTTP_HEADERS,
          'Content-Type': 'application/x-www-form-urlencoded',
          Referer: 'https://www.bing.com/translator',
        },
        validateStatus: status => status === 200,
      },
    );
  } catch (err) {
    bingSession = null;
    bingSessionExpiresAt = 0;
    throw err;
  }

  const data = response.data;
  if (Array.isArray(data) && data[0]?.translations?.[0]?.text) {
    return String(data[0].translations[0].text);
  }
  if (data?.statusCode && data.statusCode !== 200) {
    bingSession = null;
    bingSessionExpiresAt = 0;
  }
  return null;
}

// ─── DeepL (free, unofficial jsonrpc used by the web UI) ─────────────────────

const DEEPL_SUPPORTED_TARGETS = new Set([
  'BG', 'CS', 'DA', 'DE', 'EL', 'EN', 'ES', 'ET', 'FI', 'FR', 'HU', 'ID',
  'IT', 'JA', 'KO', 'LT', 'LV', 'NB', 'NL', 'PL', 'PT', 'RO', 'RU', 'SK',
  'SL', 'SV', 'TR', 'UK', 'ZH',
]);

async function translateViaDeepL(text, from, to) {
  const targetLang = String(to || '').toUpperCase();
  if (!DEEPL_SUPPORTED_TARGETS.has(targetLang)) return null;

  const sourceLang = from && from.toLowerCase() !== 'auto'
    ? String(from).toUpperCase()
    : 'auto';

  const id = 1_000_000 + Math.floor(Math.random() * 9_000_000);
  const iCount = (text.match(/i/g) || []).length;
  const baseTimestamp = Date.now();
  const timestamp = iCount > 0
    ? baseTimestamp + (iCount + 1) - (baseTimestamp % (iCount + 1))
    : baseTimestamp;

  const body = {
    jsonrpc: '2.0',
    method: 'LMT_handle_jobs',
    id,
    params: {
      jobs: [{
        kind: 'default',
        sentences: [{ text, id: 1, prefix: '' }],
        raw_en_context_before: [],
        raw_en_context_after: [],
        preferred_num_beams: 1,
      }],
      lang: {
        target_lang: targetLang,
        source_lang_user_selected: sourceLang,
      },
      priority: 1,
      commonJobParams: { mode: 'translate' },
      timestamp,
    },
  };

  let payload = JSON.stringify(body);
  if ((id + 5) % 29 === 0 || (id + 3) % 13 === 0) {
    payload = payload.replace('"method":"', '"method" : "');
  } else {
    payload = payload.replace('"method":"', '"method": "');
  }

  const { data } = await axios.post('https://www2.deepl.com/jsonrpc', payload, {
    timeout: REQUEST_TIMEOUT,
    headers: {
      ...HTTP_HEADERS,
      'Content-Type': 'application/json',
      Origin: 'https://www.deepl.com',
      Referer: 'https://www.deepl.com/',
    },
    validateStatus: status => status === 200,
  });

  const sentences = data?.result?.translations?.[0]?.beams?.[0]?.sentences;
  if (!Array.isArray(sentences) || !sentences.length) return null;
  return sentences.map(sentence => String(sentence.text ?? '')).join('\n');
}

// ─── Kagi Translate (free, no account on translate.kagi.com) ─────────────────
//
// The endpoint and payload shape can be overridden via env so it can adapt
// without code changes if the upstream signature ever changes.

const KAGI_TRANSLATE_URL = process.env.KAGI_TRANSLATE_URL || 'https://translate.kagi.com/api/translate';

async function translateViaKagi(text, from, to) {
  const body = {
    q: text,
    text,
    source: from,
    source_lang: from,
    target: to,
    target_lang: to,
    format: 'text',
  };

  const { data } = await axios.post(KAGI_TRANSLATE_URL, body, {
    timeout: REQUEST_TIMEOUT,
    headers: {
      ...HTTP_HEADERS,
      'Content-Type': 'application/json',
      Origin: 'https://translate.kagi.com',
      Referer: 'https://translate.kagi.com/',
    },
    validateStatus: status => status === 200,
  });

  return (
    data?.translatedText
    ?? data?.translated_text
    ?? data?.translation
    ?? data?.text
    ?? data?.result
    ?? null
  );
}

// ─── Registry ────────────────────────────────────────────────────────────────

const PROVIDERS = {
  google: { name: 'google', translate: translateViaGoogle },
  bing: { name: 'bing', translate: translateViaBing },
  deepl: { name: 'deepl', translate: translateViaDeepL },
  kagi: { name: 'kagi', translate: translateViaKagi },
};

// Test seam — flushes Bing session caches between unit tests.
export function __resetTranslationProvidersForTests() {
  bingSession = null;
  bingSessionExpiresAt = 0;
  bingSessionPromise = null;
}
