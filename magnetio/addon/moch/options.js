/**
 * Central registry of all supported debrid / cloud-download services.
 *
 * Each entry describes:
 *   id         – URL-safe identifier used in catalog IDs
 *   configKey  – the config property that holds this service's API key
 *   shortName  – abbreviated name shown in the addon title
 *   name       – full display name
 *   hasCatalog – whether the service exposes a browsable catalog
 */
export const MochOptions = {
  realdebrid: {
    id:         'rd',
    configKey:  'realDebridApiKey',
    shortName:  'RD',
    name:       'Real-Debrid',
    hasCatalog: true,
  },
  premiumize: {
    id:         'pm',
    configKey:  'premiumizeApiKey',
    shortName:  'PM',
    name:       'Premiumize',
    hasCatalog: true,
  },
  alldebrid: {
    id:         'ad',
    configKey:  'allDebridApiKey',
    shortName:  'AD',
    name:       'AllDebrid',
    hasCatalog: false,
  },
  debridlink: {
    id:         'dl',
    configKey:  'debridLinkApiKey',
    shortName:  'DL',
    name:       'DebridLink',
    hasCatalog: true,
  },
  easydebrid: {
    id:         'ed',
    configKey:  'easyDebridApiKey',
    shortName:  'ED',
    name:       'EasyDebrid',
    hasCatalog: false,
  },
  offcloud: {
    id:         'oc',
    configKey:  'offcloudApiKey',
    shortName:  'OC',
    name:       'Offcloud',
    hasCatalog: false,
  },
  torbox: {
    id:         'tb',
    configKey:  'torboxApiKey',
    shortName:  'TB',
    name:       'TorBox',
    hasCatalog: true,
  },
  putio: {
    id:         'pu',
    configKey:  'putioApiKey',
    shortName:  'PU',
    name:       'Put.io',
    hasCatalog: true,
  },
};

/** Minimum API-key length to be considered valid. */
export const MIN_API_KEY_LENGTH = 15;
