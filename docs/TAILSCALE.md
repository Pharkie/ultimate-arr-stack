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

### Exit node: don't use the NAS, use the router

> ⚠️ **`--advertise-exit-node` is deliberately absent from node 1's
> `TS_EXTRA_ARGS`, and must stay that way.** Tailscale writes its exit-node
> rules to the *legacy* iptables tables (`ts-postrouting` MASQUERADE,
> `ts-forward` ACCEPT), while Docker and UGOS enforce the *nft* backend, where
> `filter` carries `-P FORWARD DROP`. Nothing accepts new forwarded flows from
> `tailscale0`, so a node-1 exit node silently drops all exit traffic while
> `tailscale ping` still reports success — subnet routing is unaffected, which
> is exactly what makes this so confusing to diagnose. This cost real
> debugging time before it was root-caused; don't re-enable it.
> `tests/compose-validation.bats` guards against it coming back.

The Tailscale exit-node role for this network runs on **`arr-stack-router`**
(the router itself, native Tailscale + WireGuard), egressing through
ProtonVPN — not on the NAS. A NAS-based version
(`gluetun-exit`/`tailscale-exit`, a second Dockerized ProtonVPN tunnel sharing
a netns with a second tailnet node) was built, proven, and later
**decommissioned**: it worked, but capped at ~6-9 Mbps per flow — a structural
ceiling from Docker + netns nesting on a NAS kernel older than Tailscale's
UDP-GSO/GRO fast path — while the router achieves 8-10x that running natively
on dedicated routing hardware. Full history, the root-cause investigation, and
the router's live configuration (its WireGuard/`uci` setup isn't tracked in
this repo, the same way `gluetun-exit`'s key only ever lived in the NAS's
`.env`) are in `docs/EXIT-NODE-PROJECT-LOG.md`.

Three facts from the NAS-based build remain true regardless of which device
serves the exit-node role, because they're properties of Tailscale exit nodes
in general, not of any specific implementation:

- **Tailnet DNS must be configured, or the exit node looks completely
  broken.** Selecting an exit node routes *all* client DNS through it via
  `peerapi`; if the tailnet has no nameserver of its own, every lookup fails
  — both public sites and `.lan` names — while already-open connections keep
  working, which reads like a routing bug rather than a DNS one. Set global
  nameservers and a `.lan` → NAS-IP split-DNS entry in the admin console under
  **DNS** (or via `https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers`
  and `.../dns/split-dns`). ⚠️ The split-DNS entry pins the NAS's LAN IP
  literally — it lives in Tailscale's cloud config, so nothing on the NAS or
  in this repo reveals a mismatch after an IP change. It broke exactly this
  way once, silently killing `.lan` for every remote client until it was
  fixed by hand.
- **Judge throughput on completed bytes, never on `ping`.** ProtonVPN
  rate-limits ICMP; a 60% "packet loss" reading has coexisted with 98 Mbps of
  real throughput in this project. And ProtonVPN's per-country server pool is
  itself not uniform — a bad server draw ("connects, works for a few seconds,
  then dies" on bulk transfer) can look exactly like an MTU or DERP problem
  and has cost real debugging time chasing the wrong layer.
- **Check direct-vs-relay before blaming anything else.** `tailscale status`
  reporting `relay "xyz"` instead of `direct ip:port` means traffic is riding
  Tailscale's shared DERP relay infrastructure, which is rate-shaped on their
  side regardless of local link speed. `docs/EXIT-NODE-PROJECT-LOG.md` §5
  covers the peer-relay mitigation and its own gotcha (the relay-port setting
  doesn't survive a node-1 restart, self-healed by
  `scripts/ensure-tailscale-relay-port.sh`).

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

> ⚠️ **`autoApprovers.exitNode: ["tag:nas-router"]` above no longer describes
> the NAS.** No NAS-side device advertises as an exit node any more (see
> "Exit node: don't use the NAS, use the router" above). It's not dead
> configuration though — confirmed live (2026-09-05) that `arr-stack-router`
> carries this same `tag:nas-router` tag, so its exit-node advertisement
> already auto-approves through this entry with no ACL edit needed. Its
> Tailscale config lives on the device, not in this repo, but the tag
> assignment is what matters here and that's confirmed via the admin
> console's Machines list.

## Troubleshooting

**`docker logs tailscale` shows no login URL.**
The container may have re-used existing state. Force a fresh login:
```bash
docker exec tailscale tailscale logout
docker exec tailscale tailscale up --advertise-routes=192.168.1.0/24 --accept-routes
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

**`*.lan` fails only while the exit node is selected** (public sites fine,
`DNS_PROBE_POSSIBLE` on every `.lan` name). An exit node resolves DNS *for its
clients* — see the tailnet-DNS note under "Exit node" above; this is a tailnet
DNS configuration gap, not a routing bug, regardless of which device serves
the exit-node role.

**Healthcheck failing in `docker ps`.**
Normal until you complete the interactive auth in step 2. Once authenticated, the next healthcheck interval (30s) should flip to healthy.

**Connection works on cellular but not on a specific hotel/corporate WiFi.**
Some networks block all outbound UDP. Tailscale automatically falls back to DERP relay over TCP/443; just confirm in the admin console *Machines* view — the node may show "(via DERP)" instead of "direct".

---

## ✅ + Tailscale Complete!

Your tailnet now exposes the LAN privately to any device you've authorised. Add new devices via the admin console; revoke them the same way.

Issues? [Report on GitHub](https://github.com/leonardoazeredo/ultimate-arr-stack/issues).
