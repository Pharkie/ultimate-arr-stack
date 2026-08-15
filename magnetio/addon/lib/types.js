// Content types supported by Magnetio
export const ContentType = {
  MOVIE: 'movie',
  SERIES: 'series',
  ANIME: 'anime',
};

// Torrent providers / scrapers
export const TorrentProvider = {
  YTS: 'yts',
  EZTV: 'eztv',
  TORRENTGALAXY: 'torrentgalaxy',
  THEPIRATEBAY: 'thepiratebay',
  KICKASSTORRENTS: 'kickasstorrents',
  LEETX: '1337x',
  NYAA: 'nyaa',
  ANIMESATURN: 'animesaturn',
  RUTOR: 'rutor',
  RUTRACKER: 'rutracker',
  LIMETORRENTS: 'limetorrents',
  BITSEARCH: 'bitsearch',
  BT4G: 'bt4g',
  BTDIG: 'btdig',
  GLOTORRENTS: 'glotorrents',
  TORLOCK: 'torlock',
  TORRENTDOWNLOADS: 'torrentdownloads',
  TORZNAB: 'torznab',
};

// Sort options exposed in configuration
export const SortType = {
  QUALITY_THEN_SEEDERS: 'qualityseeders',
  QUALITY_THEN_SIZE:    'qualitysize',
  SEEDERS:              'seeders',
  SIZE:                 'size',
};

// Quality tiers (high → low)
export const Quality = {
  UHD_8K:  '8k',
  UHD_4K:  '4k',
  FHD:     '1080p',
  HD:      '720p',
  SD:      '480p',
  CAM:     'cam',
  UNKNOWN: 'unknown',
};

// Size limit labels
export const SizeLimit = {
  GB1:  '1gb',
  GB2:  '2gb',
  GB3:  '3gb',
  GB5:  '5gb',
  GB10: '10gb',
  GB20: '20gb',
  GB50: '50gb',
};
