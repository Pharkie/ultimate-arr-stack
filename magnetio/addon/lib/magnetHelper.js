import axios from 'axios';
import { logger } from './logger.js';

// Public tracker list sources
const TRACKER_SOURCES = [
  'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt',
  'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt',
];

let _bestTrackers = [];

/**
 * Fetch and cache the best public trackers.
 * Called once at server startup.
 */
export async function initBestTrackers() {
  for (const url of TRACKER_SOURCES) {
    try {
      const { data } = await axios.get(url, { timeout: 10_000 });
      _bestTrackers = data
        .split('\n')
        .map(t => t.trim())
        .filter(t => t.startsWith('udp://') || t.startsWith('http'));
      logger.info(`Loaded ${_bestTrackers.length} trackers from ${url}`);
      return;
    } catch (err) {
      logger.warn(`Failed to fetch trackers from ${url}: ${err.message}`);
    }
  }
  logger.warn('Could not load any trackers; using empty list');
}

/**
 * Build a magnet URI from an infoHash, optional display name, and trackers.
 */
export function buildMagnet(infoHash, displayName, extraTrackers = []) {
  const dn       = displayName ? `&dn=${encodeURIComponent(displayName)}` : '';
  const trackers = [...new Set([...extraTrackers, ..._bestTrackers])]
    .slice(0, 20)
    .map(t => `&tr=${encodeURIComponent(t)}`)
    .join('');
  return `magnet:?xt=urn:btih:${infoHash}${dn}${trackers}`;
}

/**
 * Return the current list of best trackers.
 */
export function getBestTrackers() {
  return _bestTrackers;
}
