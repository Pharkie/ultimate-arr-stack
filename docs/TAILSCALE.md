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

### Optional: a ProtonVPN exit node (get both at once)

The exit node above has a real limitation: your traffic leaves via **your home
ISP's IP**. That's fine for encrypting untrusted WiFi, but it's the opposite of
anonymity — sites see an address tied to your actual home account — and it can't
geo-unblock anything, because the exit is always your own country.

The fix is a **second** Tailscale node whose own internet egress goes through
ProtonVPN. Your phone then picks *that* node as its exit node and gets home LAN
access **and** a Proton IP from a single VPN connection — which is otherwise
impossible on mobile, since the OS only allows one VPN app at a time.

```
 phone ──▶ tailscale        (host netns)   → LAN routes, .lan DNS
       └─▶ tailscale-exit   (in gluetun-exit's netns) → ProtonVPN → internet
```

Three services in `docker-compose.tailscale.yml` implement this, all opt-in:

| Service | Role |
|---|---|
| `gluetun-exit` | A **dedicated second** ProtonVPN tunnel (172.20.0.18) |
| `tailscale-exit` | Second tailnet node, exit-node only, sharing that netns |
| `tailscale-exit-routing` | Reconcile sidecar that keeps the routing/firewall fixes applied |

**Why a second Gluetun rather than reusing the download one?** Opening the
FORWARD chain on the main `gluetun` would require `FIREWALL=off`, destroying the
kill switch for qBittorrent/SABnzbd/Prowlarr. And `gluetun-rotator` restarts that
container every 6 hours by design to rotate exit servers, which would drop every
in-flight exit-node session four times a day. It also lets the browsing exit
country differ from the download country.

**Two firewall backends share this netns — by design, not by accident.** Gluetun's
`iptables` is `nf_tables`; the Tailscale image symlinks `iptables` →
`iptables-legacy`, so both `tailscaled` and the reconcile sidecar write into the
*legacy* tables. The kernel evaluates both at the same netfilter hooks, so the
two layers compose:

| Layer | Backend | Contents |
|---|---|---|
| Gluetun's kill switch | nft | `-P FORWARD DROP` + `post-rules.txt`'s two `tailscale0` ACCEPTs |
| Tailscale + sidecar | legacy | `ts-forward`/`ts-postrouting`, the sidecar's ACCEPTs, and `-t nat -o tun0 -j MASQUERADE` |

This is why `post-rules.txt` accepts on `tailscale0` **unconditionally** instead
of jumping to `ts-forward`: the chain it would jump to lives in the other
backend. Two consequences worth knowing:

- **`iptables -S FORWARD` inside `gluetun-exit` will not show `ts-forward`, and
  that is correct** — it's an nft view of legacy-resident chains. Use
  `iptables-legacy -S FORWARD` to see them. Don't read the absence as a
  misconfigured `TS_DEBUG_FIREWALL_MODE`.
- All NAT ends up in legacy. Gluetun adds no nft NAT of its own (only Docker's
  `127.0.0.11` DNS rule), so there's no legacy/nft NAT conflict here — but if a
  future Gluetun version starts masquerading in nft, revisit this, because mixing
  NAT across the two backends is genuinely unsafe.

#### Setup

