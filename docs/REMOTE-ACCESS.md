# + remote access

> Return to [Setup Guide](SETUP.md)

Watch and request media from anywhere via `jellyfin.yourdomain.com` and `seerr.yourdomain.com`.

**Requirements:**
- Buy a new, external domain name (~$10/year) — [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/) is simplest
- Cloudflare account (free tier)

## Cloudflare Tunnel Setup

Cloudflare Tunnel lets you access services from outside your home without opening ports on your router. We use CLI commands (faster than clicking through the web dashboard).

**1. Login to Cloudflare (run on NAS via SSH):**

```bash
cd /volume1/docker/arr-stack
mkdir -p cloudflared && chmod 777 cloudflared
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel login
```

This prints a URL. Open it in your browser, select your domain, and authorize. The running cloudflared process receives the cert via callback and saves it automatically (the browser shouldn't offer any download).

**2. Create the tunnel:**

```bash
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel create nas-tunnel
```

Note the tunnel ID (e.g., `6271ac25-f8ea-4cd3-b269-ad9778c61272`).

**3. Rename credentials and create config:**

```bash
# Rename credentials file
mv cloudflared/*.json cloudflared/credentials.json

# Create config (replace TUNNEL_ID and DOMAIN)
cat > cloudflared/config.yml << 'EOF'
tunnel: YOUR_TUNNEL_ID
credentials-file: /home/nonroot/.cloudflared/credentials.json

ingress:
  - hostname: "*.yourdomain.com"
    service: http://traefik:80
  - hostname: yourdomain.com
    service: http://traefik:80
  - service: http_status:404
EOF
```

**4. Add DNS routes:**

```bash
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel route dns nas-tunnel "*.yourdomain.com"
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel route dns nas-tunnel yourdomain.com
```

## Update Traefik Config

Copy the example configs and customize with your domain:

```bash
# Copy example configs
cp traefik/traefik.yml.example traefik/traefik.yml
cp traefik/dynamic/vpn-services.yml.example traefik/dynamic/vpn-services.yml
```

Edit `traefik/dynamic/vpn-services.yml` and replace the Host rules:

```yaml
# Replace yourdomain.com with your actual domain
jellyfin:
  rule: "Host(`jellyfin.yourdomain.com`)"  # ← your domain
seerr:
  rule: "Host(`seerr.yourdomain.com`)"  # ← your domain
```

> **Note:** The `.yml` files are gitignored. Your customized configs won't be overwritten when you `git pull` updates.

## Deploy + remote access

```bash
# Deploy Cloudflare Tunnel
docker compose -f docker-compose.cloudflared.yml up -d

# Optional: Improve tunnel stability (increases UDP buffer for QUIC)
sudo sysctl -w net.core.rmem_max=7500000
sudo sysctl -w net.core.wmem_max=7500000
```

<details>
<summary><strong>Make sysctl settings permanent (optional)</strong></summary>

The `sysctl -w` commands above are lost on reboot. To persist them:

```bash
# Add these lines to /etc/sysctl.conf
echo "net.core.rmem_max=7500000" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=7500000" | sudo tee -a /etc/sysctl.conf
```

Some NAS systems (like Ugreen) may reset `/etc/sysctl.conf` on firmware updates. If your settings disappear after an update, re-run the commands above.

</details>

<details>
<summary><strong>Using the tunnel for other services</strong></summary>

The tunnel config uses a wildcard (`*.yourdomain.com`) that routes all subdomains to Traefik. To route specific subdomains to other services, add hostname rules **before** the wildcard (rules are evaluated top-to-bottom, first match wins):

```yaml
ingress:
  # Specific routes first
  - hostname: homeassistant.yourdomain.com
    service: http://homeassistant:8123
  - hostname: blog.yourdomain.com
    service: http://192.168.1.100:80

  # Then wildcard for media stack
  - hostname: "*.yourdomain.com"
    service: http://traefik:80
  - hostname: yourdomain.com
    service: http://traefik:80
  - service: http_status:404
```

Add DNS records for the new hostnames:
```bash
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel route dns nas-tunnel homeassistant.yourdomain.com
```

**Tip:** For Docker containers on the `arr-stack` network, use the container name as hostname. For services outside Docker, use the IP address.

</details>

## Test Cloudflare Tunnel

From your phone on cellular data (not WiFi):
- Visit `https://jellyfin.yourdomain.com`
- Check SSL certificate is valid (padlock icon)

---

## ✅ + remote access Complete!

**Congratulations!** You now have:
- Jellyfin and Seerr accessible from anywhere via `yourdomain.com`
- HTTPS encryption for all external traffic
- No ports exposed on your router

**You're done!** The sections below are optional but recommended:
- **[Backup](SETUP.md#backup)** — Protect your configs
- **[Optional Utilities](UTILITIES.md)** — Monitoring, auto-recovery, disk usage

> **Need full network access remotely?** Cloudflare Tunnel only exposes HTTP services (Jellyfin, Seerr). If you need to access admin UIs (Sonarr, Radarr, etc.) or `.lan` domains from outside your home, look into [Tailscale](https://tailscale.com/) — it's free for personal use and works even behind CGNAT. Setup is not covered here.

Issues? [Report on GitHub](https://github.com/Pharkie/ultimate-arr-stack/issues) or [chat on Reddit](https://www.reddit.com/user/Jeff46K4/).
