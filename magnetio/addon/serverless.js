import crypto from 'crypto';
import express from 'express';
import rateLimit from 'express-rate-limit';
import StremioAddonSdk from 'stremio-addon-sdk';
import { dummyManifest } from './lib/manifest.js';
import { getDefaultConfiguration, parseConfiguration } from './lib/configuration.js';
import { getAddonInterface } from './addon.js';
import { landingTemplate } from './lib/landingTemplate.js';
import { statsDashboard } from './lib/statsDashboard.js';
import { logger } from './lib/logger.js';
import { handleSubtitleProxyRequest } from './lib/subtitleProxy.js';
import { handleYifySubtitleProxy } from './lib/yifySubtitles.js';
import { handleTvSubtitlesProxy } from './lib/tvSubtitles.js';
import { handleCommunitySubtitlesProxy } from './lib/communitySubtitles.js';
import { handleTranslatedSubtitleProxy } from './lib/translatedSubtitles.js';
import { trackRequest, getStats } from './lib/analytics.js';
import { runWithClientIp } from './lib/requestContext.js';
import { streamTorrent } from './lib/torrentProxy.js';

const router = express.Router();

// Security and CORS headers
router.use((_req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  next();
});

const ROUTER_CACHE_TTL_MS = 1000 * 60 * 5;
const MAX_CACHED_ROUTERS = 64;
const addonRouterCache = new Map();
const { getRouter: getSdkRouter } = StremioAddonSdk;

router.get('/', (_req, res) => {
  res.setHeader('content-type', 'text/html');
  res.send(landingTemplate(dummyManifest(), getDefaultConfiguration()));
});

router.get('/configure', (_req, res) => {
  res.setHeader('content-type', 'text/html');
  res.send(landingTemplate(dummyManifest(), getDefaultConfiguration()));
});

router.get('/manifest.json', (_req, res) => {
  res.json(dummyManifest());
});

// ─── SEO: robots.txt and sitemap ─────────────────────────────────────────────

router.get('/.well-known/security.txt', (_req, res) => {
  res.type('text/plain').send([
    'Contact: mailto:info@peterdsp.dev',
    'Preferred-Languages: en, el',
    'Canonical: https://magnetio.peterdsp.dev/.well-known/security.txt',
    'Policy: https://github.com/peterdsp/Magnetio/blob/main/SECURITY.md',
  ].join('\n'));
});

router.get('/robots.txt', (_req, res) => {
  res.type('text/plain').send([
    'User-agent: *',
    'Allow: /',
    'Disallow: /proxy/',
    'Disallow: /swagger',
    'Disallow: /stats',
    '',
    'Sitemap: https://magnetio.peterdsp.dev/sitemap.xml',
  ].join('\n'));
});

router.get('/sitemap.xml', (_req, res) => {
  const now = new Date().toISOString().split('T')[0];
  res.type('application/xml').send([
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    '  <url>',
    '    <loc>https://magnetio.peterdsp.dev/</loc>',
    `    <lastmod>${now}</lastmod>`,
    '    <changefreq>weekly</changefreq>',
    '    <priority>1.0</priority>',
    '  </url>',
    '  <url>',
    '    <loc>https://magnetio.peterdsp.dev/configure</loc>',
    `    <lastmod>${now}</lastmod>`,
    '    <changefreq>weekly</changefreq>',
    '    <priority>0.8</priority>',
    '  </url>',
    '</urlset>',
  ].join('\n'));
});

const globalLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 120,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, try again later' },
});

const subtitleProxyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many subtitle requests, try again later' },
});

router.get('/proxy/subtitle/:id.srt', subtitleProxyLimiter, handleSubtitleProxyRequest);
router.get('/proxy/yify/:id.srt', subtitleProxyLimiter, handleYifySubtitleProxy);
router.get('/proxy/tvsubs/:id.srt', subtitleProxyLimiter, handleTvSubtitlesProxy);
router.get('/proxy/community/:id.srt', subtitleProxyLimiter, handleCommunitySubtitlesProxy);
router.get('/proxy/translated/:id.srt', subtitleProxyLimiter, handleTranslatedSubtitleProxy);

const proxyStreamLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many proxy stream requests, try again later' },
});

