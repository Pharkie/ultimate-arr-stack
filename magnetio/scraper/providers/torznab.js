/**
 * Torznab provider -- queries any Torznab-compatible endpoint (Jackett, Prowlarr, etc.).
 * Conditionally active: returns [] when no torznabUrl is configured.
 */
import * as cheerio from 'cheerio';
import { get } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { logger } from '../lib/logger.js';

export const id   = 'torznab';
export const name = 'Torznab';

const CATEGORY_MOVIES = '2000';
const CATEGORY_TV     = '5000';

export async function scrape(meta) {
  const baseUrl = meta.torznabUrl;
  const apiKey  = meta.torznabApiKey;
  if (!baseUrl) return [];

  if (!isUrlSafe(baseUrl)) {
    logger.warn('[Torznab] Rejected unsafe or invalid URL');
    return [];
  }

  try {
    const params = buildParams(meta, apiKey);

    const { data } = await get(baseUrl, {
      limiterKey: 'torznab',
      timeout: 15_000,
      params,
    });

    const $ = cheerio.load(data, { xmlMode: true });
    const results = [];

    $('item').each((_, el) => {
      const item = $(el);
      const record = normalise(item, meta);
      if (record) results.push(record);
    });

    const redactedUrl = (() => { try { return new URL(baseUrl).origin; } catch { return '(invalid)'; } })();
    logger.info(`[Torznab] ${results.length} results from ${redactedUrl}`);
    return results;
  } catch (err) {
    logger.warn(`[Torznab] ${err.message}`);
    return [];
  }
}

function buildParams(meta, apiKey) {
  const params = {};
  if (apiKey) params.apikey = apiKey;

  if (meta.imdbId && meta.type === 'movie') {
    params.t = 'movie';
    params.imdbid = meta.imdbId;
  } else if (meta.imdbId && (meta.type === 'series' || meta.type === 'anime')) {
    params.t = 'tvsearch';
    params.imdbid = meta.imdbId;
    if (meta.season != null) params.season = meta.season;
    if (meta.episode != null) params.ep = meta.episode;
  } else {
    params.t = 'search';
    params.q = buildSearchQuery(meta);
    params.cat = meta.type === 'movie' ? CATEGORY_MOVIES : CATEGORY_TV;
  }

  return params;
}

function normalise(item, meta) {
  const title = item.find('title').text().trim();
  if (!title) return null;

  const infoHash = extractInfoHash(item);
  if (!infoHash) return null;

  const seeders  = attrValue(item, 'seeders');
  const peers    = attrValue(item, 'peers');
  const sizeEl   = item.find('size').text();
  const encLen   = item.find('enclosure').attr('length');

  const parsed = parseTitle(title);

  const parsedSeeders = parseInt(seeders, 10);
  const parsedPeers   = parseInt(peers, 10);
  const parsedSize    = parseInt(sizeEl || encLen || '0', 10);

  return {
    infoHash,
    title,
    seeders:  Number.isFinite(parsedSeeders) ? parsedSeeders : 0,
    leechers: Number.isFinite(parsedPeers) ? Math.max(0, parsedPeers - (parsedSeeders || 0)) : 0,
    size:     Number.isFinite(parsedSize) ? parsedSize : 0,
    provider: 'Torznab',
    imdbId:   meta.imdbId || null,
    ...parsed,
  };
}

function extractInfoHash(item) {
  const hashAttr = attrValue(item, 'infohash');
  if (hashAttr) return hashAttr.toLowerCase();

  const link = item.find('link').text().trim();
  const magnetMatch = link.match(/magnet:\?xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  if (magnetMatch) {
    const hash = magnetMatch[1];
    return hash.length === 32 ? base32ToHex(hash) : hash.toLowerCase();
  }

  const comments = item.find('comments').text().trim();
  const commentsMatch = comments.match(/magnet:\?xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  if (commentsMatch) {
    const hash = commentsMatch[1];
    return hash.length === 32 ? base32ToHex(hash) : hash.toLowerCase();
  }

  return null;
}

function attrValue(item, attrName) {
  const el = item.find(`torznab\\:attr[name="${attrName}"], attr[name="${attrName}"]`);
  return el.length ? el.attr('value') : null;
}

function isUrlSafe(urlStr) {
  try {
    const parsed = new URL(urlStr);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
    const host = parsed.hostname;
    if (host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '0.0.0.0') return false;
    if (host.startsWith('10.')) return false;
    if (host.startsWith('192.168.')) return false;
    if (host.startsWith('169.254.')) return false;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(host)) return false;
    if (host.endsWith('.local') || host.endsWith('.internal')) return false;
    if (host.includes('metadata.google') || host.includes('metadata.aws')) return false;
    return true;
  } catch {
    return false;
  }
}

function base32ToHex(base32) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const c of base32.toUpperCase()) {
    const val = alphabet.indexOf(c);
    if (val === -1) return null;
    bits += val.toString(2).padStart(5, '0');
  }
  let hex = '';
  for (let i = 0; i + 4 <= bits.length; i += 4) {
    hex += parseInt(bits.substring(i, i + 4), 2).toString(16);
  }
  return hex.length === 40 ? hex : null;
}
