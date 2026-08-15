# Troubleshooting

## Gluetun: Harmless Log Noise on Startup

**Symptom:** Two scary-looking lines in `docker logs gluetun` even though the VPN appears to be working:

```
ERROR [vpn] getting public IP address information: persisting public ip address: open /tmp/gluetun/ip: permission denied
INFO  [healthcheck] listening for ICMP packets: not permitted: you can try adding NET_RAW capability to resolve this; permanently falling back to plain DNS over UDP checks
```

**Cause:** Both are non-fatal. The first is gluetun unable to cache the detected public IP to a file inside the container — the VPN connection itself is unaffected. The second is gluetun's healthcheck wanting to ping; we drop `NET_RAW` for security, so it falls back to DNS lookups (still a valid health signal).

**Confirm the VPN is actually working:**
```bash
# Should print your VPN exit IP, NOT your home IP
docker exec gluetun wget -qO- https://ifconfig.me
```

If that shows a different IP from your home connection, gluetun is fine — leave the warnings alone. If it shows your real IP (or times out), see the gluetun logs for `tunnel down`, `auth failed`, or the container restarting — those are the actual failure modes worth chasing.

## Indexers: New Releases Never Grab (VPN Exit Country Blocked)

**Symptom:** A monitored episode/movie that is clearly out (aired days ago) never gets grabbed. Sonarr/Radarr history is empty for it, nothing is in the queue, and an interactive search returns **0 releases**. Prowlarr health shows `Indexers unavailable due to failures for more than 6 hours: EZTV` (or another indexer), and that indexer is auto-disabled.

**Cause:** The VPN exit is in a country that legally blocks the indexer. Our stack defaults to `VPN_COUNTRIES=United Kingdom`, and the UK now serves Cloudflare-level legal blocks for several public torrent indexers. The block returns **HTTP 451** with a body like:

```
In response to a legal order, Cloudflare has taken steps to limit access
to this website through Cloudflare's pass-through security and CDN services
within United Kingdom.
```

Prowlarr (and all `*arr` indexer traffic) rides the gluetun tunnel, so every query exits through the blocked country. EZTV — the indexer most likely to carry a niche/new TV release — is the usual casualty.

**Diagnose:**
```bash
# 1. Confirm the VPN exit country
docker exec gluetun wget -qO- https://ipinfo.io/json   # look at "country"

# 2. Test the failing indexer in Prowlarr (id 3 = EZTV here; GET /indexer to list ids)
PK=<prowlarr-apikey>
curl -s -X POST "http://localhost:9696/api/v1/indexer/test?apikey=$PK" \
  -H "Content-Type: application/json" \
  -d "$(curl -s http://localhost:9696/api/v1/indexer/3?apikey=$PK)"
# "UnavailableForLegalReasons" / 451 in the error = legal block, not a dead indexer

# 3. Which indexers are in backoff
curl -s "http://localhost:9696/api/v1/indexerstatus?apikey=$PK"
```

**Fix — switch the VPN exit out of the blocking country:**
```bash
cd /volume1/docker/arr-stack
cp .env ".env.bak-$(date +%Y%m%d-%H%M%S)"          # .env is gitignored — edit on the NAS
sed -i 's/^VPN_COUNTRIES=United Kingdom$/VPN_COUNTRIES=Netherlands/' .env

# Recreate gluetun AND every container sharing its network namespace
# (sonarr, radarr, prowlarr, qbittorrent, sabnzbd, flaresolverr — all bounce together)
docker compose -f docker-compose.arr-stack.yml up -d

# Verify the new exit + that the indexer is reachable again
docker exec gluetun wget -qO- "https://eztvx.to/api/get-torrents?limit=1"   # HTTP 200 = unblocked

# Clear the indexer backoff so Prowlarr queries it again (disable then re-enable)
DEF=$(curl -s "http://localhost:9696/api/v1/indexer/3?apikey=$PK")
echo "$DEF" | python3 -c 'import sys,json;d=json.load(sys.stdin);d["enable"]=False;print(json.dumps(d))' \
  | curl -s -X PUT "http://localhost:9696/api/v1/indexer/3?apikey=$PK" -H "Content-Type: application/json" -d @-
echo "$DEF" | curl -s -X PUT "http://localhost:9696/api/v1/indexer/3?apikey=$PK" -H "Content-Type: application/json" -d @-
```

