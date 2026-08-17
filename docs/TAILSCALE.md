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

**a) Approve the subnet route.** Open *Machines* → click your NAS → *Edit route settings* → tick `10.10.0.0/24` (or whatever you set as `LAN_SUBNET`) → Save. Without this, peers see the route but Tailscale won't forward traffic to it.

**b) Disable key expiry on the NAS.** Same page → *Disable key expiry*. The NAS is an always-on router; you don't want it to silently disconnect every ~6 months.

**c) Split DNS for `*.lan`.** Open *DNS* → *Add nameserver* → *Custom* → IP `10.10.0.10` → *Restrict to domain*: `lan` → Save. This makes `sonarr.lan`, `homeassistant.lan` etc. resolve via Pi-hole when remote.

> **Why split DNS?** Tailscale doesn't override your device's normal DNS unless you tell it to (we set `TS_ACCEPT_DNS=false`). The split-DNS rule says "only for `.lan` queries, ask Pi-hole" — everything else keeps using the device's normal resolver.

### Optional: use the NAS as an exit node

The compose file also advertises the NAS as an exit node (`--advertise-exit-node`), which lets a device route **all** its internet traffic through your home connection — not just LAN traffic. Useful if you want Tailscale to double as your "encrypt my traffic on untrusted WiFi" VPN instead of running a second always-on VPN app.

**Approve it** (one-time, same *Machines* page as the subnet route): click your NAS → *Edit route settings* → under *Exit node* tick both `0.0.0.0/0` and `::/0` → Save.

**Enable it per-device**: in the Tailscale app, open the device list / settings and select the NAS as your exit node.

> ⚠️ Android (and most mobile OSes) only run **one** VPN app at a time. If you also run an always-on VPN app (e.g. ProtonVPN), it and Tailscale will kick each other off the tunnel — including with that app's own split-tunneling/exclude-app settings enabled, since that only affects which traffic uses an *already-active* tunnel, not whether two VPN apps can hold the system tunnel concurrently. Using the NAS as an exit node is meant to **replace** that other VPN app on such devices, not run alongside it.

If you host a NAS on a locked-down system (sysctls mounted read-only inside containers), you may need to enable `net.ipv6.conf.all.forwarding` and `net.ipv4.conf.all.src_valid_mark` on the host directly (`sysctl -w ...`, then persist in `/etc/sysctl.conf` or `/etc/sysctl.d/`) — check `docker exec tailscale tailscale status --json | grep -A2 Health` for a forwarding warning after enabling the exit node.

## 4. Install Tailscale on your devices

- **iOS/Android**: install the Tailscale app, sign in with the same account
- **macOS**: `brew install --cask tailscale` (or download from tailscale.com/download)
- **Windows/Linux**: see [tailscale.com/download](https://tailscale.com/download)

Each device shows up in *Machines* in the admin console after first sign-in.

## 5. Test it

Put your laptop on a phone hotspot (simulates a v4-only hotel network), then try:

```bash
# Direct IP — Home Assistant
curl http://10.10.0.20:8123

# .lan domain — Sonarr (via Traefik on the NAS)
curl http://sonarr.lan
```

Both should respond exactly as they do on home WiFi.

## 6. Restrict access with an ACL policy (recommended)

By default, every device you approve on the tailnet gets full access to everything the NAS
advertises — the whole LAN subnet route and the exit node. Fine for your own devices; not fine for
a device you don't fully trust with that (a guest, a shared device, a friend's phone you just want
pointed at Jellyfin). An ACL policy scopes each device class to only what it needs.

> ⚠️ **Order matters — tag your own devices before writing any restrictive rule.** Once a `dst`
> rule exists, anything not matched by an `accept` rule is denied by default. If your own device
> isn't tagged `tag:personal-device` yet when you save the policy below, you lock yourself out of
> the NAS over Tailscale. Do step 2 (tag your devices) for *every* device you use — including
> whichever one you're reading this on — before trusting the restrictive rules to be in effect.

**1. Set the ACL policy.** Tailscale admin console → *Access controls* → replace the policy (or
merge into an existing custom one) with:

