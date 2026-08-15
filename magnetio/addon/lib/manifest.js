import { getManifestOverride } from './configuration.js';
import { MochOptions } from '../moch/options.js';

const ADDON_ID      = 'com.magnetio.addon';
const ADDON_VERSION = '1.1.5';
const ADDON_NAME    = 'Magnetio';
const ASSET_BASE_URL = `${(process.env.ADDON_PUBLIC_URL || 'https://magnetio.peterdsp.dev').replace(/\/$/, '')}/static`;
const ADDON_LOGO = `${ASSET_BASE_URL}/magnetio-logo.svg`;
const ADDON_BACKGROUND = `${ASSET_BASE_URL}/magnetio-wordmark.svg`;

/**
 * Build the full addon manifest for a given config.
 */
export function manifest(config) {
  const override = getManifestOverride(config?.overrideId);

  return {
    id:          override?.id          ?? ADDON_ID,
    version:     ADDON_VERSION,
    name:        override?.name        ?? getName(config),
    description: override?.description ?? getDescription(config),
    logo:        override?.logo        ?? ADDON_LOGO,
    background:  ADDON_BACKGROUND,
    types:       ['movie', 'series', 'anime'],
    resources:   getResources(),
    catalogs:    getCatalogs(config),
    behaviorHints: {
      configurable:      true,
      configurationRequired: false,
      p2p:               true,
    },
    stremioAddonsConfig: {
      issuer: 'https://stremio-addons.net',
      signature: 'eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0..HyLU28BPtTd06szaQlmclQ._4Km4R8rkgZfnwV5BCt1h5h9AzZ8ZSszesrBMq0Wih1O1jnC49ny_zUtFuSbfUj8WdVoqX0wvCHKqEpi5mNYGtYRD_IM9Qr8Qz3wFb2Qsa7Hw53ocomqPJQuH5_Hmonn.-g1fCVlhSWdoY3Nyz3zdVg',
    },
  };
}

/**
 * Minimal manifest returned before a user configures the addon.
 */
export function dummyManifest() {
  return {
    id:          ADDON_ID,
    version:     ADDON_VERSION,
    name:        ADDON_NAME,
    description: `${ADDON_NAME} - configure sources, subtitles and debrid services at /configure`,
    logo:        ADDON_LOGO,
    background:  ADDON_BACKGROUND,
    types:       ['movie', 'series', 'anime'],
    resources:   getResources(),
    catalogs:    [],
    behaviorHints: {
      configurable: true,
      p2p: true,
    },
    stremioAddonsConfig: {
      issuer: 'https://stremio-addons.net',
      signature: 'eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0..HyLU28BPtTd06szaQlmclQ._4Km4R8rkgZfnwV5BCt1h5h9AzZ8ZSszesrBMq0Wih1O1jnC49ny_zUtFuSbfUj8WdVoqX0wvCHKqEpi5mNYGtYRD_IM9Qr8Qz3wFb2Qsa7Hw53ocomqPJQuH5_Hmonn.-g1fCVlhSWdoY3Nyz3zdVg',
    },
  };
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getName(config) {
  const enabledMochs = getEnabledMochs(config);
  if (!enabledMochs.length) return ADDON_NAME;
  return `${ADDON_NAME} ${enabledMochs.map(m => `+${m.shortName}`).join('')}`;
}

function getDescription(config) {
  const enabledMochs = getEnabledMochs(config);
  const debridPart = enabledMochs.length
    ? `\nDebrid services: ${enabledMochs.map(m => m.name).join(', ')}.`
    : '';
  return (
    `Aggregates streams from configurable sources. Includes subtitle support when available.` +
    debridPart +
    `\n\nConfigure at your Stremio settings page.`
  );
}

function getCatalogs(config) {
  const debridCatalogsEnabled = config?.debridCatalogs !== false;
  const debridCatalogs = debridCatalogsEnabled
    ? getEnabledMochs(config).flatMap(moch =>
        moch.hasCatalog
          ? [
              { id: `${moch.id}_movie`,  type: 'movie',  name: `${moch.name} - Movies`  },
              { id: `${moch.id}_series`, type: 'series', name: `${moch.name} - Series` },
            ]
          : []
      )
    : [];

  const similarCatalogs = config?.tmdbApiKey
    ? [
        {
          id: 'magnetio_similar_movie',
          type: 'movie',
          name: 'Magnetio - Similar',
          extra: [{ name: 'genre', isRequired: true }],
        },
        {
          id: 'magnetio_similar_series',
          type: 'series',
          name: 'Magnetio - Similar',
          extra: [{ name: 'genre', isRequired: true }],
        },
      ]
    : [];

  return [...debridCatalogs, ...similarCatalogs];
}

function getResources() {
  return [
    {
      name: 'stream',
      types: ['movie', 'series', 'anime'],
      idPrefixes: ['tt', 'kitsu'],
    },
    {
      name: 'subtitles',
      types: ['movie', 'series', 'anime'],
      idPrefixes: ['tt', 'kitsu'],
    },
    {
      name: 'catalog',
      types: ['movie', 'series'],
      idPrefixes: ['rd', 'pm', 'ad', 'dl', 'ed', 'oc', 'tb', 'pu', 'magnetio_similar'],
    },
    {
      name: 'meta',
      types: ['movie', 'series'],
      idPrefixes: ['rd', 'pm', 'ad', 'dl', 'ed', 'oc', 'tb', 'pu'],
    },
  ];
}

function getEnabledMochs(config) {
  if (!config) return [];
  return Object.values(MochOptions).filter(moch => config[moch.configKey]);
}
