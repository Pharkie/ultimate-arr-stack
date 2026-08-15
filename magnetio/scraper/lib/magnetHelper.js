/**
 * Shared magnet/infoHash parsing utilities.
 */

/**
 * Extract an infoHash from a magnet URI string.
 * Handles both hex (40-char) and base32 (32-char) encoded btih values.
 *
 * @param {string} magnet
 * @returns {string|null} lowercase 40-char hex infoHash, or null
 */
export function extractInfoHash(magnet = '') {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  if (!match) return null;
  const raw = match[1];
  if (raw.length === 32) return base32ToHex(raw);
  return raw.toLowerCase();
}

/**
 * Convert a base32-encoded string to a 40-char lowercase hex string.
 * Returns null if the input is invalid or does not produce exactly 40 hex chars.
 *
 * @param {string} str  32-char base32 string
 * @returns {string|null}
 */
export function base32ToHex(str) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const c of str.toUpperCase()) {
    const val = alphabet.indexOf(c);
    if (val === -1) return null;
    bits += val.toString(2).padStart(5, '0');
  }
  let hex = '';
  for (let i = 0; i + 4 <= bits.length; i += 4) {
    hex += parseInt(bits.slice(i, i + 4), 2).toString(16);
  }
  return hex.length === 40 ? hex : null;
}

/**
 * Parse a human-readable file size string (e.g. "1.5 GB") into bytes.
 *
 * @param {string} str
 * @returns {number}
 */
export function parseSize(str) {
  if (!str) return 0;
  const m = str.match(/([\d.]+)\s*(B|KB|MB|GB|TB)/i);
  if (!m) return 0;
  const val   = parseFloat(m[1]);
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(val * (units[m[2].toLowerCase()] ?? 1));
}
