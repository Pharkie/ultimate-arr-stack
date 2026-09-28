# + remote access — Tailscale path

> Return to [Setup Guide](SETUP.md) · For the public-HTTPS path, see [Cloudflared](REMOTE-ACCESS.md)

Reach your whole LAN (Pi-hole, `*.lan` domains, admin UIs, Home Assistant, the NAS) from anywhere — including hotel WiFi, mobile data, or networks behind CGNAT.

**Requirements:**
- Free [Tailscale](https://tailscale.com) account (up to 100 devices, personal use)
- The stack already deployed and running on the NAS

## 1. Create your Tailscale account

Sign up at [login.tailscale.com](https://login.tailscale.com/) — it federates with Google/Microsoft/GitHub/Apple, no separate password needed. Keep the browser tab open; you'll use the admin console in step 3.

## 2. Deploy the Tailscale container

```bash
cd $NAS_STACK_DIR
docker compose -f docker-compose.tailscale.yml up -d
```

The container starts but isn't authenticated yet. Get the login URL:

```bash
docker logs tailscale 2>&1 | grep -A1 "To authenticate"
```

You should see a line like `https://login.tailscale.com/a/abc123...`. Open it in your browser, sign into the same account from step 1, and approve the device.

> **Be quick (~70 seconds).** The container regenerates the URL roughly every minute while waiting for auth. If you've already signed into Tailscale in another tab and the *Add Device* button is one click away, you'll comfortably make it. If you stall, re-run the `docker logs` command to grab the fresh URL.

> **Alternative — pre-auth key.** If interactive keeps timing out (e.g. you're setting up an account from scratch and the GitHub OAuth flow takes a while), generate an [auth key](https://login.tailscale.com/admin/settings/keys), add `TS_AUTHKEY=tskey-auth-…` to `.env`, and `docker compose -f docker-compose.tailscale.yml up -d --force-recreate`. The container auto-registers — no clicking. Remove the key from `.env` after (it's single-use).

## 3. Configure the tailnet (Tailscale admin console)

Three one-time settings at [login.tailscale.com/admin](https://login.tailscale.com/admin):

**a) Approve the subnet route.** Open *Machines* → click your NAS → *Edit route settings* → tick `192.168.1.0/24` (or whatever you set as `LAN_SUBNET`) → Save. Without this, peers see the route but Tailscale won't forward traffic to it.

**b) Disable key expiry on the NAS.** Same page → *Disable key expiry*. The NAS is an always-on router; you don't want it to silently disconnect every ~6 months.

**c) Split DNS for `*.lan`.** Open *DNS* → *Add nameserver* → *Custom* → IP `192.168.1.10` → *Restrict to domain*: `lan` → Save. This makes `sonarr.lan`, `homeassistant.lan` etc. resolve via Pi-hole when remote.

> **Why split DNS?** Tailscale doesn't override your device's normal DNS unless you tell it to (we set `TS_ACCEPT_DNS=false`). The split-DNS rule says "only for `.lan` queries, ask Pi-hole" — everything else keeps using the device's normal resolver.

### Optional: use the NAS as an exit node

An exit node carries *all* of a device's internet traffic out through your home connection, not just its `.lan` traffic. That makes Tailscale your VPN on untrusted Wi-Fi. The compose file already offers the NAS as one (`--advertise-exit-node`); nothing changes until you approve it.

1. **Approve it.** Admin console → *Machines* → the NAS → *Edit route settings* → under *Exit node*, tick `0.0.0.0/0`, plus `::/0` if IPv6 forwarding is on (see below).
2. **Turn it on per device**, in that device's Tailscale app.

> Phones generally hold one VPN connection at a time, so Tailscale and another always-on VPN app keep displacing each other. On a phone, use the exit node *instead of* the other app.

