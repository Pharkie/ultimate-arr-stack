const QUALITIES = [
  ['4k', '4K'],
  ['1080p', '1080p'],
  ['720p', '720p'],
  ['480p', '480p'],
  ['cam', 'CAM'],
];

const LANGUAGES = [
  ['en', 'English'],
  ['es', 'Spanish'],
  ['pt', 'Portuguese'],
  ['fr', 'French'],
  ['de', 'German'],
  ['it', 'Italian'],
  ['ru', 'Russian'],
  ['ja', 'Japanese'],
  ['ko', 'Korean'],
  ['zh', 'Chinese'],
  ['ar', 'Arabic'],
  ['tr', 'Turkish'],
  ['hi', 'Hindi'],
  ['ta', 'Tamil'],
  ['te', 'Telugu'],
  ['ml', 'Malayalam'],
  ['kn', 'Kannada'],
  ['el', 'Greek'],
  ['sq', 'Albanian'],
];

const DEBRID_FIELDS = [
  ['rd', 'Real-Debrid', 'https://real-debrid.com/apitoken'],
  ['pm', 'Premiumize', 'https://www.premiumize.me/account'],
  ['ad', 'AllDebrid', 'https://alldebrid.com/apikeys'],
  ['dl', 'DebridLink', 'https://debrid-link.com/webapp/apikey'],
  ['ed', 'EasyDebrid', 'https://easydebrid.com/settings'],
  ['oc', 'Offcloud', 'https://offcloud.com/#/account'],
  ['tb', 'TorBox', 'https://torbox.app/settings'],
  ['pu', 'Put.io', 'https://put.io/oauth/apps'],
];

const SVG_SUN = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>';
const SVG_MOON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';
const SVG_EYE = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
const SVG_EYE_OFF = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>';

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