Surfshark's WireGuard key is account-wide, so changing only `VPN_COUNTRIES` is enough — gluetun picks a server in the new country with the same key. No new config from Surfshark is needed. The VPN only covers the download stack (qBittorrent/usenet/indexers/`*arr`), **not** Jellyfin, so a non-UK exit has no downside for playback. Leave it on a non-blocking country (e.g. Netherlands) to avoid recurrence; revert with the `.env` backup if ever needed.

> **Diagnostic gotcha — Prowlarr masks API keys.** `GET /api/v1/indexer/<id>` returns indexer secrets as a short placeholder, **not** the real key. If you curl an indexer's newznab API directly using that masked value you'll get `<error code="102" description="Empty API Key"/>` and zero results — which looks like a dead indexer but isn't. Prowlarr's own searches use the real key (32 chars for NZBgeek). Read the real value from `prowlarr.db` (`Indexers.Settings` JSON) before testing by hand, or just trust Prowlarr's search rather than a manual curl.

## Indexers: All Slow / Intermittently Failing (Throttled VPN Exit Server)

**Symptom:** Searches feel broken but nothing is hard-down. An interactive search or `GET /api/v1/search` takes **~50s** instead of a second or two. Per-indexer tests are slow (10s+) or return **HTTP 500**, and the slowness hits *everything* riding the tunnel at once — including reliable paid indexers like NZBgeek that should never be slow. Crucially, this is **not** a 451/legal block, and `GET /api/v1/indexerstatus` may show **0 failures** because nothing has crossed the 6-hour auto-disable threshold yet. The web UIs of VPN-protected services (Prowlarr/qBittorrent) also feel laggy and jittery (response times jumping 10ms → 4s).

This can masquerade as unrelated problems: a `*.lan` service like `seerr.lan` "feeling slow" is **not** caused by this (that path is local and never touches the VPN) — but *triggering a search/request inside Jellyseerr* is, because that call fans out seerr → Sonarr/Radarr → Prowlarr → tunnel.

**Cause:** The specific WireGuard server gluetun happened to connect to is congested or throttled (or partially degraded). The country is fine — it's just a bad server, and gluetun will sit on it indefinitely. The exit IP resolves and basic reachability works (so it's not a tunnel-down or auth failure), it's just slow. Distinct from the geo-block case above (HTTP 451), which needs a *country* change.

**Diagnose:**
```bash
PK=<prowlarr-apikey>
# Aggregate search time — the headline symptom (healthy = ~1-2s, throttled = ~50s)
time curl -s "http://localhost:9696/api/v1/search?query=ubuntu&type=search&limit=5" -H "X-Api-Key: $PK" >/dev/null

# Per-indexer latency — throttled = several seconds each and/or HTTP 500
for id in $(curl -s "http://localhost:9696/api/v1/indexer" -H "X-Api-Key: $PK" | python3 -c 'import sys,json;[print(i["id"]) for i in json.load(sys.stdin)]'); do
  cfg=$(curl -s "http://localhost:9696/api/v1/indexer/$id" -H "X-Api-Key: $PK")
  code=$(printf '%s' "$cfg" | curl -s -o /dev/null -w '%{http_code} %{time_total}s' -X POST "http://localhost:9696/api/v1/indexer/test" -H "X-Api-Key: $PK" -H "Content-Type: application/json" --data-binary @-)
  echo "indexer $id: $code"
done

# Confirm the exit IP (note it, so you can verify it changes after the restart)
docker exec gluetun wget -qO- https://ipinfo.io/ip
```