**Check forwarding for both IP versions.** The kernel has to forward packets, and IPv4 and IPv6 are switched on separately. On a UGREEN NAS we found IPv4 forwarding on (so `.lan` routing worked) and IPv6 forwarding off: `0.0.0.0/0` worked, and `::/0` would have failed without a word.

```bash
cat /proc/sys/net/ipv4/ip_forward                      # want 1
docker exec tailscale sh -c 'cat /proc/sys/net/ipv4/ip_forward; cat /proc/sys/net/ipv6/conf/all/forwarding'
docker exec tailscale tailscale status --json | grep -i -A2 health
```

Tailscale's warning *"Subnet routing is enabled, but IP forwarding is disabled"* can mean only the IPv6 half is off. For IPv6, enable it on the host (`sysctl -w net.ipv6.conf.all.forwarding=1`, persisted under `/etc/sysctl.d/`). IPv4-only? Approve `0.0.0.0/0` alone and ignore the warning.

**Check the approval took effect.** Compare what the NAS offers with what the tailnet accepted:

```bash
docker exec tailscale tailscale status --json \
  | python3 -c "import sys,json; s=json.load(sys.stdin)['Self']; print('advertised:', s.get('AllowedIPs'))"
docker exec tailscale tailscale debug prefs \
  | python3 -c "import sys,json; print('offered   :', json.load(sys.stdin).get('AdvertiseRoutes'))"
```

`AdvertiseRoutes` is the offer: it lists `0.0.0.0/0` and `::/0` as soon as the flag is set, approved or not. `AllowedIPs` is what the coordination server accepted, so `0.0.0.0/0` there means approval went through. `ExitNodeOption` answers a different question (is the node advertising and able to forward?) and says nothing about approval.

A client that reports "no exit nodes found" while `AllowedIPs` looks right is usually just disconnected: check `tailscale status` on that device.

## 4. Install Tailscale on your devices

- **iOS/Android**: install the Tailscale app, sign in with the same account
- **macOS**: `brew install --cask tailscale` (or download from tailscale.com/download)
- **Windows/Linux**: see [tailscale.com/download](https://tailscale.com/download)

Each device shows up in *Machines* in the admin console after first sign-in.

## 5. Test it

Put your laptop on a phone hotspot (simulates a v4-only hotel network), then try:

```bash
# Direct IP — Home Assistant
curl http://192.168.1.20:8123

# .lan domain — Sonarr (via Traefik on the NAS)
curl http://sonarr.lan
```

Both should respond exactly as they do on home WiFi.

## Troubleshooting

**`docker logs tailscale` shows no login URL.**
The container may have re-used existing state. Force a fresh login:
```bash
docker exec tailscale tailscale logout
docker exec tailscale tailscale up --advertise-routes=192.168.1.0/24 --accept-routes --advertise-exit-node
```
The URL prints to that command's output.

**Peer can ping the NAS (192.168.1.10) but not other LAN devices (192.168.1.20 etc).**
The subnet route isn't approved. Re-check step 3a — until you tick the route box in the admin console and save, only the Tailscale node itself is reachable.

**`*.lan` doesn't resolve when remote.**
Split DNS isn't configured. Re-check step 3c. Verify on the client:
```bash
# macOS
scutil --dns | grep -A2 'domain.*lan'
```
You should see a resolver with nameserver `192.168.1.10` scoped to domain `lan`.

**Healthcheck failing in `docker ps`.**
Normal until you complete the interactive auth in step 2. Once authenticated, the next healthcheck interval (30s) should flip to healthy.

**Connection works on cellular but not on a specific hotel/corporate WiFi.**
Some networks block all outbound UDP. Tailscale automatically falls back to DERP relay over TCP/443; just confirm in the admin console *Machines* view — the node may show "(via DERP)" instead of "direct".

---

## ✅ + Tailscale Complete!

Your tailnet now exposes the LAN privately to any device you've authorised. Add new devices via the admin console; revoke them the same way.

Issues? [Report on GitHub](https://github.com/Pharkie/ultimate-arr-stack/issues).