export function landingTemplate(manifest, initialConfig = {}) {
  const brandLogo = escapeHtml(manifest.logo || '');
  const brandBackground = escapeHtml(manifest.background || manifest.logo || '');
  const initialState = escapeJsonForHtml({
    sort: initialConfig.sort ?? 'qualityseeders',
    limit: initialConfig.limit ?? 10,
    qualities: initialConfig.qualities ?? [],
    languages: initialConfig.languages ?? [],
    subtitleLanguages: initialConfig.subtitleLanguages ?? ['en'],
    prewarmDebrid: initialConfig.prewarmDebrid ?? true,
    prewarmLimit: initialConfig.prewarmLimit ?? 3,
    debridCatalogs: initialConfig.debridCatalogs ?? true,
    tmdbApiKey: initialConfig.tmdbApiKey ?? '',
    torznabUrl: initialConfig.torznabUrl ?? '',
    torznabApiKey: initialConfig.torznabApiKey ?? '',
    proxyUrl: initialConfig.proxyUrl ?? '',
    realDebridApiKey: initialConfig.realDebridApiKey ?? '',
    premiumizeApiKey: initialConfig.premiumizeApiKey ?? '',
    allDebridApiKey: initialConfig.allDebridApiKey ?? '',
    debridLinkApiKey: initialConfig.debridLinkApiKey ?? '',
    easyDebridApiKey: initialConfig.easyDebridApiKey ?? '',
    offcloudApiKey: initialConfig.offcloudApiKey ?? '',
    torboxApiKey: initialConfig.torboxApiKey ?? '',
    putioApiKey: initialConfig.putioApiKey ?? '',
  });

  return `<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${escapeHtml(manifest.name)} - Self-Hosted Stremio Addon with 22+ Providers and Debrid Support</title>
  <meta name="description" content="Magnetio is a free, open-source, self-hosted Stremio addon with 22+ torrent providers, 8 debrid services, Torznab/Jackett/Prowlarr support, TMDB recommendations, and subtitle sync. Stream movies, series, and anime instantly." />
  <meta name="keywords" content="Magnetio, Stremio addon, self-hosted, torrent, debrid, Real-Debrid, Premiumize, AllDebrid, TorBox, Jackett, Prowlarr, Torznab, streaming, movies, series, anime, open source, TMDB" />
  <meta name="author" content="peterdsp" />
  <meta name="robots" content="index, follow" />
  <link rel="canonical" href="https://magnetio.peterdsp.dev/" />

  <!-- Open Graph -->
  <meta property="og:type" content="website" />
  <meta property="og:title" content="Magnetio - Self-Hosted Stremio Addon" />
  <meta property="og:description" content="Stream anything with 22+ providers, 8 debrid services, Torznab support, and TMDB recommendations. Fully self-hosted, your API keys never leave your server." />
  <meta property="og:url" content="https://magnetio.peterdsp.dev/" />
  <meta property="og:site_name" content="Magnetio" />
  <meta property="og:image" content="${brandLogo}" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />

  <!-- Twitter Card -->
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="Magnetio - Self-Hosted Stremio Addon" />
  <meta name="twitter:description" content="Stream anything with 22+ providers, 8 debrid services, and Torznab support. Open source and self-hosted." />
  <meta name="twitter:image" content="${brandLogo}" />
  <link rel="icon" href="${brandLogo}" type="image/svg+xml" />
  <link rel="apple-touch-icon" href="${brandLogo}" />

  <!-- JSON-LD Structured Data -->
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": "Magnetio",
    "applicationCategory": "MultimediaApplication",
    "operatingSystem": "Docker, Node.js",
    "url": "https://magnetio.peterdsp.dev",
    "description": "Self-hosted Stremio addon with 22+ torrent providers, 8 debrid services, Torznab/Jackett/Prowlarr support, TMDB recommendations, and subtitle sync pipeline.",
    "offers": {
      "@type": "Offer",
      "price": "0",
      "priceCurrency": "USD"
    },
    "author": {
      "@type": "Person",
      "name": "peterdsp",
      "url": "https://github.com/peterdsp"
    },
    "softwareVersion": "${escapeHtml(manifest.version)}",
    "license": "https://github.com/peterdsp/Magnetio/blob/main/LICENSE",
    "codeRepository": "https://github.com/peterdsp/Magnetio",
    "featureList": [
      "22+ torrent providers",
      "8 debrid services (Real-Debrid, Premiumize, AllDebrid, TorBox, etc.)",
      "Torznab/Jackett/Prowlarr integration",
      "TMDB similar content recommendations",
      "Subtitle search and sync pipeline",
      "Background cache prewarm",
      "Self-hosted on Raspberry Pi or any server"
    ]
  }
  </script>

  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet" />
  <style>
    html { scroll-behavior: smooth; }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg: #06070a;
      --surface: rgba(255,255,255,0.04);
      --surface-solid: #0d0e12;
      --border: rgba(255,255,255,0.08);
      --border-hover: rgba(255,255,255,0.15);
      --text-primary: #e2e8f0;
      --text-secondary: #94a3b8;
      --text-muted: rgba(255,255,255,0.3);
      --accent: #a78bfa;
      --accent-hover: #c4b5fd;
      --gradient-start: #667eea;
      --gradient-end: #764ba2;
      --success: #34d399;
      --input-bg: rgba(255,255,255,0.05);
      --chip-bg: rgba(255,255,255,0.06);
      --chip-bg-active: rgba(167,139,250,0.15);
      --chip-border-active: #a78bfa;
      --code-bg: rgba(0,0,0,0.4);
    }

    body {
      min-height: 100vh;
      color: var(--text-primary);
      background: var(--bg);
      font-family: "Inter", -apple-system, BlinkMacSystemFont, sans-serif;
      overflow-x: hidden;
    }

    /* ---- Navbar ---- */
    .navbar {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      z-index: 1000;
      padding: 0 32px;
      height: 64px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      background: rgba(6,7,10,0.8);
      backdrop-filter: blur(20px);
      border-bottom: 1px solid var(--border);
    }

    .nav-left {
      display: flex;
      align-items: center;
      gap: 12px;
    }

    .nav-logo {
      width: 32px;
      height: 32px;
      display: block;
      flex-shrink: 0;
    }

    .nav-brand {
      font-weight: 800;
      font-size: 1.15rem;
      letter-spacing: -0.04em;
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end));
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }

    .nav-version {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.7rem;
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
      padding: 3px 10px;
      border-radius: 999px;
    }

    .nav-cta {
      display: inline-flex;
      align-items: center;
      padding: 8px 22px;
      border-radius: 999px;
      border: none;
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end));
      color: #fff;
      font-family: "Inter", sans-serif;
      font-weight: 600;
      font-size: 0.85rem;
      cursor: pointer;
      transition: opacity 0.2s, transform 0.2s;
      text-decoration: none;
    }

    .nav-cta:hover { opacity: 0.9; transform: translateY(-1px); }

    /* ---- Hero ---- */
    .hero {
      position: relative;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 120px 24px 80px;
      overflow: hidden;
    }

    .hero-watermark {
      position: absolute;
      top: 120px;
      left: 50%;
      width: min(520px, 70vw);
      height: auto;
      opacity: 0.06;
      transform: translateX(-50%);
      pointer-events: none;
    }

    .hero-orb {
      position: absolute;
      border-radius: 50%;
      filter: blur(120px);
      opacity: 0.3;
      pointer-events: none;
    }

    .hero-orb-1 {
      width: 600px;
      height: 600px;
      background: radial-gradient(circle, var(--gradient-start), transparent 70%);
      top: -200px;
      left: -100px;
      animation: floatOrb1 20s ease-in-out infinite;
    }

    .hero-orb-2 {
      width: 500px;
      height: 500px;
      background: radial-gradient(circle, var(--gradient-end), transparent 70%);
      bottom: -150px;
      right: -100px;
      animation: floatOrb2 25s ease-in-out infinite;
    }

    .hero-orb-3 {
      width: 350px;
      height: 350px;
      background: radial-gradient(circle, var(--accent), transparent 70%);
      top: 40%;
      left: 50%;
      transform: translateX(-50%);
      animation: floatOrb3 18s ease-in-out infinite;
      opacity: 0.15;
    }

    @keyframes floatOrb1 {
      0%, 100% { transform: translate(0, 0); }
      33% { transform: translate(60px, 40px); }
      66% { transform: translate(-40px, 20px); }
    }

    @keyframes floatOrb2 {
      0%, 100% { transform: translate(0, 0); }
      33% { transform: translate(-50px, -30px); }
      66% { transform: translate(30px, -50px); }
    }

    @keyframes floatOrb3 {
      0%, 100% { transform: translateX(-50%) scale(1); }
      50% { transform: translateX(-50%) scale(1.2); }
    }

    .hero-content {
      position: relative;
      z-index: 1;
      max-width: 800px;
    }

    .hero-brand {
      display: flex;
      justify-content: center;
      margin-bottom: 28px;
    }

    .hero-brand img {
      width: min(560px, 82vw);
      height: auto;
      display: block;
      filter: drop-shadow(0 24px 80px rgba(0, 0, 0, 0.28));
    }

    .hero-headline {
      font-weight: 800;
      font-size: 4rem;
      line-height: 1.08;
      letter-spacing: -0.04em;
      margin-bottom: 24px;
    }

    .hero-headline .gradient-text {
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end), var(--accent));
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }

    .hero-sub {
      font-size: 1.15rem;
      line-height: 1.7;
      color: var(--text-secondary);
      max-width: 560px;
      margin: 0 auto 40px;
    }

    .hero-buttons {
      display: flex;
      gap: 16px;
      justify-content: center;
      flex-wrap: wrap;
    }

    .btn-hero-primary {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 14px 32px;
      border-radius: 999px;
      border: none;
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end));
      color: #fff;
      font-family: "Inter", sans-serif;
      font-weight: 700;
      font-size: 1rem;
      cursor: pointer;
      transition: opacity 0.2s, transform 0.2s;
      text-decoration: none;
    }

    .btn-hero-primary:hover { opacity: 0.9; transform: translateY(-2px); }

    .btn-hero-secondary {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 14px 32px;
      border-radius: 999px;
      border: 1px solid var(--border);
      background: transparent;
      color: var(--text-primary);
      font-family: "Inter", sans-serif;
      font-weight: 600;
      font-size: 1rem;
      cursor: pointer;
      transition: all 0.2s;
      text-decoration: none;
    }

    .btn-hero-secondary:hover { border-color: var(--accent); color: var(--accent); }

    /* ---- Stats Bar ---- */
    .stats-bar {
      display: flex;
      justify-content: center;
      gap: 0;
      padding: 0 24px;
      max-width: 960px;
      margin: -40px auto 0;
      position: relative;
      z-index: 2;
    }

    .stat-item {
      flex: 1;
      text-align: center;
      padding: 32px 24px;
      background: var(--surface);
      backdrop-filter: blur(12px);
      border: 1px solid var(--border);
      border-right: none;
    }

    .stat-item:first-child { border-radius: 16px 0 0 16px; }
    .stat-item:last-child { border-radius: 0 16px 16px 0; border-right: 1px solid var(--border); }

    .stat-number {
      font-weight: 800;
      font-size: 2rem;
      letter-spacing: -0.04em;
      color: var(--success);
      line-height: 1;
    }

    .stat-label {
      font-size: 0.78rem;
      color: var(--text-secondary);
      margin-top: 8px;
    }

    /* ---- Section container ---- */
    .page-section {
      max-width: 1100px;
      margin: 0 auto;
      padding: 100px 24px;
      opacity: 0;
      transform: translateY(30px);
      transition: opacity 0.7s ease-out, transform 0.7s ease-out;
    }

    .page-section.visible {
      opacity: 1;
      transform: translateY(0);
    }

    .section-label {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.75rem;
      letter-spacing: 0.12em;
      text-transform: uppercase;
      color: var(--accent);
      margin-bottom: 12px;
    }

    .section-heading {
      font-weight: 800;
      font-size: 2.4rem;
      letter-spacing: -0.04em;
      margin-bottom: 16px;
    }

    .section-sub {
      font-size: 1.05rem;
      color: var(--text-secondary);
      line-height: 1.7;
      max-width: 600px;
      margin-bottom: 48px;
    }

    /* ---- Features Grid ---- */
    .features-grid {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 20px;
    }

    .feature-card {
      background: var(--surface);
      backdrop-filter: blur(12px);
      border: 1px solid var(--border);
      border-radius: 20px;
      padding: 32px 28px;
      transition: border-color 0.3s, box-shadow 0.3s;
    }

    .feature-card:hover {
      border-color: var(--border-hover);
      box-shadow: 0 0 30px rgba(102,126,234,0.08);
    }

    .feature-icon {
      font-size: 2rem;
      margin-bottom: 20px;
      display: block;
    }

    .feature-title {
      font-weight: 700;
      font-size: 1.1rem;
      letter-spacing: -0.02em;
      margin-bottom: 10px;
    }

    .feature-desc {
      font-size: 0.88rem;
      color: var(--text-secondary);
      line-height: 1.65;
    }

    /* ---- How It Works ---- */
    .how-steps {
      display: flex;
      gap: 0;
      align-items: flex-start;
      position: relative;
    }

    .how-step {
      flex: 1;
      text-align: center;
      padding: 0 24px;
      position: relative;
    }

    .how-step-number {
      width: 56px;
      height: 56px;
      border-radius: 50%;
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end));
      color: #fff;
      font-weight: 800;
      font-size: 1.2rem;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto 20px;
      position: relative;
      z-index: 1;
    }

    .how-step-line {
      position: absolute;
      top: 28px;
      left: calc(50% + 28px);
      width: calc(100% - 56px);
      height: 2px;
      background: linear-gradient(90deg, var(--gradient-start), var(--gradient-end));
      opacity: 0.3;
    }

    .how-step:last-child .how-step-line { display: none; }

    .how-step-title {
      font-weight: 700;
      font-size: 1.15rem;
      letter-spacing: -0.02em;
      margin-bottom: 10px;
    }

    .how-step-desc {
      font-size: 0.88rem;
      color: var(--text-secondary);
      line-height: 1.6;
    }

    /* ---- Configure Section ---- */
    .configure-section {
      max-width: 800px;
      margin: 0 auto;
      padding: 100px 24px;
    }

    .config-card {
      background: var(--surface);
      backdrop-filter: blur(12px);
      border: 1px solid var(--border);
      border-radius: 20px;
      padding: 32px;
      margin-bottom: 24px;
      display: grid;
      gap: 20px;
    }

    .config-card-title {
      font-weight: 700;
      font-size: 1.1rem;
      letter-spacing: -0.02em;
    }

    .config-card-desc {
      font-size: 0.85rem;
      color: var(--text-secondary);
      line-height: 1.65;
    }

    .config-card-desc a { color: var(--accent); }

    .field-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 16px;
    }

    label {
      display: grid;
      gap: 6px;
      font-size: 0.78rem;
      color: var(--text-secondary);
    }

    select, input[type="number"] {
      width: 100%;
      border: 1px solid var(--border);
      border-radius: 12px;
      background: var(--input-bg);
      color: var(--text-primary);
      padding: 11px 14px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.82rem;
      outline: none;
      transition: border-color 0.2s;
    }

    select:focus, input:focus { border-color: var(--accent); }

    .chip-grid {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .chip {
      cursor: pointer;
      display: inline-flex;
      font-size: 0.78rem;
    }

    .chip span {
      display: inline-block;
      padding: 7px 16px;
      border-radius: 999px;
      background: var(--chip-bg);
      border: 1px solid var(--border);
      color: var(--text-secondary);
      font-family: "JetBrains Mono", monospace;
      font-size: 0.75rem;
      transition: all 0.2s;
      user-select: none;
    }

    .chip:has(input:checked) span,
    .chip.selected span {
      background: var(--chip-bg-active);
      border-color: var(--chip-border-active);
      color: var(--accent);
    }

    .chip input { display: none; }

    .password-wrap { position: relative; }

    .password-wrap input {
      width: 100%;
      border: 1px solid var(--border);
      border-radius: 12px;
      background: var(--input-bg);
      color: var(--text-primary);
      padding: 11px 40px 11px 14px;
      font-family: "JetBrains Mono", monospace;
      font-size: 0.82rem;
      outline: none;
      transition: border-color 0.2s;
    }

    .password-wrap input:focus { border-color: var(--accent); }

    .eye-toggle {
      position: absolute;
      right: 8px;
      top: 50%;
      transform: translateY(-50%);
      background: none;
      border: none;
      color: var(--text-secondary);
      cursor: pointer;
      padding: 4px;
      display: flex;
      align-items: center;
    }

    .eye-toggle:hover { color: var(--accent); }

    /* ---- Install Bar ---- */
    .install-bar {
      max-width: 800px;
      margin: 0 auto 60px;
      padding: 0 24px;
    }

    .install-card {
      background: var(--surface);
      backdrop-filter: blur(12px);
      border: 1px solid var(--border);
      border-radius: 20px;
      padding: 32px;
      display: grid;
      gap: 16px;
    }

    .install-card-label {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.7rem;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--text-muted);
    }

    .install-card-url {
      font-family: "JetBrains Mono", monospace;
      color: var(--accent);
      word-break: break-all;
      line-height: 1.6;
      font-size: 0.75rem;
    }

    .install-card-actions {
      display: flex;
      gap: 12px;
    }

    .btn {
      border: none;
      border-radius: 999px;
      padding: 14px 28px;
      font-family: "Inter", sans-serif;
      font-weight: 600;
      font-size: 0.88rem;
      cursor: pointer;
      transition: all 0.2s;
      text-align: center;
      flex: 1;
    }

    .btn:hover { opacity: 0.88; }

    .btn-primary {
      color: #fff;
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end));
    }

    .btn-primary:hover { transform: translateY(-1px); }

    .btn-secondary {
      color: var(--text-primary);
      background: transparent;
      border: 1px solid var(--border);
    }

    .btn-secondary:hover { border-color: var(--accent); color: var(--accent); }

    .status {
      font-family: "JetBrains Mono", monospace;
      color: var(--accent);
      font-size: 0.78rem;
      min-height: 1.2rem;
      text-align: center;
    }

    /* ---- Footer ---- */
    .site-footer {
      border-top: 1px solid var(--border);
      padding: 40px 24px;
      text-align: center;
    }

    .footer-text {
      font-size: 0.82rem;
      color: var(--text-secondary);
      line-height: 1.8;
    }

    .footer-text a { color: var(--accent); text-decoration: none; }
    .footer-text a:hover { text-decoration: underline; }

    /* ---- Mobile footer ---- */
    .mobile-footer {
      display: none;
      position: fixed;
      bottom: 0;
      left: 0;
      right: 0;
      background: rgba(6,7,10,0.95);
      backdrop-filter: blur(20px);
      border-top: 1px solid var(--border);
      padding: 12px 16px;
      z-index: 100;
    }

    .mobile-footer .footer-actions {
      display: flex;
      gap: 10px;
    }

    .mobile-footer .btn {
      flex: 1;
      padding: 12px 12px;
      font-size: 0.8rem;
    }

    .mobile-footer .footer-preview {
      margin-top: 8px;
      display: none;
    }

    .mobile-footer .footer-preview.open { display: block; }

    .mobile-footer .preview-toggle {
      background: none;
      border: none;
      font-family: "JetBrains Mono", monospace;
      color: var(--text-secondary);
      font-size: 0.72rem;
      cursor: pointer;
      padding: 6px 0 0;
      text-decoration: underline;
    }

    .mobile-footer .preview-code {
      font-family: "JetBrains Mono", monospace;
      color: var(--accent);
      word-break: break-all;
      font-size: 0.68rem;
      line-height: 1.5;
      margin-top: 6px;
    }

    /* ---- Responsive ---- */
    @media (max-width: 980px) {
      .hero-headline { font-size: 2.8rem; }
      .hero-watermark { width: min(440px, 76vw); }
      .features-grid { grid-template-columns: repeat(2, 1fr); }
      .stats-bar { flex-wrap: wrap; margin-top: 0; }
      .stat-item { flex: 1 1 45%; }
      .stat-item:first-child { border-radius: 16px 0 0 0; }
      .stat-item:nth-child(2) { border-radius: 0 16px 0 0; border-right: 1px solid var(--border); }
      .stat-item:nth-child(3) { border-radius: 0 0 0 16px; }
      .stat-item:last-child { border-radius: 0 0 16px 0; }
      .how-steps { flex-direction: column; gap: 32px; }
      .how-step { text-align: left; display: flex; gap: 20px; align-items: flex-start; padding: 0; }
      .how-step-number { margin: 0; flex-shrink: 0; }
      .how-step-line { display: none !important; }
      .install-bar { display: none; }
      .mobile-footer { display: block; }
      body { padding-bottom: 90px; }
    }

    @media (max-width: 640px) {
      .navbar { padding: 0 16px; }
      .nav-logo { width: 28px; height: 28px; }
      .nav-version { display: none; }
      .hero { padding: 100px 16px 60px; }
      .hero-watermark { width: min(300px, 74vw); top: 132px; }
      .hero-brand { margin-bottom: 22px; }
      .hero-brand img { width: min(420px, 84vw); }
      .hero-headline { font-size: 2rem; }
      .hero-sub { font-size: 0.95rem; }
      .features-grid { grid-template-columns: 1fr; }
      .section-heading { font-size: 1.8rem; }
      .field-grid { grid-template-columns: 1fr; }
      .config-card { padding: 24px 20px; }
      .page-section { padding: 60px 16px; }
      .configure-section { padding: 60px 16px; }
    }
  </style>
</head>
<body>

  <!-- Navbar -->
  <nav class="navbar">
    <div class="nav-left">
      <img class="nav-logo" src="${brandLogo}" alt="" aria-hidden="true" />
      <span class="nav-brand">${escapeHtml(manifest.name)}</span>
      <span class="nav-version">v${escapeHtml(manifest.version)}</span>
    </div>
    <a href="#configure" class="nav-cta">Configure</a>
  </nav>

  <!-- Hero -->
  <section class="hero">
    <img class="hero-watermark" src="${brandLogo}" alt="" aria-hidden="true" />
    <div class="hero-orb hero-orb-1"></div>
    <div class="hero-orb hero-orb-2"></div>
    <div class="hero-orb hero-orb-3"></div>
    <div class="hero-content">
      <div class="hero-brand">
        <img src="${brandBackground}" alt="${escapeHtml(manifest.name)}" />
      </div>
      <h1 class="hero-headline">
        <span class="gradient-text">Stream anything.</span><br />Own your setup.
      </h1>
      <p class="hero-sub">
        Magnetio is a self-hosted addon for <strong>Stremio</strong> and <strong><a href="https://nuvioplugin.com" target="_blank" rel="noreferrer" style="color:var(--accent);text-decoration:none;">Nuvio</a></strong> that aggregates torrents from 22+ providers,
        resolves them through 8 debrid services, and delivers instant high-quality streams.
      </p>
      <div class="hero-buttons">
        <a href="#configure" class="btn-hero-primary">Get Started</a>
        <a href="https://github.com/peterdsp/Magnetio" target="_blank" rel="noreferrer" class="btn-hero-secondary">View on GitHub</a>
      </div>
    </div>
  </section>

  <!-- Stats Bar -->
  <div class="stats-bar">
    <div class="stat-item">
      <div class="stat-number">22+</div>
      <div class="stat-label">Torrent Providers</div>
    </div>
    <div class="stat-item">
      <div class="stat-number">8</div>
      <div class="stat-label">Debrid Services</div>
    </div>
    <div class="stat-item">
      <div class="stat-number">500+</div>
      <div class="stat-label">Indexers via Torznab</div>
    </div>
    <div class="stat-item">
      <div class="stat-number">24/7</div>
      <div class="stat-label">Self-Hosted</div>
    </div>
  </div>

  <!-- Features -->
  <section class="page-section">
    <div class="section-label">Features</div>
    <h2 class="section-heading">Everything you need to stream</h2>
    <p class="section-sub">Built for power users who want full control over their streaming pipeline.</p>
    <div class="features-grid">
      <div class="feature-card">
        <span class="feature-icon">&#9889;</span>
        <div class="feature-title">Multi-Provider Scraping</div>
        <div class="feature-desc">22 torrent providers queried in parallel with smart deduplication and quality ranking.</div>
      </div>
      <div class="feature-card">
        <span class="feature-icon">&#128279;</span>
        <div class="feature-title">Debrid Integration</div>
        <div class="feature-desc">8 debrid services for instant cached streams at full speed with automatic fallback.</div>
      </div>
      <div class="feature-card">
        <span class="feature-icon">&#128270;</span>
        <div class="feature-title">Torznab Support</div>
        <div class="feature-desc">Connect Jackett or Prowlarr for 500+ additional indexers and private trackers.</div>
      </div>
      <div class="feature-card">
        <span class="feature-icon">&#10024;</span>
        <div class="feature-title">Smart Recommendations</div>
        <div class="feature-desc">TMDB-powered similar content suggestions for every movie and series title.</div>
      </div>
      <div class="feature-card">
        <span class="feature-icon">&#127916;</span>
        <div class="feature-title">Subtitle Pipeline</div>
        <div class="feature-desc">Automatic subtitle search, download, and sync with ffsubsync in 15 languages.</div>
      </div>
      <div class="feature-card">
        <span class="feature-icon">&#128274;</span>
        <div class="feature-title">Self-Hosted</div>
        <div class="feature-desc">Runs on a Raspberry Pi. Your API keys never leave your server. No tracking, no telemetry.</div>
      </div>
      <div class="feature-card">
        <span class="feature-icon">&#128257;</span>
        <div class="feature-title">Stremio + Nuvio</div>
        <div class="feature-desc">Works with both <a href="https://www.stremio.com" target="_blank" rel="noreferrer" style="color:var(--accent);">Stremio</a> and <a href="https://nuvioplugin.com" target="_blank" rel="noreferrer" style="color:var(--accent);">Nuvio</a>. Same manifest URL, same configuration — install once, use on both platforms.</div>
      </div>
    </div>
  </section>

  <!-- How It Works -->
  <section class="page-section">
    <div class="section-label">How it works</div>
    <h2 class="section-heading">Three steps to streaming</h2>
    <p class="section-sub">From configuration to playback in under a minute.</p>
    <div class="how-steps">
      <div class="how-step">
        <div class="how-step-number">1</div>
        <div class="how-step-line"></div>
        <div>
          <div class="how-step-title">Configure</div>
          <div class="how-step-desc">Set your quality preferences, debrid API keys, and optional Torznab indexers below.</div>
        </div>
      </div>
      <div class="how-step">
        <div class="how-step-number">2</div>
        <div class="how-step-line"></div>
        <div>
          <div class="how-step-title">Install</div>
          <div class="how-step-desc">One-click install into Stremio via the generated manifest URL. Works on any device.</div>
        </div>
      </div>
      <div class="how-step">
        <div class="how-step-number">3</div>
        <div>
          <div class="how-step-title">Stream</div>
          <div class="how-step-desc">Play any movie or series with instant debrid-resolved streams at full quality.</div>
        </div>
      </div>
    </div>
  </section>

  <!-- Configure -->
  <div class="configure-section" id="configure">
    <div class="section-label">Configure</div>
    <h2 class="section-heading">Set up your addon</h2>
    <p class="section-sub">Customize providers, quality filters, subtitles, and API keys.</p>

    <div class="config-card">
      <div class="config-card-title">Stream Rules</div>
      <div class="field-grid">
        <label>
          Sort order
          <select id="sort">
            <option value="qualityseeders">Quality then seeders</option>
            <option value="qualitysize">Quality then size</option>
            <option value="seeders">Seeders only</option>
            <option value="size">Size only</option>
          </select>
        </label>
        <label>
          Max streams
          <select id="limit">
            <option value="5">5</option>
            <option value="10">10</option>
            <option value="20">20</option>
            <option value="50">50</option>
          </select>
        </label>
      </div>

      <label>
        Allowed qualities
        <div class="chip-grid" id="qualities">
          ${QUALITIES.map(([value, label]) => `<label class="chip"><input type="checkbox" value="${value}" /><span>${label}</span></label>`).join('')}
        </div>
      </label>

      <label>
        Audio languages
        <div class="chip-grid" id="languages">
          ${LANGUAGES.map(([value, label]) => `<label class="chip"><input type="checkbox" value="${value}" /><span>${label}</span></label>`).join('')}
        </div>
      </label>
    </div>

    <div class="config-card">
      <div class="config-card-title">Subtitles</div>
      <div class="config-card-desc">Select every subtitle language you want returned. Magnetio provides a dedicated Stremio subtitles resource.</div>
      <label>
        Subtitle languages
        <div class="chip-grid" id="subtitleLanguages">
          ${LANGUAGES.map(([value, label]) => `<label class="chip"><input type="checkbox" value="${value}" /><span>${label}</span></label>`).join('')}
        </div>
      </label>
    </div>

    <div class="config-card">
      <div class="config-card-title">Recommendations</div>
      <div class="config-card-desc">Enable "More Like This" suggestions powered by TMDB. Get a free API key at <a href="https://www.themoviedb.org/settings/api" target="_blank" rel="noreferrer">themoviedb.org</a>.</div>
      <div class="field-grid">
        <label>
          TMDB API Key
          <div class="password-wrap">
            <input type="password" id="tmdb" autocomplete="off" placeholder="TMDB API key (v3 auth)" />
            <button type="button" class="eye-toggle" data-target="tmdb" title="Toggle visibility">${SVG_EYE}</button>
          </div>
        </label>
      </div>
    </div>

    <div class="config-card">
      <div class="config-card-title">Torznab / Jackett / Prowlarr</div>
      <div class="config-card-desc">Connect a Torznab-compatible indexer manager. Enter the full Torznab API URL and your API key.</div>
      <div class="field-grid">
        <label>
          Torznab URL
          <div class="password-wrap">
            <input type="text" id="torznabUrl" autocomplete="off" placeholder="http://jackett:9117/api/v2.0/indexers/all/results/torznab" />
          </div>
        </label>
        <label>
          Torznab API Key
          <div class="password-wrap">
            <input type="password" id="torznabKey" autocomplete="off" placeholder="API key" />
            <button type="button" class="eye-toggle" data-target="torznabKey" title="Toggle visibility">${SVG_EYE}</button>
          </div>
        </label>
      </div>
    </div>

    <div class="config-card" id="p2pWarningCard" style="display:none;border-color:rgba(251,191,36,0.4);">
      <div class="config-card-title" style="color:#fbbf24;">&#9888; P2P Exposure Warning</div>
      <div class="config-card-desc" style="color:#fbbf24;opacity:0.85;">You have no debrid service configured. Without a debrid service, streams are fetched directly via P2P (peer-to-peer), which <strong>exposes your IP address</strong> to other peers in the torrent swarm. To protect your privacy, either add a debrid API key above or enable the Privacy Proxy below and provide your own VPN/SOCKS5 proxy so that the Magnetio server routes torrent traffic through your VPN.</div>
    </div>

    <div class="config-card">
      <div class="config-card-title">Privacy Proxy</div>
      <div class="config-card-desc">Stream torrents through the Magnetio server instead of connecting directly to the swarm. Your device never touches the torrent network.<br /><br /><strong>Important:</strong> Without a VPN/SOCKS5 proxy configured below, the server's own IP is used for torrent connections. Each user can provide their own SOCKS5 proxy (from a VPN provider) so that all torrent traffic is routed through that VPN — keeping both you and the server operator private.</div>
      <div class="field-grid">
        <label>
          P2P Privacy Proxy
          <select id="proxyStreams">
            <option value="0">Disabled</option>
            <option value="1">Enabled</option>
          </select>
        </label>
        <label id="proxyUrlLabel" style="display:none;">
          Your SOCKS5 Proxy
          <div class="password-wrap">
            <input type="password" id="proxyUrl" autocomplete="off" placeholder="socks5://user:pass@host:1080" />
            <button type="button" class="eye-toggle" data-target="proxyUrl" title="Toggle visibility">${SVG_EYE}</button>
          </div>
        </label>
      </div>
      <div class="config-card-desc" id="proxyHelpText" style="display:none;font-size:0.8rem;opacity:0.7;">Most VPN providers offer SOCKS5 proxy access (NordVPN, Surfshark, PIA, Mullvad, etc.). Enter the SOCKS5 address from your VPN provider above. This way, torrent traffic goes through your VPN — not through the server's IP.</div>
    </div>

    <div class="config-card">
      <div class="config-card-title">Debrid Services</div>
      <div class="config-card-desc">Add API keys for your debrid services. Cached torrents resolve as direct streams automatically.</div>
      <div class="field-grid">
        <label>
          Debrid prewarm
          <select id="prewarm">
            <option value="1">Enabled</option>
            <option value="0">Disabled</option>
          </select>
        </label>
        <label>
          Prewarm top uncached
          <select id="prewarmLimit">
            <option value="1">1</option>
            <option value="2">2</option>
            <option value="3">3</option>
            <option value="5">5</option>
          </select>
        </label>
        <label>
          Add Debrid cloud catalogs
          <select id="debridCatalogs" title="When a Debrid API key is set, also expose your cloud catalog (Movies/Series) in Stremio">
            <option value="1">Enabled</option>
            <option value="0">Disabled</option>
          </select>
        </label>
      </div>
      <div class="field-grid">
        ${DEBRID_FIELDS.map(([id, label, url]) => `
          <label>
            <a href="${url}" target="_blank" rel="noreferrer" style="color:var(--accent);text-decoration:none;">${label} <span style="font-size:0.65em;opacity:0.6;">&#8599;</span></a>
            <div class="password-wrap">
              <input type="password" id="${id}" autocomplete="off" placeholder="${label} API key" />
              <button type="button" class="eye-toggle" data-target="${id}" title="Toggle visibility">${SVG_EYE}</button>
            </div>
          </label>
        `).join('')}
      </div>
    </div>
  </div>

  <!-- Install Bar (desktop) -->
  <div class="install-bar" id="desktopSummary">
    <div class="install-card">
      <div class="install-card-label">Manifest URL</div>
      <div class="install-card-url" id="manifestPreview"></div>
      <div class="install-card-actions">
        <button class="btn btn-primary" type="button" id="installBtn">Install in Stremio</button>
        <button class="btn btn-secondary" type="button" id="copyBtn">Copy URL</button>
      </div>
      <div class="status" id="status"></div>
    </div>
  </div>

  <!-- Footer -->
  <footer class="site-footer">
    <div class="footer-text">
      Magnetio does not host or distribute any content.
      <a href="https://github.com/peterdsp/Magnetio#disclaimer" target="_blank" rel="noreferrer">Read disclaimer</a>.<br />
      <a href="https://github.com/peterdsp/Magnetio" target="_blank" rel="noreferrer">GitHub</a>
    </div>
  </footer>

  <!-- Mobile footer -->
  <div class="mobile-footer" id="mobileFooter">
    <div class="footer-actions">
      <button class="btn btn-primary" type="button" id="mobileInstallBtn">Install</button>
      <button class="btn btn-secondary" type="button" id="mobileCopyBtn">Copy URL</button>
    </div>
    <button class="preview-toggle" type="button" id="mobilePreviewToggle">Show manifest URL</button>
    <div class="footer-preview" id="mobilePreview">
      <div class="preview-code" id="mobileManifestPreview"></div>
    </div>
  </div>

  <script>
    const initialConfig = ${initialState};

    (function initTheme() {
      const saved = localStorage.getItem('magnetio-theme');
      const prefer = window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', saved || prefer);
      updateThemeIcon();
    })();

    function updateThemeIcon() {
      const btn = document.getElementById('themeToggle');
      if (!btn) return;
      const current = document.documentElement.getAttribute('data-theme');
      btn.innerHTML = current === 'dark' ? '${SVG_MOON}' : '${SVG_SUN}';
    }

    var themeBtn = document.getElementById('themeToggle');
    if (themeBtn) {
      themeBtn.addEventListener('click', function() {
        const current = document.documentElement.getAttribute('data-theme');
        const next = current === 'dark' ? 'light' : 'dark';
        document.documentElement.setAttribute('data-theme', next);
        localStorage.setItem('magnetio-theme', next);
        updateThemeIcon();
      });
    }

    window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', function(e) {
      if (!localStorage.getItem('magnetio-theme')) {
        document.documentElement.setAttribute('data-theme', e.matches ? 'light' : 'dark');
        updateThemeIcon();
      }
    });

    function selectedValues(id) {
      return Array.from(document.querySelectorAll('#' + id + ' input:checked')).map(function(el) { return el.value; });
    }

    function setChipGrid(id, values) {
      var wanted = new Set(values || []);
      document.querySelectorAll('#' + id + ' input[type="checkbox"]').forEach(function(cb) {
        cb.checked = wanted.has(cb.value);
        var chip = cb.closest('.chip');
        if (chip) chip.classList.toggle('selected', cb.checked);
      });
    }

    document.querySelectorAll('.chip-grid').forEach(function(grid) {
      grid.addEventListener('change', function(e) {
        if (e.target.type === 'checkbox') {
          var chip = e.target.closest('.chip');
          if (chip) chip.classList.toggle('selected', e.target.checked);
          refreshPreview();
        }
      });
    });

    function applyInitialState() {
      document.getElementById('sort').value = initialConfig.sort || 'qualityseeders';
      document.getElementById('limit').value = String(initialConfig.limit || 10);
      document.getElementById('prewarm').value = initialConfig.prewarmDebrid === false ? '0' : '1';
      document.getElementById('prewarmLimit').value = String(initialConfig.prewarmLimit || 3);
      document.getElementById('debridCatalogs').value = initialConfig.debridCatalogs === false ? '0' : '1';
      document.getElementById('proxyStreams').value = initialConfig.proxyStreams ? '1' : '0';
      document.getElementById('proxyUrl').value = initialConfig.proxyUrl || '';

      setChipGrid('qualities', initialConfig.qualities || []);
      setChipGrid('languages', initialConfig.languages || []);
      setChipGrid('subtitleLanguages', initialConfig.subtitleLanguages || ['en']);

      document.getElementById('tmdb').value = initialConfig.tmdbApiKey || '';

      document.getElementById('torznabUrl').value = initialConfig.torznabUrl || '';
      document.getElementById('torznabKey').value = initialConfig.torznabApiKey || '';

      document.getElementById('rd').value = initialConfig.realDebridApiKey || '';
      document.getElementById('pm').value = initialConfig.premiumizeApiKey || '';
      document.getElementById('ad').value = initialConfig.allDebridApiKey || '';
      document.getElementById('dl').value = initialConfig.debridLinkApiKey || '';
      document.getElementById('ed').value = initialConfig.easyDebridApiKey || '';
      document.getElementById('oc').value = initialConfig.offcloudApiKey || '';
      document.getElementById('tb').value = initialConfig.torboxApiKey || '';
      document.getElementById('pu').value = initialConfig.putioApiKey || '';
    }

    function buildConfiguration() {
      var parts = [];
      parts.push('sort=' + document.getElementById('sort').value);
      parts.push('limit=' + document.getElementById('limit').value);
      parts.push('prewarm=' + document.getElementById('prewarm').value);
      parts.push('prewarmLimit=' + document.getElementById('prewarmLimit').value);
      var debridCatalogsValue = document.getElementById('debridCatalogs').value;
      if (debridCatalogsValue === '0') parts.push('debridCatalogs=0');
      var proxyValue = document.getElementById('proxyStreams').value;
      if (proxyValue === '1') parts.push('proxy=1');
      var proxyUrlVal = document.getElementById('proxyUrl').value.trim();
      if (proxyUrlVal) parts.push('proxyUrl=' + encodeURIComponent(proxyUrlVal));

      var qualities = selectedValues('qualities');
      var languages = selectedValues('languages');
      var subtitleLanguages = selectedValues('subtitleLanguages');

      if (qualities.length) parts.push('qualities=' + qualities.join(','));
      if (languages.length) parts.push('languages=' + languages.join(','));
      if (subtitleLanguages.length) parts.push('subtitleLanguages=' + subtitleLanguages.join(','));

      var tmdbKey = document.getElementById('tmdb').value.trim();
      if (tmdbKey) parts.push('tmdb=' + tmdbKey);

      var torznabUrl = document.getElementById('torznabUrl').value.trim();
      var torznabKey = document.getElementById('torznabKey').value.trim();
      if (torznabUrl) parts.push('torznabUrl=' + encodeURIComponent(torznabUrl));
      if (torznabKey) parts.push('torznabKey=' + encodeURIComponent(torznabKey));

      var keys = ['rd','pm','ad','dl','ed','oc','tb','pu'];
      keys.forEach(function(id) {
        var val = document.getElementById(id).value.trim();
        if (val) parts.push(id + '=' + val);
      });

      return parts.join('|');
    }

    function manifestUrl() {
      var config = buildConfiguration();
      return config
        ? location.origin + '/' + config + '/manifest.json'
        : location.origin + '/manifest.json';
    }

    function refreshPreview() {
      var url = manifestUrl();
      document.getElementById('manifestPreview').textContent = url;
      var mobileEl = document.getElementById('mobileManifestPreview');
      if (mobileEl) mobileEl.textContent = url;
      document.getElementById('status').textContent = '';
    }

    document.querySelectorAll('select, input').forEach(function(el) {
      el.addEventListener('change', refreshPreview);
      el.addEventListener('input', refreshPreview);
    });

    function handleInstall() {
      var url = manifestUrl();
      window.open('stremio://' + url.replace(/^https?:\\/\\//, ''));
    }

    function handleCopy() {
      var url = manifestUrl();
      navigator.clipboard.writeText(url).then(function() {
        document.getElementById('status').textContent = 'Manifest URL copied.';
      }).catch(function() {
        document.getElementById('status').textContent = 'Copy failed. Use the preview URL manually.';
      });
    }

    document.getElementById('installBtn').addEventListener('click', handleInstall);
    document.getElementById('copyBtn').addEventListener('click', handleCopy);
    document.getElementById('mobileInstallBtn').addEventListener('click', handleInstall);
    document.getElementById('mobileCopyBtn').addEventListener('click', handleCopy);

    document.getElementById('mobilePreviewToggle').addEventListener('click', function() {
      var preview = document.getElementById('mobilePreview');
      var open = preview.classList.toggle('open');
      this.textContent = open ? 'Hide manifest URL' : 'Show manifest URL';
    });

    document.querySelectorAll('.eye-toggle').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var input = document.getElementById(this.getAttribute('data-target'));
        var showing = input.type === 'text';
        input.type = showing ? 'password' : 'text';
        this.innerHTML = showing ? '${SVG_EYE}' : '${SVG_EYE_OFF}';
      });
    });

    // Fade-in on scroll (IntersectionObserver)
    document.querySelectorAll('.page-section').forEach(function(section) {
      var observer = new IntersectionObserver(function(entries) {
        entries.forEach(function(entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('visible');
            observer.unobserve(entry.target);
          }
        });
      }, { threshold: 0.1 });
      observer.observe(section);
    });

    function updateProxyVisibility() {
      var enabled = document.getElementById('proxyStreams').value === '1';
      document.getElementById('proxyUrlLabel').style.display = enabled ? '' : 'none';
      document.getElementById('proxyHelpText').style.display = enabled ? '' : 'none';
    }

    function updateP2pWarning() {
      var keys = ['rd','pm','ad','dl','ed','oc','tb','pu'];
      var hasDebrid = keys.some(function(id) { return document.getElementById(id).value.trim(); });
      document.getElementById('p2pWarningCard').style.display = hasDebrid ? 'none' : '';
    }

    document.getElementById('proxyStreams').addEventListener('change', function() {
      updateProxyVisibility();
      refreshPreview();
    });

    var keys_for_warning = ['rd','pm','ad','dl','ed','oc','tb','pu'];
    keys_for_warning.forEach(function(id) {
      document.getElementById(id).addEventListener('input', updateP2pWarning);
    });

    applyInitialState();
    updateProxyVisibility();
    updateP2pWarning();
    refreshPreview();
  </script>
</body>
</html>`;
}

function escapeJsonForHtml(value) {
  return JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026');
}