**Fix — bounce gluetun onto a fresh server (same country, no `.env` change):**
```bash
cd /volume1/docker/arr-stack
docker restart gluetun                       # reconnects to a *different* server with the same key
# Wait for healthy (~50s), confirm the exit IP changed:
docker inspect -f '{{.State.Health.Status}}' gluetun
docker exec gluetun wget -qO- https://ipinfo.io/ip

# REQUIRED: restart every container sharing gluetun's network namespace.
# Restarting gluetun alone severs their networking — they go dead (empty/000 responses)
# until bounced too.
docker restart prowlarr qbittorrent          # add sabnzbd/sonarr/radarr/bazarr if they share the netns
```

Re-run the aggregate search to confirm it's back to ~1-2s. (Observed 2026-06-19: a throttled NL server gave a 54s search with two indexers at HTTP 500; `docker restart gluetun` + bouncing the dependents dropped it to **1.2s**, no config change.) If the new server is *also* slow, restart gluetun again to roll the dice on another. Only switch `VPN_COUNTRIES` (the section above) if you actually see HTTP 451 — that's a different problem.

## Apps Unreachable After a VPN Reconnect (Stale Network Namespace)

> **Note (v1.7.23):** Sonarr and Radarr were moved off the VPN onto the bridge, so they are **no longer affected** by this — a gluetun restart can't strand them. This section now applies only to the remaining VPN-bound apps: **qBittorrent, SABnzbd, Prowlarr, FlareSolverr**.

**Symptom:** After gluetun restarts (VPN reconnect, server switch, or container recreate), some VPN-bound apps go unreachable from the rest of the stack even though `docker ps` shows them **Up (healthy)**. Classic tells: Prowlarr reporting FlareSolverr down, or Sonarr/Radarr unable to reach their download clients (grabs not starting). The affected container answers fine on its own `localhost` but refuses connections from anything else.

**Cause:** These services use `network_mode: "service:gluetun"`, so they share gluetun's network namespace. When gluetun restarts, that namespace is destroyed. Two things can happen to each dependent:
- It is SIGKILLed and stays **Exited** (docker can't rejoin a vanished namespace), or
- It keeps **running as a zombie** on the dead namespace — alive on `127.0.0.1`, invisible to the network, and its localhost healthcheck still passes so it shows green.

The second case is the nasty one: everything *looks* fine. `deunhealth` won't touch it (it's not unhealthy) and an exited-only watcher misses it.

**Auto-recovery (built in):** The `gluetun-recover` watcher handles both cases. On every gluetun `health_status: healthy` event it restarts any `gluetun.dependent=true` container that is Exited **or** whose `StartedAt` predates gluetun's current start (a stale-namespace zombie). No action needed — give it ~30-60s after gluetun goes healthy.

**Verify / manual fix if ever needed:**
```bash
# Any dependent started BEFORE gluetun is a stale zombie:
g=$(docker inspect -f '{{.State.StartedAt}}' gluetun | cut -c1-19); echo "gluetun: $g"
for c in qbittorrent sabnzbd prowlarr flaresolverr; do
  echo "  $c: $(docker inspect -f '{{.State.StartedAt}}' $c | cut -c1-19)"
done
# Confirm reachability through the shared namespace:
docker exec seerr   wget -qO- http://gluetun:9696/ping   # prowlarr -> {"status":"OK"}
docker exec prowlarr wget -qO- http://127.0.0.1:8191/    # flaresolverr -> "ready" (use 127.0.0.1, it's IPv4-only)

# Manual recovery (gluetun-recover does this automatically):
docker restart qbittorrent sabnzbd prowlarr flaresolverr   # or whichever started before gluetun
```

`./scripts/detect-vpn-zombies.sh` automates the check above — it compares each dependent's `network_mode` binding against Gluetun's *current* container ID and prints exactly which ones are stale. It's also exercised as `tests/e2e/resilience.spec.ts` in the Playwright suite. Run it any time you suspect a zombie, or on a schedule via cron/SSH.