```json
{
  "tagOwners": {
    "tag:nas-router":       ["autogroup:admin"],
    "tag:personal-device":  ["autogroup:admin"],
    "tag:guest":            ["autogroup:admin"]
  },
  "grants": [
    {"src": ["autogroup:admin"], "dst": ["*"], "ip": ["*"]},
    {"src": ["tag:personal-device"], "dst": ["tag:nas-router", "<LAN_SUBNET>"], "ip": ["*"]},
    {"src": ["tag:personal-device"], "dst": ["autogroup:internet"], "ip": ["*"]},
    {"src": ["tag:guest"], "dst": ["<NAS_LAN_IP>"], "ip": ["tcp:8096", "tcp:5055"]}
  ],
  "autoApprovers": {
    "routes": {"<LAN_SUBNET>": ["tag:nas-router"]},
    "exitNode": ["tag:nas-router"]
  },
  "ssh": [
    {
      "action": "check",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["autogroup:nonroot", "root"]
    }
  ]
}
```

Replace `<LAN_SUBNET>` with your actual `.env` `LAN_SUBNET` value (e.g. `192.168.8.0/24`) and
`<NAS_LAN_IP>` with the NAS's LAN IP. This uses the modern `grants` syntax (not the older
`"action": "accept"` style `acls` array — Tailscale's console may already have generated a
default policy using `grants`, in which case merge these entries into it rather than replacing
the whole file). The first `grants` entry is a deliberate safety net: it keeps `autogroup:admin`
(your own account) with full access regardless of tagging state, so a tagging mistake can't lock
you out the way the untagged case above did. `autoApprovers` means the subnet route and exit node
auto-approve for anything tagged `tag:nas-router` — no more manual "Edit route settings" clicks
(steps 3a/3b above become automatic once the NAS is tagged, step 3 below). The `ssh` block is
Tailscale SSH's default check-mode policy — keep it if your existing policy already has one.

**2. Tag every personal device.** *Machines* → (device) → **⋯** → *Edit ACL tags* → add
`tag:personal-device`. Repeat for **every** device you personally use, before doing anything else
— this is the step that prevents a lockout.

**3. Recreate the Tailscale container** so the NAS picks up `tag:nas-router` (already wired into
`docker-compose.tailscale.yml`'s `TS_EXTRA_ARGS`):

```bash
docker compose -f docker-compose.tailscale.yml up -d --force-recreate
```

Confirm: `docker exec tailscale tailscale status --json` should show `"Tags":["tag:nas-router"]`
under `Self`, and the subnet route + exit node should already show approved (via `autoApprovers`)
without the manual admin-console clicks from step 3 above.

**4. Only after your own devices are confirmed working**, tag any shared/guest device
`tag:guest` — it's restricted to Jellyfin (`:8096`) and Seerr (`:5055`) only, bypassing Traefik and
the HTTPS+basicauth layer entirely (both apps have their own login, so this is intentional — a
guest never needs Sonarr/Radarr/Pi-hole/etc.).

**Rollback**: the admin console keeps ACL policy version history — *Access controls* → *History* →
revert to the previous version. No NAS-side action needed; the compose change (advertising
`tag:nas-router`) is harmless even without a matching ACL policy, it just has no effect until
`tagOwners` grants it.

## Troubleshooting

**`docker logs tailscale` shows no login URL.**
The container may have re-used existing state. Force a fresh login:
```bash
docker exec tailscale tailscale logout
docker exec tailscale tailscale up --advertise-routes=10.10.0.0/24 --accept-routes
```
The URL prints to that command's output.

**Peer can ping the NAS (10.10.0.10) but not other LAN devices (10.10.0.20 etc).**
The subnet route isn't approved. Re-check step 3a — until you tick the route box in the admin console and save, only the Tailscale node itself is reachable.

**`*.lan` doesn't resolve when remote.**
Split DNS isn't configured. Re-check step 3c. Verify on the client:
```bash
# macOS
scutil --dns | grep -A2 'domain.*lan'
```
You should see a resolver with nameserver `10.10.0.10` scoped to domain `lan`.

**Healthcheck failing in `docker ps`.**
Normal until you complete the interactive auth in step 2. Once authenticated, the next healthcheck interval (30s) should flip to healthy.

**Connection works on cellular but not on a specific hotel/corporate WiFi.**
Some networks block all outbound UDP. Tailscale automatically falls back to DERP relay over TCP/443; just confirm in the admin console *Machines* view — the node may show "(via DERP)" instead of "direct".

---

## ✅ + Tailscale Complete!

Your tailnet now exposes the LAN privately to any device you've authorised. Add new devices via the admin console; revoke them the same way.

Issues? [Report on GitHub](https://github.com/leonardoazeredo/ultimate-arr-stack/issues).