router.get('/proxy/stream/:infoHash/:fileIdx', proxyStreamLimiter, async (req, res) => {
  const { infoHash, fileIdx } = req.params;
  if (!/^[a-f0-9]{40}$/i.test(infoHash)) {
    return res.status(400).json({ error: 'Invalid infoHash' });
  }
  let proxyUrl = null;
  if (req.query.p) {
    try { proxyUrl = Buffer.from(req.query.p, 'base64url').toString('utf8'); } catch {
      return res.status(400).json({ error: 'Invalid proxy parameter encoding' });
    }
    if (proxyUrl && !/^socks[45]?:\/\//i.test(proxyUrl)) {
      return res.status(400).json({ error: 'Invalid proxy URL scheme (must be socks4:// or socks5://)' });
    }
  }
  try {
    await streamTorrent(infoHash, parseInt(fileIdx, 10) || 0, req, res, proxyUrl);
  } catch (err) {
    logger.error(`Proxy stream error: ${err.message}`);
    if (!res.headersSent) res.status(500).json({ error: 'Stream failed' });
  }
});

router.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'Magnetio', version: '1.1.5' });
});

router.get('/stats', (req, res, next) => {
  const user = process.env.METRICS_USER || 'admin';
  const pass = process.env.METRICS_PASSWORD || 'magnetio';
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Basic ')) {
    res.setHeader('WWW-Authenticate', 'Basic realm="Magnetio Stats"');
    return res.status(401).json({ error: 'Authentication required' });
  }
  const [u, p] = Buffer.from(auth.slice(6), 'base64').toString().split(':');
  if (u !== user || p !== pass) {
    return res.status(403).json({ error: 'Invalid credentials' });
  }
  next();
}, async (req, res) => {
  const stats = await getStats();
  const wantsHtml = (req.headers.accept || '').includes('text/html');
  if (!wantsHtml) return res.json(stats);
  res.setHeader('content-type', 'text/html');
  res.send(statsDashboard(stats));
});

router.get('/:configuration', (req, res) => {
  try {
    const config = parseConfiguration(req.params.configuration);
    res.setHeader('content-type', 'text/html');
    res.send(landingTemplate(dummyManifest(), config));
  } catch (err) {
    logger.error(`Configuration page error: ${err.message}`);
    res.status(500).send('Unable to render configuration');
  }
});

router.get('/:configuration/configure', (req, res) => {
  try {
    const config = parseConfiguration(req.params.configuration);
    res.setHeader('content-type', 'text/html');
    res.send(landingTemplate(dummyManifest(), config));
  } catch (err) {
    logger.error(`Configuration page error: ${err.message}`);
    res.status(500).send('Unable to render configuration');
  }
});

router.use('/:configuration', globalLimiter, async (req, res, next) => {
  const clientIp = req.ip || req.connection?.remoteAddress;

  runWithClientIp(clientIp, async () => {
    try {
      const configHash = hashConfiguration(req.params.configuration);
      const pathAfterConfig = req.path.replace(/^\/[^/]+/, '');
      const type = pathAfterConfig.match(/^\/(stream|catalog|subtitle|meta)\b/)?.[1] || 'page';
      trackRequest(type, configHash).catch(() => {});

      const addonRouter = await getConfiguredAddonRouter(
        req.params.configuration,
        getPublicBaseUrl(req),
      );
      addonRouter(req, res, next);
    } catch (err) {
      logger.error(`Addon routing error: ${err.message}`);
      res.status(500).json({ error: err.message });
    }
  });
});

export const serverless = router;

async function getConfiguredAddonRouter(configString, publicBaseUrl) {
  purgeExpiredRouters();

  const cacheKey = hashConfiguration(`${configString}|${publicBaseUrl}`);
  const cached = addonRouterCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) {
    cached.expiresAt = Date.now() + ROUTER_CACHE_TTL_MS;
    addonRouterCache.delete(cacheKey);
    addonRouterCache.set(cacheKey, cached);
    return cached.router;
  }

  const config = parseConfiguration(configString);
  config._publicBaseUrl = publicBaseUrl;
  const addonInterface = await getAddonInterface(config);
  const addonRouter = getSdkRouter(addonInterface);

  addonRouterCache.set(cacheKey, {
    router: addonRouter,
    expiresAt: Date.now() + ROUTER_CACHE_TTL_MS,
  });

  while (addonRouterCache.size > MAX_CACHED_ROUTERS) {
    const oldestKey = addonRouterCache.keys().next().value;
    addonRouterCache.delete(oldestKey);
  }

  return addonRouter;
}

function purgeExpiredRouters() {
  const now = Date.now();
  for (const [key, value] of addonRouterCache.entries()) {
    if (value.expiresAt <= now) {
      addonRouterCache.delete(key);
    }
  }
}

function hashConfiguration(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function getPublicBaseUrl(req) {
  const envUrl = process.env.ADDON_PUBLIC_URL || process.env.PUBLIC_URL;
  if (envUrl) return String(envUrl).replace(/\/$/, '');
  return `${req.protocol}://${req.get('host')}`;
}