## NEVER Use `--remove-orphans` (Multi-Compose-File Project)

This stack splits its services across several compose files (`docker-compose.arr-stack.yml`, `docker-compose.utilities.yml`, `docker-compose.traefik.yml`, …) that share **one project directory and project name**. To compose, any running container of the project that is not defined in the file you passed with `-f` is an *orphan*. So:

```bash
# DO NOT DO THIS — it deletes every container from the OTHER compose files:
docker compose -f docker-compose.arr-stack.yml up -d --remove-orphans
```

This happened for real on 2026-08-01 (~20:30 BST): a single `--remove-orphans` run removed **traefik, camera-listen, cloudflared, diun, uptime-kuma, beszel, beszel-agent, gluetun-recover, deunhealth, duc and configarr** in one stroke. Volumes and configs survived (downtime only), and everything had to be restored file by file.

The same split has a second face: **recreate a service only via the file that defines it.** Attachments and settings that live in one file are silently dropped if the container is ever brought up through another path — e.g. traefik's `traefik-lan` macvlan (its `10.10.0.11` LAN presence) exists only in `docker-compose.traefik.yml`; a traefik container created without that file comes up bridge-only and **every `.lan` URL dies while the container still reports healthy** (also observed 2026-08-01).

If you actually need to prune an orphan, remove that one container by name with `docker rm`.

### After a Gluetun RECREATE (not just a restart), `docker restart` cannot save you

Everything above assumes gluetun was **restarted** — same container, same ID. If gluetun is **recreated** (its config in the compose file drifted, so *any* `docker compose up -d`, even of an unrelated service like seerr, replaces it), the dependents' `network_mode: "service:gluetun"` still points at the **old container ID**. They are SIGKILLed (exit 137), and now `docker restart` — whether run by you or by `gluetun-recover` — fails with:

```
Error response from daemon: ... joining network namespace of container <old-id>: No such container
```

