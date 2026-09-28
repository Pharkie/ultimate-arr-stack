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

The compose file also advertises the NAS as an **exit node** (`--advertise-exit-node`), which lets a device send *all* its internet traffic through your home connection rather than just LAN traffic. Useful if you'd rather Tailscale be your "encrypt my traffic on untrusted WiFi" VPN than run a second always-on VPN app.

**Advertising it does nothing on its own** — like the subnet route, it stays inert until approved.

**Approve it** (same *Machines* page as the subnet route): click your NAS → *Edit route settings* → under *Exit node*, tick both `0.0.0.0/0` and `::/0` → Save.

**Then enable it per-device**, in that device's Tailscale app settings.

> ⚠️ **Most mobile OSes run only one VPN at a time.** On Android in particular, an always-on VPN app and Tailscale will kick each other off the system tunnel — including with that app's own split-tunnelling enabled, since that only decides which traffic uses an *already-active* tunnel, not whether two apps can hold the tunnel at once. Using the NAS as an exit node is meant to **replace** that other app on such devices, not run alongside it.

**Exit nodes need IP forwarding**, and the two protocols are separate. Subnet routing already working does *not* mean an exit node will — verified on a UGREEN NAS where `net.ipv4.ip_forward` was `1` (so `.lan` routing was fine) while `net.ipv6.conf.all.forwarding` was `0`. Approving `0.0.0.0/0` worked; `::/0` would have silently failed to forward.

Check both, on the host and inside the container:

```bash
cat /proc/sys/net/ipv4/ip_forward                      # want 1
docker exec tailscale sh -c 'cat /proc/sys/net/ipv4/ip_forward; cat /proc/sys/net/ipv6/conf/all/forwarding'
docker exec tailscale tailscale status --json | grep -i -A2 health
```

Tailscale reports this as *"Subnet routing is enabled, but IP forwarding is disabled"* — which reads as though subnet routing is broken when it may only be the IPv6 half that's missing. If you need IPv6, enable it on the host (`sysctl -w net.ipv6.conf.all.forwarding=1`, then persist in `/etc/sysctl.d/`); if you're IPv4-only, approve just `0.0.0.0/0` and ignore the warning.

**To confirm approval actually landed, compare what the node *advertises* against what the tailnet *allows*:**

```bash
docker exec tailscale tailscale status --json \
  | python3 -c "import sys,json; s=json.load(sys.stdin)['Self']; print('advertised:', s.get('AllowedIPs'))"
docker exec tailscale tailscale debug prefs \
  | python3 -c "import sys,json; print('offered   :', json.load(sys.stdin).get('AdvertiseRoutes'))"
```

`AdvertiseRoutes` is what this machine *claims*; it contains `0.0.0.0/0` and `::/0` the moment you add the flag, approved or not. **`AllowedIPs` is what the coordination server has actually accepted** — if `0.0.0.0/0` appears there, approval landed.

> Don't use `ExitNodeOption` for this. It reads `true` once the node is advertising and forwarding correctly, which is not the same as approved, so it can mislead in both directions.

If a client reports "no exit nodes found" while `AllowedIPs` looks right, check the *client* is actually connected (`tailscale status` on that device) — a stopped client has no netmap and can't see anything on the tailnet.

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