1. **Generate a second WireGuard config** at
   [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) —
   a *new* one, not the key already used by the download tunnel. It counts as
   another device against your plan's simultaneous-connection limit. Leave
   NAT-PMP port forwarding **off** (it doesn't help here — see below).
   **The server the download page picks doesn't matter.** Only the config's
   `PrivateKey` and `Address` are used; Gluetun ignores its `Endpoint` and
   selects a server from `VPN_EXIT_COUNTRIES` using its own embedded list.
   Live-verified: a Belgian (`BE#47`) config with `VPN_EXIT_COUNTRIES=Netherlands`
   connected to a Dutch server and reported an NL egress IP.
2. **Get the node authenticated.** Either works:
   - *Auth key* (Settings → Keys), **reusable** and **non-ephemeral**, set as
     `TS_EXIT_AUTHKEY`. Best for unattended rebuilds.
   - *Interactive login* — leave `TS_EXIT_AUTHKEY` empty and read the URL out of
     `docker logs tailscale-exit` (`To authenticate, visit: …`). Workable, but
     **an auth key is strongly preferred**, and the reason is a trap worth
     knowing: every container restart makes `tailscale up` mint a *fresh
     nodekey*, which invalidates any login URL already issued. Hit this live —
     the node restarted 9 times while a login URL was outstanding, so a login
     that genuinely succeeded attached to a key the container no longer held,
     leaving the console showing a logged-in device that the container reported
     as logged out. The healthcheck now reports healthy (rather than failing
     into a deunhealth restart) whenever the node is logged out *and*
     `TS_EXIT_AUTHKEY` is empty, specifically so an interactive login has a
     stable URL to complete against. With a key set it still restarts on
     failure, because there a restart genuinely re-authenticates.
3. **Add to the NAS's `.env`**: `VPN_EXIT_WIREGUARD_PRIVATE_KEY`,
   `VPN_EXIT_WIREGUARD_ADDRESSES`, `VPN_EXIT_COUNTRIES`, `TS_EXIT_AUTHKEY`,
   and optionally `TS_EXIT_HOSTNAME`.
4. **Configure tailnet DNS — the exit node is unusable without it.** This is not
   optional polish, and it is the single most likely reason a correctly-built
   exit node looks completely broken. Normally a phone resolves DNS via its
   carrier or WiFi resolver. Select an exit node and *all* traffic routes through
   it, so those resolvers — private addresses on a network the exit node has no
   route to — become unreachable. If the tailnet has no nameserver of its own,
   nothing takes over and **every** lookup fails: browsers show a DNS probe
   error for internet and `.lan` names alike, while already-established
   connections keep working, which makes it look like a routing bug rather than
   a DNS one.

   Set both, in the admin console under **DNS** (or via the API):

   ```bash
   # Global nameservers - used by exit-node clients for everything else
   curl -u "$TSKEY:" -X POST -H 'Content-Type: application/json' \
     --data '{"dns":["1.1.1.1","1.0.0.1"]}' \
     https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers

   # Split DNS - send only the .lan domain to Pi-hole, reached over node 1's
   # subnet route. NOTE: the endpoint is dns/split-dns; dns/splitdns 404s.
   curl -u "$TSKEY:" -X PATCH -H 'Content-Type: application/json' \
     --data '{"lan":["<NAS_LAN_IP>"]}' \
     https://api.tailscale.com/api/v2/tailnet/-/dns/split-dns
   ```

   Splitting them this way keeps Pi-hole's blocklists off general remote
   browsing and stops Pi-hole downtime from taking out internet DNS, while
   `.lan` still resolves.

   ⚠️ **Configuring this in the console is necessary but not sufficient — the
   exit node has to be able to act on it.** An exit node answers DNS *on its
   clients' behalf* over `peerapi`: select it on a phone and every lookup that
   phone makes is resolved on the NAS, not on the phone. So the client never
   queries Pi-hole itself, and the split-DNS entry is only honoured if
   `tailscale-exit` runs `--accept-dns=true`. With `false`, tailscaled forwards
   those queries to whatever the netns system resolver is — here Gluetun's
   DoT → Cloudflare — which answers `*.lan` with **rcode 5 REFUSED**, because it
   isn't a public domain. The symptom is public sites loading normally while
   every `.lan` name fails with `DNS_PROBE_POSSIBLE`, which reads like a Traefik
   or Pi-hole fault and is neither.

   Confirm which it is from the exit node, not from the client:

   ```bash
   docker exec tailscale-exit tailscale dns query sonarr.lan
   # want: "Forwarding to resolver: <NAS_LAN_IP>" + RCodeSuccess
   docker logs tailscale-exit 2>&1 | grep -E 'peerapi: handleDNS|refusal'
   # "handleDNS fwd error" or "response code indicating refusal: 5"
   #   => the exit node is forwarding to the wrong resolver
   ```

   A useful cross-check: if the phone were resolving `.lan` for itself, Pi-hole
   would log a `100.x` tailnet client. Query its database directly —
   `docker exec pihole pihole-FTL sqlite3 /etc/pihole/pihole-FTL.db "SELECT
   client, domain FROM queries ORDER BY timestamp DESC LIMIT 40;"` — rather than
   `/var/log/pihole/pihole.log`, which rotates at midnight and will read empty
   for hours, looking exactly like "no queries arrived".

   ⚠️ **The split-DNS entry pins the NAS's LAN IP, so any NAS IP change breaks
   it** — and it lives in Tailscale's cloud config, so nothing on the NAS or in
   this repo will reveal the mismatch. It broke exactly this way here: it still
   read `192.168.8.246` long after the VLAN10 migration moved the NAS to
   `192.168.110.246`, silently killing `.lan` for every remote client. It only
   fails when away from home, so there was no obvious moment of breakage. Add it
   to the checklist for any future addressing change.
5. **Check the ACL policy first.** The node advertises `tag:nas-router`, which
   step 6's policy already lists in both `tagOwners` and `autoApprovers.exitNode`
   — so **no ACL edit is needed and the exit node self-approves**. But verify the
   live policy still matches before first boot: advertising a tag that isn't in
   `tagOwners` fails `tailscale up` entirely, it doesn't just warn.
6. **Start it**, naming the services explicitly so the existing `tailscale`
   container isn't reconciled and briefly dropped:
   ```bash
   docker compose -f docker-compose.tailscale.yml up -d gluetun-exit
   # wait for healthy, then:
   docker compose -f docker-compose.tailscale.yml up -d tailscale-exit tailscale-exit-routing
   ```
7. **On the phone**: Tailscale app → Exit Node → select `arr-stack-vpn-exit`.

#### Verify

```bash
# Exit node registered and self-approved
docker exec tailscale-exit tailscale status --json | grep -A3 '"Self"'

# Forwarding sysctls landed in the SHARED netns (set on gluetun-exit, the
# namespace owner — Docker skips net.* sysctls for containers that JOIN a netns)
docker exec tailscale-exit cat /proc/sys/net/ipv4/ip_forward     # → 1

# The return-path fix: pref 99 must sit ABOVE gluetun's pref ~101 rule
docker exec gluetun-exit ip rule show | grep 100.64.0.0/10

# Gluetun's DROP policy, with post-rules.txt's hole punched through it
docker exec gluetun-exit iptables -S FORWARD

# ...and the legacy tables, where tailscaled's and the sidecar's rules live
docker exec gluetun-exit iptables-legacy -S FORWARD
docker exec gluetun-exit iptables-legacy -t nat -S POSTROUTING

# The headline proof — these two must DIFFER
docker exec gluetun-exit sh -c 'wget -qO- https://ifconfig.me/ip'  # Proton IP
docker exec sonarr sh -c 'curl -s https://ifconfig.me/ip'          # home WAN IP
```

Then from the phone **with the exit node active**: `https://ifconfig.me/ip` must
match `gluetun-exit`, and `http://sonarr.lan` must still load (proving subnet
routes and split DNS survive alongside the exit node).

**If both fail with a DNS error, it's step 4, not the tunnel.** Check tailnet
DNS before touching anything on the NAS — the forwarding counters tell you
instantly whether packets are even reaching the exit node:

```bash
docker exec gluetun-exit iptables -L FORWARD -v -n   # non-zero pkts on tailscale0 = traffic IS arriving
curl -u "$TSKEY:" https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers  # must NOT be {"dns":[]}
curl -u "$TSKEY:" https://api.tailscale.com/api/v2/tailnet/-/dns/split-dns    # "lan" must be the CURRENT NAS IP
```

Traffic flowing while every hostname fails is the signature of missing tailnet
DNS, not a broken tunnel.

**Leak test** — `docker stop gluetun-exit` while the phone is on the exit node.
The phone should lose internet **entirely**. If it silently falls back to
working, the kill switch failed and traffic is leaving on your home IP.

#### Performance: direct vs relay

The one thing worth measuring. Run `tailscale status` on the phone/laptop:

- `direct 185.x.x.x:41641` — hole punching worked. Full speed.
- `relay "ams"` — falling back to DERP, Tailscale's shared relay
  infrastructure. It's rate-shaped on their side, so a fast home link doesn't
  help. Reported throughput varies enormously (roughly 10–40 Mbps, occasionally
  far worse). 30 Mbps is fine for browsing and 1080p; under ~5 Mbps isn't usable.

`tailscale ping arr-stack-vpn-exit` reports DERP for the first packet or two then
upgrades — run it several times and read the steady state, not the first line.

The Android app doesn't surface this clearly. Read it from the exit node instead,
which reports the connection type per peer:

```bash
docker exec tailscale-exit tailscale status
# ... leonardos-s24-ultra   android   active; relay "lhr"
```

Measured here on first connection: **`relay "lhr"`** — a phone on cellular behind
CGNAT, relaying via DERP London rather than hole-punching direct.

If it relays, the mitigation is **peer relays** (Tailscale 1.86+): make the
host-network node a relay with
`docker exec tailscale tailscale set --relay-server-port=41641` plus a
`tailscale.com/cap/relay` grant in the ACL. Note this requires dropping `--reset`
from that node's `TS_EXTRA_ARGS` first, or the setting is wiped on every restart.

> **Why port forwarding doesn't help.** Gluetun does support ProtonVPN NAT-PMP,
> but it hands out a *dynamic* port re-leased about every 60 seconds while
> `tailscaled --port` is static — and even reconciled it wouldn't matter, since
> Tailscale advertises whatever STUN discovers rather than an endpoint you pick.
> `VPN_PORT_FORWARDING` is deliberately left off.


#### Performance: which ProtonVPN server you drew

Measure this **before** blaming Tailscale. ProtonVPN's per-country pool is not
uniform, and a bad draw is by far the largest performance effect in this stack —
larger than DERP-vs-direct, larger than MTU. Measured on the NAS 2026-08-23,
back to back, same 20 MB payload:

| Path | Throughput |
|---|---|
| NAS host, no VPN | 579–698 Mbps |
| `gluetun` (main stack, a different Proton server) | 105–144 Mbps |
| `gluetun-exit` on Proton `103.69.224.76` | **0.5–3 Mbps**, 100 MB flows never completed |
| `gluetun-exit` after rotating to `185.107.44.149` | **78–98 Mbps** |

A bad server presents as *"connects, works for a few seconds, then dies"* —
small requests succeed while bulk transfer decays to failure. That looks exactly
like an MTU black hole, and it cost this project two days of chasing MSS, IPv6
and DERP before the three-way split above isolated it.

**Gluetun's own healthcheck cannot catch this.** It probes TCP/TLS to
`1.1.1.1:443`, which succeeds fine on a server delivering 0.5 Mbps. Health is
not speed. That is why `gluetun-exit-rotator` exists: it measures real
throughput every 6 h and rotates the server until it clears
`GLUETUN_EXIT_MIN_MBPS`.

> **Do not measure this path with `ping`.** Proton rate-limits ICMP, so loss
> figures are meaningless here — a reading of 60% "packet loss" was recorded in
> the same minute as 98 Mbps of real throughput. Judge on completed bytes and
> elapsed time only. An earlier "53% packet loss" finding in this project was
> purely this artifact.

To check or rotate by hand (the control-server API, from inside the netns):

```bash
# which server am I on?
docker exec gluetun-exit wget -qO- http://127.0.0.1:8000/v1/publicip/ip

# rotate WITHOUT restarting the container (see the warning below)
docker exec -i gluetun-exit nc 127.0.0.1 8000 <<'EOF'
PUT /v1/vpn/status HTTP/1.1
Host: 127.0.0.1
Content-Length: 20
Connection: close

{"status":"stopped"}
EOF
# ...then the same with {"status":"running"}
```

> **Never rotate `gluetun-exit` with `docker restart`.** A restart gives it a new
> network namespace, orphaning `tailscale-exit` until deunhealth notices ~2 min
> later — and **Android clients do not re-establish on their own** when that
> happens; they sit stranded until Tailscale is manually toggled. The
> control-server API swaps the WireGuard peer in place, leaving the namespace
> intact. Verified: after an API rotation `tailscale-exit` was still
> `Up 56 minutes (healthy)` on an unchanged netns. This is why
> `gluetun-exit-rotator` is API-driven while the main `gluetun-rotator` next
> door can safely use `docker restart`.

#### Rollback

The existing `tailscale` node is left completely untouched and still advertises
its own exit node, which makes rollback trivial even from far away:

1. **From the phone, anywhere**: Exit Node → pick `arr-stack-nas` or **None**.
   LAN access is unaffected either way.
2. **Admin console**: Machines → `arr-stack-vpn-exit` → Disable/Remove.
3. **On the NAS**: `docker compose -f docker-compose.tailscale.yml stop tailscale-exit tailscale-exit-routing gluetun-exit`

> **Alternative worth pricing first:** Tailscale sells **Mullvad exit nodes** as
> a tailnet add-on, which achieves the same outcome (LAN access + a non-home exit
> IP with a country picker) with no extra containers and direct routing by
> design. It costs a monthly add-on and it's Mullvad rather than Proton, but it's
> minutes of work instead of the setup above.

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

**`*.lan` fails only while the ProtonVPN exit node is selected** (public sites
fine, `DNS_PROBE_POSSIBLE` on every `.lan` name). Different cause: the exit node
resolves DNS for its clients, so it needs `TS_ACCEPT_DNS=true`. See the warning
under setup step 4. Turning that on has three consequences worth knowing before
changing it, because it rewrites `resolv.conf` for the whole **shared** netns:

| Consequence | Handled by |
|---|---|
| Gluetun's `-P OUTPUT DROP` blocks tailscaled's own resolvers, so every lookup in the netns fails with `Operation not permitted` | `tailscale-exit-routing` adds `OUTPUT -o tailscale0 -j ACCEPT` for **both** address families |
| musl (Alpine) queries every nameserver in `resolv.conf` rather than falling back, so the blocked IPv6 resolver alone fails the whole lookup even when the IPv4 one would answer | the IPv6 half of that same grant |
| A DNS-dependent Gluetun healthcheck could fail → deunhealth restarts Gluetun → the netns dies → `tailscale-exit` is left a zombie | `HEALTH_TARGET_ADDRESSES` pinned to IP literals |

Two traps when working on this, both of which cost a deploy cycle here:

- **Don't** grant the tailnet by adding `100.64.0.0/10` to
  `FIREWALL_OUTBOUND_SUBNETS`. It works, but Gluetun then installs its own
  `to 100.64.0.0/10 lookup 199` rule at priority 99, routing tailnet traffic out
  `eth0` and displacing the `lookup 52` rule the exit node's return path
  depends on. Grant it in `OUTPUT` instead. Its IPv6 counterpart is ignored
  outright — `ignoring subnet ... which has no default route matching its
  family` — since the Proton tunnel is IPv4-only.
- Rules must go to the **nft** backend (`iptables-nft` / `ip6tables-nft`). The
  tailscale image symlinks the plain names to `-legacy`, and a legacy `ACCEPT`
  does not override an nft `DROP` policy even though both are evaluated at the
  same hooks. A legacy rule applies cleanly and changes nothing, so verify with
  the same binary Gluetun uses, never just `iptables -S`.

**Healthcheck failing in `docker ps`.**
Normal until you complete the interactive auth in step 2. Once authenticated, the next healthcheck interval (30s) should flip to healthy.

**Connection works on cellular but not on a specific hotel/corporate WiFi.**
Some networks block all outbound UDP. Tailscale automatically falls back to DERP relay over TCP/443; just confirm in the admin console *Machines* view — the node may show "(via DERP)" instead of "direct".

---

## ✅ + Tailscale Complete!

Your tailnet now exposes the LAN privately to any device you've authorised. Add new devices via the admin console; revoke them the same way.

Issues? [Report on GitHub](https://github.com/leonardoazeredo/ultimate-arr-stack/issues).
