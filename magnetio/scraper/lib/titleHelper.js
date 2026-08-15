/**
 * Shared torrent title parsing utilities.
 * Extracts quality, codec, size, language hints from raw torrent names.
 */

const QUALITY_PATTERNS = [
  { re: /\b(8k|7680[xX]4320)\b/i,              quality: '8k'    },
  { re: /\b(2160p|4k|uhd)\b/i,                  quality: '4k'    },
  { re: /\b1080p\b/i,                            quality: '1080p' },
  { re: /\b720p\b/i,                             quality: '720p'  },
  { re: /\b480p\b/i,                             quality: '480p'  },
  { re: /\b(cam|camrip|ts|telesync|telecine|hdcam)\b/i, quality: 'cam' },
];

const CODEC_PATTERNS = [
  { re: /\b(x265|hevc|h\.?265)\b/i, codec: 'HEVC' },
  { re: /\b(x264|avc|h\.?264)\b/i,  codec: 'AVC'  },
  { re: /\bav1\b/i,                  codec: 'AV1'  },
];

const SOURCE_PATTERNS = [
  { re: /\b(bluray|blu-ray|bdrip|brrip)\b/i,  source: 'BluRay'   },
  { re: /\b(webrip|web-rip)\b/i,               source: 'WEBRip'   },
  { re: /\b(webdl|web-dl|web)\b/i,             source: 'WEB-DL'   },
  { re: /\bhdrip\b/i,                           source: 'HDRip'    },
  { re: /\bdvdrip\b/i,                          source: 'DVDRip'   },
  { re: /\bhdtv\b/i,                            source: 'HDTV'     },
];

const LANGUAGE_PATTERNS = [
  { re: /\bmulti\b/i,     lang: 'multi' },
  { re: /\bfrench\b/i,    lang: 'fr'    },
  { re: /\bspanish\b/i,   lang: 'es'    },
  { re: /\bportuguese\b/i,lang: 'pt'    },
  { re: /\bitalian\b/i,   lang: 'it'    },
  { re: /\bgerman\b/i,    lang: 'de'    },
  { re: /\brussian\b/i,   lang: 'ru'    },
  { re: /\bkorean\b/i,    lang: 'ko'    },
  { re: /\bjapanese\b/i,  lang: 'ja'    },
  { re: /\bchinese\b/i,   lang: 'zh'    },
  { re: /\barabic\b/i,    lang: 'ar'    },
  { re: /\bturkish\b/i,   lang: 'tr'    },
  { re: /\bhindi\b/i,     lang: 'hi'    },
  { re: /\b(tamil|tam)\b/i,       lang: 'ta' },
  { re: /\b(telugu|tel)\b/i,      lang: 'te' },
  { re: /\bmalayalam\b/i,         lang: 'ml' },
  { re: /\bkannada\b/i,           lang: 'kn' },
  { re: /\b(greek|ellinika|ελληνικά)\b/i, lang: 'el' },
  { re: /\b(albanian|shqip)\b/i, lang: 'sq' },
  { re: /\bdubbed\b/i,    lang: 'dubbed'},
];

export function parseTitle(title) {
  if (!title) return {};

  let quality = null;
  for (const { re, quality: q } of QUALITY_PATTERNS) {
    if (re.test(title)) { quality = q; break; }
  }

  let codec = null;
  for (const { re, codec: c } of CODEC_PATTERNS) {
    if (re.test(title)) { codec = c; break; }
  }

  let source = null;
  for (const { re, source: s } of SOURCE_PATTERNS) {
    if (re.test(title)) { source = s; break; }
  }

  const languages = [];
  for (const { re, lang } of LANGUAGE_PATTERNS) {
    if (re.test(title)) languages.push(lang);
  }
  // Default to English if no language detected
  if (!languages.length && !/\b(dubbed|multi)\b/i.test(title)) {
    languages.push('en');
  }

  const hdr = /\b(hdr|hdr10|dolby.?vision|dv)\b/i.test(title);
  const bitdepth = hdr ? '10bit' : (/\b10.?bit\b/i.test(title) ? '10bit' : null);

  return { quality, codec, source, languages, hdr, bitdepth };
}

/**
 * Build a search query string for a given piece of content.
 * For series: "Show Name S01E02"
 * For movies: "Movie Name 2024"
 */
export function buildSearchQuery(meta) {
  if (meta.type === 'series' && meta.season != null && meta.episode != null) {
    const s = String(meta.season).padStart(2, '0');
    const e = String(meta.episode).padStart(2, '0');
    return `${meta.name} S${s}E${e}`;
  }
  if (meta.year) return `${meta.name} ${meta.year}`;
  return meta.name;
}
