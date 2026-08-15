// Language code → display name mapping
export const LANGUAGES = {
  'en':    'English',
  'es':    'Spanish',
  'pt':    'Portuguese',
  'fr':    'French',
  'de':    'German',
  'it':    'Italian',
  'nl':    'Dutch',
  'ru':    'Russian',
  'pl':    'Polish',
  'ja':    'Japanese',
  'ko':    'Korean',
  'zh':    'Chinese',
  'ar':    'Arabic',
  'tr':    'Turkish',
  'hi':    'Hindi',
  'ta':    'Tamil',
  'te':    'Telugu',
  'ml':    'Malayalam',
  'kn':    'Kannada',
  'sv':    'Swedish',
  'da':    'Danish',
  'fi':    'Finnish',
  'no':    'Norwegian',
  'cs':    'Czech',
  'sk':    'Slovak',
  'hu':    'Hungarian',
  'ro':    'Romanian',
  'bg':    'Bulgarian',
  'el':    'Greek',
  'sq':    'Albanian',
  'he':    'Hebrew',
  'uk':    'Ukrainian',
  'multi': 'Multi-Audio',
};

const ISO_639_2 = {
  ar: 'ara',
  bg: 'bul',
  cs: 'ces',
  da: 'dan',
  de: 'deu',
  el: 'ell',
  en: 'eng',
  es: 'spa',
  fi: 'fin',
  fr: 'fra',
  he: 'heb',
  hi: 'hin',
  hu: 'hun',
  it: 'ita',
  kn: 'kan',
  ml: 'mal',
  ta: 'tam',
  te: 'tel',
  ja: 'jpn',
  ko: 'kor',
  nl: 'nld',
  no: 'nor',
  pl: 'pol',
  pt: 'por',
  ro: 'ron',
  ru: 'rus',
  sk: 'slk',
  sq: 'sqi',
  sv: 'swe',
  tr: 'tur',
  uk: 'ukr',
  zh: 'zho',
};

// Language flags for display
export const LANGUAGE_FLAGS = {
  'en': '🇬🇧',
  'es': '🇪🇸',
  'pt': '🇵🇹',
  'fr': '🇫🇷',
  'de': '🇩🇪',
  'it': '🇮🇹',
  'nl': '🇳🇱',
  'ru': '🇷🇺',
  'pl': '🇵🇱',
  'ja': '🇯🇵',
  'ko': '🇰🇷',
  'zh': '🇨🇳',
  'ar': '🇸🇦',
  'tr': '🇹🇷',
  'hi': '🇮🇳',
  'ta': '🇮🇳',
  'te': '🇮🇳',
  'ml': '🇮🇳',
  'kn': '🇮🇳',
  'sv': '🇸🇪',
  'da': '🇩🇰',
  'fi': '🇫🇮',
  'no': '🇳🇴',
  'cs': '🇨🇿',
  'hu': '🇭🇺',
  'ro': '🇷🇴',
  'bg': '🇧🇬',
  'el': '🇬🇷',
  'sq': '🇦🇱',
  'he': '🇮🇱',
  'uk': '🇺🇦',
  'multi': '🌍',
};

/**
 * Get the display name for a language code.
 */
export function getLanguageName(code) {
  return LANGUAGES[code.toLowerCase()] || code.toUpperCase();
}

/**
 * Get the flag emoji for a language code.
 */
export function getLanguageFlag(code) {
  return LANGUAGE_FLAGS[code.toLowerCase()] || '';
}

export function toSubtitleLanguageCode(code) {
  const normalized = String(code || '').trim().toLowerCase();
  if (!normalized) return 'eng';
  if (normalized.length === 3) return normalized;
  return ISO_639_2[normalized] || normalized;
}

/**
 * Extract language codes from a torrent record.
 * For anime content, Japanese is excluded by default (audio is usually
 * Japanese; the "language" tag refers to subtitle language).
 */
export function getLanguages(record, isAnime = false) {
  const langs = new Set();

  if (record.languages && Array.isArray(record.languages)) {
    for (const l of record.languages) {
      if (isAnime && l === 'ja') continue;
      langs.add(l);
    }
  }

  if (record.dubbed) langs.add('dubbed');

  return Array.from(langs);
}
