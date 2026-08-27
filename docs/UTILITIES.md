# Optional Utilities

> Return to [Setup Guide](SETUP.md)

Deploy additional utilities for monitoring and NAS optimization:

```bash
docker compose -f docker-compose.utilities.yml up -d
```

| Service | Description | Access |
|---------|-------------|--------|
| **deunhealth** | Auto-restarts services when VPN recovers | Internal |
| **Uptime Kuma** | Service monitoring dashboard | http://uptime.lan |
| **Beszel** | System metrics (CPU, RAM, disk, containers) | http://beszel.lan |
| **duc** | Disk usage analyzer (treemap UI) | http://duc.lan |
| **Configarr** | Syncs TRaSH Guides quality profiles to Sonarr/Radarr | Run manually |

> **Want Docker log viewing?** [Dozzle](https://dozzle.dev/) is a lightweight web UI for viewing container logs in real-time. Not included in the stack, but easy to add if you want it.

## Uptime Kuma Setup

Uptime Kuma monitors service health. After first launch, open http://NAS_IP:3001 (or http://uptime.lan) and create an admin account.

**Adding monitors**: Uptime Kuma has no API — configure monitors through the web UI or directly via SQLite:

```bash
# Query existing monitors
docker exec uptime-kuma sqlite3 /app/data/kuma.db "SELECT id, name, url FROM monitor ORDER BY name"

# Add a monitor (MUST include user_id=1 or it won't appear in the UI)
docker exec uptime-kuma sqlite3 /app/data/kuma.db \
  "INSERT INTO monitor (name, type, url, interval, accepted_statuscodes_json, active, maxretries, user_id) \
   VALUES ('ServiceName', 'http', 'http://url:port', 60, '[\"200-299\"]', 1, 3, 1);"

# Rename a monitor
docker exec uptime-kuma sqlite3 /app/data/kuma.db "UPDATE monitor SET name='NewName' WHERE id=ID"

# Restart to pick up DB changes
docker restart uptime-kuma
```

### The VPN check, and why it is a push monitor

`scripts/check-vpn.sh` runs from cron every 5 minutes and pings a Kuma **push**
monitor named `VPN Check` on success only. Kuma raises the alarm when the pings
stop.

That inversion is the point. An HTTP monitor asks "is the service answering?",
which a leaking or unmeasurable VPN answers perfectly well. A push monitor asks
"did the check run and pass?", so it also catches the case an HTTP monitor never
can: the check itself not running. A dead cron and a healthy VPN look identical
to everything else on this page.

```bash
# Create the push monitor (token is yours; generate a fresh 32-char one)
TOKEN=$(head -c 24 /dev/urandom | md5sum | cut -c1-32)
docker exec uptime-kuma sqlite3 /app/data/kuma.db \
  "INSERT INTO monitor (name, active, type, interval, retry_interval, maxretries, \
   push_token, user_id, upside_down, accepted_statuscodes_json, method) \
   VALUES ('VPN Check', 1, 'push', 600, 60, 1, '$TOKEN', 1, 0, '[\"200-299\"]', 'GET');"

# Attach your notification so it can actually reach you (id 1 = your default)
MID=$(docker exec uptime-kuma sqlite3 /app/data/kuma.db "SELECT id FROM monitor WHERE name='VPN Check';")
docker exec uptime-kuma sqlite3 /app/data/kuma.db \
  "INSERT INTO monitor_notification (monitor_id, notification_id) VALUES ($MID, 1);"

docker restart uptime-kuma
echo "push URL: http://localhost:3001/api/push/$TOKEN"
```

The cron entry pushes only when the script exits 0, and logs the output when it
does not:

```cron
*/5 * * * * /path/to/arr-stack/scripts/check-vpn.sh > /tmp/check-vpn.last 2>&1 && curl -fsS -m 10 "http://localhost:3001/api/push/YOUR_TOKEN?status=up&msg=OK" > /dev/null || { echo "--- $(date) ---"; cat /tmp/check-vpn.last; } >> /path/to/arr-stack/logs/check-vpn.log
```

The monitor interval is 600s against a 300s cron, so one slow or missed run does
not page you; two consecutive failures do.

> **Installing the crontab needs root on UGOS.** `crontab <file>` writes its temp
> file into `/var/spool/cron/`, which the admin user cannot write, so it fails
> with `mkstemp: Permission denied`. Writing
> `/var/spool/cron/crontabs/<user>` directly *appears* to work — the file is
> owned by the user — but cron never reloads it, and the entry silently never
> runs. Verify with a `* * * * * date >> /tmp/canary.log` entry before trusting
> it. Use `sudo crontab -u <user> <file>`.

**Recommended monitors** (matching what the pre-commit check expects):

| Monitor | Type | URL | Notes |
|---------|------|-----|-------|
| Bazarr | HTTP | `http://bazarr:6767/ping` | Has own IP |
| Beszel | HTTP | `http://172.20.0.15:8090` | Use static IP |
| duc | HTTP | `http://duc:80` | Has own IP |
| FlareSolverr | HTTP | `http://172.20.0.3:8191` | Via Gluetun |
| Jellyfin | HTTP | `http://jellyfin:8096/health` | Has own IP |
| Pi-hole | HTTP | `http://pihole:80/admin` | Has own IP |
| Prowlarr | HTTP | `http://gluetun:9696/ping` | Via Gluetun |
| qBittorrent | HTTP | `http://gluetun:8085` | Via Gluetun |
| Radarr | HTTP | `http://radarr:7878/ping` | Has own IP |
| Seerr | HTTP | `http://seerr:5055/api/v1/status` | Has own IP |
| Sonarr | HTTP | `http://sonarr:8989/ping` | Has own IP |
| Traefik | HTTP | `http://traefik:80/ping` | Has own IP |

> **Why `gluetun` for qBittorrent/SABnzbd/Prowlarr?** Those share Gluetun's network (`network_mode: service:gluetun`) and don't get their own Docker DNS entries — use the `gluetun` hostname or its static IP `172.20.0.3`. Sonarr/Radarr run on the bridge with their own names/IPs, so monitor them directly.

> **Optional extras**: You can also add monitors for external URLs (e.g., `https://jellyfin.yourdomain.com`), Home Assistant, or other devices — these won't trigger pre-commit warnings.

## Beszel Setup

Beszel has two components: the hub (web UI) and the agent (metrics collector). The agent needs a key from the hub.

**First deploy (hub only):**
```bash
docker compose -f docker-compose.utilities.yml up -d beszel
```

**Get the agent key:**
1. Open http://NAS_IP:8090 (or http://beszel.lan)
2. Create an admin account
3. Click "Add System" → copy the `KEY` value

**Add to `.env`:**
```bash
BESZEL_KEY=ssh-ed25519 AAAA...your-key-here
```

**Deploy the agent:**
```bash
docker compose -f docker-compose.utilities.yml up -d beszel-agent
```

## Configarr Setup

Configarr syncs [TRaSH Guides](https://trash-guides.info/) quality profiles and custom formats to Sonarr and Radarr. It runs once and exits — no persistent service, no web UI.

**1. Copy the example config:**
```bash
cp configarr/config.yml.example configarr/config.yml
```

**2. Add API keys to `.env`:**
```bash
SONARR_API_KEY=your_sonarr_api_key
RADARR_API_KEY=your_radarr_api_key
```
Find these in Sonarr/Radarr → Settings → General → API Key.

**3. Edit `configarr/config.yml`** — uncomment the template set you want (e.g., `sonarr-v4-quality-profile-web-1080p`). Browse available templates at the [recyclarr config-templates repo](https://github.com/recyclarr/config-templates).

**4. Preview changes (dry run):**
```bash
docker compose -f docker-compose.utilities.yml run --rm -e DRY_RUN=true configarr
```

**5. Apply changes:**
```bash
docker compose -f docker-compose.utilities.yml run --rm configarr
```

> **Tip:** Run with `DRY_RUN=true` first every time to preview what Configarr will change before it touches your Sonarr/Radarr settings.

---

**Back to:** [Setup Guide](SETUP.md)
