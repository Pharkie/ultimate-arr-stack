/**
 * Stats dashboard HTML template.
 * Matches the Magnetio marketing page design language.
 */
export function statsDashboard(stats) {
  const today = stats.today || {};
  const total = stats.total || {};
  const days = stats.last7days || [];

  const maxReqs = Math.max(1, ...days.map(d => d.requests || 0));

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Magnetio - Dashboard</title>
  <meta name="robots" content="noindex, nofollow" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet" />
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg: #06070a;
      --surface: rgba(255,255,255,0.04);
      --border: rgba(255,255,255,0.08);
      --border-hover: rgba(255,255,255,0.15);
      --text-primary: #e2e8f0;
      --text-secondary: #94a3b8;
      --text-muted: rgba(255,255,255,0.3);
      --accent: #a78bfa;
      --gradient-start: #667eea;
      --gradient-end: #764ba2;
      --success: #34d399;
      --bar-bg: rgba(167,139,250,0.15);
      --bar-fill: linear-gradient(90deg, #667eea, #a78bfa);
    }

    html { scroll-behavior: smooth; }

    body {
      min-height: 100vh;
      background: var(--bg);
      color: var(--text-primary);
      font-family: "Inter", -apple-system, sans-serif;
      overflow-x: hidden;
    }

    .orb {
      position: fixed;
      border-radius: 50%;
      filter: blur(120px);
      opacity: 0.12;
      pointer-events: none;
      z-index: 0;
    }

    .orb-1 { width: 500px; height: 500px; background: var(--gradient-start); top: -100px; right: -100px; }
    .orb-2 { width: 400px; height: 400px; background: var(--gradient-end); bottom: 10%; left: -80px; }

    .container {
      position: relative;
      z-index: 1;
      max-width: 960px;
      margin: 0 auto;
      padding: 48px 24px;
    }

    .nav {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 48px;
    }

    .nav-brand {
      font-weight: 800;
      font-size: 1.2rem;
      background: linear-gradient(135deg, var(--gradient-start), var(--gradient-end));
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
      text-decoration: none;
    }

    .nav-back {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.8rem;
      color: var(--text-secondary);
      text-decoration: none;
      padding: 8px 16px;
      border: 1px solid var(--border);
      border-radius: 40px;
      transition: all 0.2s;
    }

    .nav-back:hover { border-color: var(--accent); color: var(--accent); }

    .page-title {
      font-size: 2.2rem;
      font-weight: 800;
      letter-spacing: -0.04em;
      margin-bottom: 8px;
    }

    .page-subtitle {
      color: var(--text-secondary);
      font-size: 0.9rem;
      margin-bottom: 40px;
    }

    .stat-grid {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 16px;
      margin-bottom: 40px;
    }

    .stat-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 24px;
      backdrop-filter: blur(12px);
      transition: border-color 0.2s;
    }

    .stat-card:hover { border-color: var(--border-hover); }

    .stat-value {
      font-size: 2rem;
      font-weight: 800;
      font-family: "JetBrains Mono", monospace;
      color: var(--success);
      letter-spacing: -0.02em;
    }

    .stat-label {
      font-size: 0.78rem;
      color: var(--text-secondary);
      margin-top: 4px;
      text-transform: uppercase;
      letter-spacing: 0.06em;
    }

    .section {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 28px;
      backdrop-filter: blur(12px);
      margin-bottom: 24px;
    }

    .section-title {
      font-size: 1rem;
      font-weight: 700;
      margin-bottom: 20px;
      letter-spacing: -0.01em;
    }

    .breakdown-grid {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 12px;
    }

    .breakdown-item {
      text-align: center;
      padding: 16px;
      background: rgba(255,255,255,0.02);
      border-radius: 12px;
      border: 1px solid rgba(255,255,255,0.04);
    }

    .breakdown-value {
      font-family: "JetBrains Mono", monospace;
      font-size: 1.4rem;
      font-weight: 700;
      color: var(--accent);
    }

    .breakdown-label {
      font-size: 0.72rem;
      color: var(--text-muted);
      margin-top: 4px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .chart {
      display: grid;
      grid-template-columns: repeat(7, 1fr);
      gap: 8px;
      align-items: end;
      height: 180px;
    }

    .chart-bar-wrap {
      display: flex;
      flex-direction: column;
      align-items: center;
      height: 100%;
      justify-content: flex-end;
    }

    .chart-bar {
      width: 100%;
      border-radius: 8px 8px 4px 4px;
      background: var(--bar-fill);
      min-height: 4px;
      transition: height 0.3s;
      position: relative;
    }

    .chart-bar:hover { opacity: 0.85; }

    .chart-bar-value {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.7rem;
      color: var(--text-secondary);
      margin-bottom: 6px;
      text-align: center;
    }

    .chart-bar-label {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.65rem;
      color: var(--text-muted);
      margin-top: 8px;
      text-align: center;
    }

    .footer {
      text-align: center;
      padding: 32px 0 16px;
      color: var(--text-muted);
      font-size: 0.75rem;
    }

    .footer a { color: var(--accent); text-decoration: none; }

    .refresh-note {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.7rem;
      color: var(--text-muted);
      text-align: right;
      margin-bottom: 16px;
    }

    @media (max-width: 768px) {
      .stat-grid { grid-template-columns: repeat(2, 1fr); }
      .breakdown-grid { grid-template-columns: repeat(2, 1fr); }
      .chart { grid-template-columns: repeat(7, 1fr); height: 120px; }
      .page-title { font-size: 1.6rem; }
    }

    @media (max-width: 480px) {
      .container { padding: 24px 16px; }
      .stat-grid { grid-template-columns: 1fr 1fr; gap: 12px; }
      .breakdown-grid { grid-template-columns: 1fr 1fr; }
    }
  </style>
</head>
<body>
  <div class="orb orb-1"></div>
  <div class="orb orb-2"></div>

  <div class="container">
    <nav class="nav">
      <a href="/" class="nav-brand">Magnetio</a>
      <a href="/configure" class="nav-back">Configure</a>
    </nav>

    <h1 class="page-title">Dashboard</h1>
    <p class="page-subtitle">Real-time analytics for your Magnetio instance</p>

    <div class="refresh-note">Auto-refreshes every 30s</div>

    <div class="stat-grid">
      <div class="stat-card">
        <div class="stat-value">${total.requests || 0}</div>
        <div class="stat-label">Total Requests</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${total.uniqueUsers || 0}</div>
        <div class="stat-label">Unique Users</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${today.requests || 0}</div>
        <div class="stat-label">Today Requests</div>
      </div>
      <div class="stat-card">
        <div class="stat-value">${today.uniqueUsers || 0}</div>
        <div class="stat-label">Today Users</div>
      </div>
    </div>

    <div class="section">
      <h2 class="section-title">Today Breakdown</h2>
      <div class="breakdown-grid">
        <div class="breakdown-item">
          <div class="breakdown-value">${today.streams || 0}</div>
          <div class="breakdown-label">Streams</div>
        </div>
        <div class="breakdown-item">
          <div class="breakdown-value">${today.catalogs || 0}</div>
          <div class="breakdown-label">Catalogs</div>
        </div>
        <div class="breakdown-item">
          <div class="breakdown-value">${today.subtitles || 0}</div>
          <div class="breakdown-label">Subtitles</div>
        </div>
        <div class="breakdown-item">
          <div class="breakdown-value">${today.pages || 0}</div>
          <div class="breakdown-label">Page Views</div>
        </div>
      </div>
    </div>

    <div class="section">
      <h2 class="section-title">Last 7 Days</h2>
      <div class="chart">
        ${days.slice().reverse().map(d => {
          const pct = maxReqs > 0 ? Math.max(3, (d.requests / maxReqs) * 100) : 3;
          const dayLabel = d.date ? d.date.slice(5) : '';
          return `<div class="chart-bar-wrap">
            <div class="chart-bar-value">${d.requests || 0}</div>
            <div class="chart-bar" style="height:${pct}%"></div>
            <div class="chart-bar-label">${dayLabel}</div>
          </div>`;
        }).join('')}
      </div>
    </div>

    <div class="footer">
      <a href="https://magnetio.peterdsp.dev">magnetio.peterdsp.dev</a>
    </div>
  </div>

  <script>
    setTimeout(function() { location.reload(); }, 30000);
  </script>
</body>
</html>`;
}