`gluetun-recover` logs this failure loudly but **cannot fix it** (it would need to run compose, which it can't). The only fix is a compose-level recreate of the dependents so they bind to the new gluetun container:

```bash
cd /volume1/docker/arr-stack
docker compose -f docker-compose.arr-stack.yml up -d qbittorrent sabnzbd prowlarr flaresolverr
```

Run `./scripts/detect-vpn-zombies.sh` afterward to confirm every dependent now binds to Gluetun's *new* container ID rather than the old one — this is the exact scenario it's built to catch.

**If that compose command hangs:** a dependent that died mid-netns-join can land in a `Dead` state that dockerd can never remove (`docker rm -f` → "removal of container is already in progress", forever). Compose then wedges trying to replace it, or leaves the replacement under a hash-prefixed name (`<id>_flaresolverr`). The only cure is a Docker daemon restart, which also clears the Dead container (observed 2026-08-01 with flaresolverr; check nobody is streaming first):

```bash
sudo systemctl restart docker    # bounces the whole stack; ~2-3 min to settle
```

**Prevention:** before any `docker compose up -d <service>` on the arr-stack file, check whether gluetun would be recreated too, and plan for the dependents:

```bash
docker compose -f docker-compose.arr-stack.yml up -d --dry-run <service> 2>&1 | grep -i recreate
```

## SABnzbd: Stuck Unpack Loop

**Symptom:** Radarr shows "Downloading" at 100% with 0 B file size. SABnzbd UI is unresponsive or Save fails. Logs show `Unpacked files []` repeatedly.

**Cause:** NZB had obfuscated filenames + par2 files but no RARs. The unpacker finds nothing to extract and retries on every SABnzbd restart, creating a new `_UNPACK_*` directory each time. Each copy is 20-50+ GB — this can silently eat TBs of disk space. The stuck post-processing loop also locks up SABnzbd's API and UI.

**Diagnose:**
```bash
# _UNPACK_ buildup = stuck unpack loop
ls -d /volume1/data/usenet/incomplete/_UNPACK_* | wc -l
du -shc /volume1/data/usenet/incomplete/_UNPACK_*

# Confirm in SABnzbd logs
docker logs sabnzbd --tail 200 2>&1 | grep "Unpacked files"
# "Unpacked files []" = nothing to unpack, stuck
```

**Fix:**
```bash
# 1. Stop SABnzbd (API will be unresponsive, must use docker stop)
docker stop sabnzbd

# 2. Delete the postproc queue to clear the stuck job
#    (The history API delete is NOT enough — the postproc queue is separate
#    and will re-trigger the loop on every restart)
sudo rm /volume1/@docker/volumes/arr-stack_sabnzbd-config/_data/admin/postproc2.sab

# 3. Delete all failed _UNPACK_ attempts to reclaim disk space
rm -rf /volume1/data/usenet/incomplete/_UNPACK_<release_name>*

# 4. Move the actual file (in incomplete/) to the movie folder
mkdir -p "/volume1/data/media/movies/MovieName (Year)"
mv "/volume1/data/usenet/incomplete/<release>/obfuscated.mkv" \
   "/volume1/data/media/movies/MovieName (Year)/MovieName (Year).mkv"
rm -rf "/volume1/data/usenet/incomplete/<release>"

# 5. Start SABnzbd back up
docker start sabnzbd

# 6. Remove from Radarr queue (get queue ID from queue API)
docker exec radarr curl -s -X DELETE \
  "http://localhost:7878/api/v3/queue/ID?removeFromClient=false&blocklist=false&apikey=KEY"

# 7. Tell Radarr to pick up the file
docker exec radarr curl -s -X POST "http://localhost:7878/api/v3/command" \
  -H "Content-Type: application/json" -H "X-Api-Key: KEY" \
  -d '{"name":"RefreshMovie","movieIds":[MOVIE_ID]}'
```

**Prevention:** No SABnzbd setting fully prevents this. Monitor disk usage (Beszel/duc) and investigate if a movie stays at "Downloading 100%" for more than 30 minutes.

## Pi-hole: Doesn't Start After Reboot

**Symptom:** After every NAS reboot, Pi-hole stays in `Exited (128)` state. All other containers start fine. Your network loses DNS resolution until you manually `docker start pihole`.

**Cause:** Pi-hole binds to `${NAS_IP}:53` (it can't use `0.0.0.0:53` because most NAS OS's run dnsmasq on `127.0.0.1:53`). If `NAS_IP` is assigned via DHCP, Docker starts before the DHCP handshake completes — the IP doesn't exist yet, the port bind fails with exit 128, and Docker's restart policy does not retry start failures (only process exits).

**Diagnose:**
```bash
# Check if Pi-hole is stopped
docker ps -a --filter name=pihole
# Look for: Exited (128)

# Check the error
docker inspect pihole --format "{{.State.Error}}"
# Look for: "listen tcp4 <IP>:53: bind: cannot assign requested address"

# Confirm your IP is from DHCP
ip addr show eth0 | grep inet
# "dynamic" = DHCP (the problem). No "dynamic" = static (correct).
```

**Fix:** Configure a static IP on the NAS itself (not just a DHCP reservation on your router):
```bash
# Back up current config
sudo cp /etc/network/interfaces.d/ifcfg-eth0 /etc/network/interfaces.d/ifcfg-eth0.bak

# Edit to static (replace IP, gateway, netmask with YOUR network values)
sudo tee /etc/network/interfaces.d/ifcfg-eth0 << 'EOF'
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 1.1.1.1 8.8.8.8
iface eth0 inet6 dhcp
EOF

# Reboot and verify
sudo reboot
# After reboot: ip addr show eth0 should show NO "dynamic" flag
# docker ps should show pihole Up
```

**Why DHCP reservation isn't enough:** A DHCP reservation on your router guarantees the same IP every time, but the NAS still *obtains* it via DHCP at boot. The DHCP handshake takes a few seconds — by which time Docker has already tried and failed to start Pi-hole. A static IP is configured directly on the NAS, so it's available the moment the interface comes up — no router involved, no delay.

**Keep the DHCP reservation too:** After switching to a static IP, keep the reservation on your router. The static IP means the NAS claims it instantly at boot; the reservation means the router won't hand out that same IP to another device via DHCP. Both together prevent IP conflicts.

## Docker: Ports Not Published After Reboot (Containers "Running", Nothing Listening)

**Symptom:** After any reboot — or a UGOS update — the whole network loses DNS, yet everything *looks* fine. `docker ps` shows Pi-hole `Up` and **healthy**. The giveaway is the `PORTS` column: it's **empty** for pihole, and nothing is listening on `${NAS_IP}:53`.

**This is not the exit-128 problem above.** There, Pi-hole is *stopped* and the cause is obvious. Here it is *running and answering nobody*, which is far harder to spot — `docker ps`, health status and the Pi-hole UI all look normal.

**Cause:** at boot the Docker **daemon** restores containers itself (`restart: always`) — compose is not involved, so no amount of `depends_on` affects it. Bindings pinned to a specific host IP fail to be established, and this Docker version logs it and starts the container anyway rather than refusing. Verified across three reboots on 2026-08-05: **pihole, baserow and therapybot — the only three containers pinned to `${NAS_IP}` — failed every time, while all 13 wildcard-bound containers were fine.** A single failed binding drops the container's *entire* mapping set, which is why Pi-hole also lost its `0.0.0.0:8081` web UI.

Pi-hole's healthcheck (`dig @127.0.0.1` *inside* the container) passes throughout, so neither `docker ps` nor `deunhealth` will ever flag this.

**Diagnose:**
```bash
docker ps --format "{{.Names}}\t{{.Ports}}" | grep pihole   # empty PORTS = not published
ss -tlnp | grep ':53 '                                      # only 127.0.0.1:53 = UGOS's own dnsmasq
dig @<NAS_IP> google.com                                    # "connection refused"
```

**Fix (permanent):** `scripts/boot-compose-up.sh`, run at boot by `scripts/boot-compose-up.service`. It runs `docker compose up -d` across every deployed stack, which reconciles each container against its compose file and re-establishes the bindings. Deployed as:

| Repo | On the NAS |
|---|---|
| `scripts/boot-compose-up.sh` | `/volume1/docker/boot-compose-up.sh` (symlink into this repo) |
| `scripts/boot-compose-up.service` | `/etc/systemd/system/boot-compose-up.service` (`systemctl enable`) |

DNS is back ~20s after boot (Pi-hole's stack is first in the list, deliberately); the full sweep takes ~5 minutes.

**Critical: use `Wants=`, never `Requires=` or `RequiresMountsFor=` in that unit.** The first version used `RequiresMountsFor=/volume1` + `Requires=docker.service`. Those are *hard* dependencies: `/volume1` wasn't mounted nine seconds into boot, so systemd failed the job outright (`Job boot-compose-up.service/start failed with result 'dependency'`) and **never retried**. DNS stayed down and the unit sat `inactive (dead)` with no error visible in `systemctl status`. The unit now waits for the script itself in `ExecStart`.

**A static IP does NOT fix this** (unlike the exit-128 case above). UGOS reverts the Control Panel setting to DHCP on reboot, and `/etc/network/interfaces.d/ifcfg-eth0` has declared `static` since February while UGOS's own `dhclient@eth0.service` overrides it regardless.

**Manual repair**, if the unit is ever missing or you need DNS back now — no root required, `mooseadmin` is in the `docker` group:
```bash
sh /volume1/docker/boot-compose-up.sh
```

**Reading boot logs:** `mooseadmin` must be in the `systemd-journal` group or `journalctl` silently returns nothing, which reads exactly like "no logs" rather than "no permission" — that mistake cost an hour of diagnosis. `sudo usermod -aG systemd-journal mooseadmin`.

## Pi-hole: Gravity Update Fails With Empty Status

**Symptom:** Running `pihole -g` (or "Update Gravity" in the web UI) shows a blocklist with a blank status and falls back to cache:

```
[i] Target: https://raw.githubusercontent.com/.../SmartTV.txt
[✗] Status: https://raw.githubusercontent.com/.../SmartTV.txt ()
[✗] List download failed: using previously cached list
```

The empty `()` is the curl HTTP code — empty means curl never got a response. Other lists from the same domain succeed, so it isn't network or DNS.

**Cause:** A file in `/etc/pihole/listsCache/` is owned by `root` instead of `pihole`. Gravity runs as the `pihole` user and uses curl's `--etag-save` to update the etag file; if that file is root-owned, curl can't overwrite it and exits before producing an HTTP code. `gravity.sh` swallows curl's stderr (`2>/dev/null`), so the only visible symptom is the empty status. This typically comes from an old Pi-hole image version that didn't chown files back to `pihole` after running gravity as root.

**Diagnose:**
```bash
docker exec pihole ls -la /etc/pihole/listsCache/
# Files owned by root: that's the problem. Should all be pihole:pihole.
```

**Fix:**
```bash
docker exec -u root pihole chown -R pihole:pihole /etc/pihole/listsCache
docker exec pihole pihole -g   # confirm both lists succeed
```

Current Pi-hole versions chown files back to `pihole` after each gravity run, so once corrected this shouldn't recur.

## Seerr: "/app/config volume mount was not configured properly"

**Symptom:** Seerr container starts but logs `The /app/config volume mount was not configured properly` (or similar) and the web UI is unreachable.

**Cause:** Seerr does a strict check on `/app/config` at startup and is fussier than Jellyseerr was. Usually triggered by a half-initialised `seerr-config` volume from an interrupted earlier start — failed `up -d`, container OOM, Ctrl+C mid-init, etc.

**Diagnose:**
```bash
docker logs seerr --tail 30
```

**Fix:** Wipe and re-init the volume.

```bash
docker compose -f docker-compose.arr-stack.yml stop seerr
docker volume rm arr-stack_seerr-config
docker compose -f docker-compose.arr-stack.yml up -d seerr
docker logs seerr --tail 30
```

> **⚠️ Destructive.** Safe on a fresh install before you've configured Seerr. Once you've added Sonarr/Radarr connections, users, or requests, this wipes them — back up `/var/lib/docker/volumes/arr-stack_seerr-config/_data/` first if you need to preserve state.

If a fresh wipe still hits the same error, post `docker logs seerr` output as a GitHub issue.

## Jellyfin: Video Stutters/Freezes Every Few Minutes

**Symptom:** Playing large video files (especially 4K remuxes, 50-100+ GB) causes playback to freeze for a few seconds every 2-3 minutes, then resume. Happens on both Jellyfin apps and Kodi with Jellyfin plugin. Jellyfin dashboard may show "Direct Play" (no transcoding).

**Cause:** UGOS default RAID5 read-ahead is 384 KB — far too small for streaming large files. This forces the kernel to issue many small IO requests to spinning HDDs, each triggering a disk seek (5-10ms). At high bitrates (60+ Mbps for 4K remuxes), the IO queue backs up, disk utilization hits 90%+, and the stream buffer empties causing the stall.

**Diagnose:**
```bash
# Check current read-ahead (384 = too low for streaming)
cat /sys/block/md1/queue/read_ahead_kb
cat /sys/block/dm-0/queue/read_ahead_kb

# Check stripe cache (256 = default, too low)
cat /sys/block/md1/md/stripe_cache_size

# Monitor disk IO during playback (look for high %util and w_await)
iostat -x 1 5 | grep -E "Device|dm-0"
```

**Fix:** Increase read-ahead and stripe cache to allow larger sequential reads:
```bash
# Apply immediately (requires root)
sudo bash -c '
echo 4096 > /sys/block/md1/queue/read_ahead_kb
echo 4096 > /sys/block/dm-0/queue/read_ahead_kb
echo 4096 > /sys/block/md1/md/stripe_cache_size
'
```

**Make permanent:** Add a `@reboot` cron job for root (**not** `/etc/rc.local` — UGOS overwrites it on firmware updates):
```bash
# Add to root crontab (sleep 30 lets RAID finish initialising)
sudo crontab -e
# Add this line:
@reboot sleep 30 && echo 4096 > /sys/block/md1/queue/read_ahead_kb && echo 4096 > /sys/block/dm-0/queue/read_ahead_kb && echo 4096 > /sys/block/md1/md/stripe_cache_size
```

> **Warning:** Do NOT use `/etc/rc.local` for custom tuning on UGOS — firmware updates silently overwrite it. Use root crontab `@reboot` instead.

**Result:** Disk utilization drops from ~96% to ~8-15% during 4K playback. Read latency drops from 20ms to 3-7ms. Stalls eliminated.

**Note:** SSD caching will **not** help with video streaming — it only accelerates frequently re-read data, and video playback is sequential read-once.

## Memory: Unnecessary Swap With Plenty of Free RAM

**Symptom:** `free -h` shows several GB of swap used even though there's plenty of available RAM. System feels slower than expected for the amount of RAM installed.

**Cause:** UGOS default `vm.swappiness=60` tells the kernel to aggressively move inactive pages to swap (including zram) even when RAM is plentiful. This is fine for a desktop but suboptimal for a server where you want application pages to stay resident.

**Diagnose:**
```bash
# Check swappiness (60 = too aggressive for a server with plenty of RAM)
cat /proc/sys/vm/swappiness

# Check swap usage (zram = compressed RAM, not disk — but still has overhead)
cat /proc/swaps
free -h
```

**Fix:**
```bash
# Apply immediately
sudo bash -c 'echo 10 > /proc/sys/vm/swappiness'

# Verify
cat /proc/sys/vm/swappiness
# Should show: 10
```

**Make permanent:** Add to the root `@reboot` crontab (alongside RAID5 tuning if present):
```bash
sudo crontab -e
# Append to existing @reboot line, or add new:
@reboot sleep 30 && echo 10 > /proc/sys/vm/swappiness
```

> **Note:** `swappiness=10` doesn't disable swap — the kernel will still swap under real memory pressure. It just stops proactively swapping out app pages to make room for disk cache when there's no pressure.

## SSH: Post-Quantum Key Exchange Warning

**Symptom:** Every SSH connection to the NAS shows:
```
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
```

**Cause:** macOS OpenSSH 10.x warns when the connection doesn't use a post-quantum key exchange algorithm (`sntrup761x25519-sha512@openssh.com`). UGOS ships OpenSSH 9.2 which supports the algorithm, but the UGOS-managed `/etc/ssh/sshd_config.d/high_crypt.conf` sets `KexAlgorithms` without it — so it's never offered to clients.

**Fix (two parts):**

1. **NAS — add a drop-in config** that loads before the UGOS-managed one:
```bash
sudo tee /etc/ssh/sshd_config.d/00-pq-kex.conf << 'EOF'
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
EOF
sudo systemctl restart sshd
```

The `00-` prefix ensures it loads before `high_crypt.conf` (alphabetical order, first match wins in sshd).

2. **Client (Mac) — add to `~/.ssh/config`:**
```
Host your-nas.local
    KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
```

**Verify:**
```bash
ssh -vv user@your-nas.local 'exit' 2>&1 | grep 'kex: algorithm'
# Should show: sntrup761x25519-sha512@openssh.com
```

**UGOS resilience:** The `sshd_config.d/` drop-in directory is less likely to be wiped than the main config (same principle as using `@reboot` crontab instead of `/etc/rc.local`). If a UGOS update does remove it, you'll just see the warning again — nothing breaks. The client-side config on your Mac is completely UGOS-proof.

