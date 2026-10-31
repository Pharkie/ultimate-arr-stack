# Upgrading the Stack

Already running an earlier version? There are two types of upgrades:

1. **Stack updates** — New features, bug fixes, compose changes from this repo
2. **Container image updates** — Newer versions of Sonarr, Radarr, Jellyfin, etc.

## Stack Updates (this repo)

SSH into your NAS and pull the latest changes:

```bash
ssh your-username@nas-ip
cd $NAS_STACK_DIR  # or your deployment path

git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate  # Updates AND restarts - no further steps needed
# If you also run utilities (beszel, uptime-kuma, etc.), add -f docker-compose.utilities.yml after the first -f
```

The `--force-recreate` flag ensures containers restart with new config even if the image hasn't changed.

## Container Image Updates (Sonarr, Jellyfin, etc.)

The compose files pin every image to a version, so newer Sonarr, Jellyfin and so on arrive as a stack update (above). `pull` fetches the pinned tags, for example after a `git pull` or after you change a tag yourself:

```bash
docker compose -f docker-compose.arr-stack.yml pull
docker compose -f docker-compose.arr-stack.yml up -d  # Restarts containers with new images - no further steps needed
# If you also run utilities (beszel, uptime-kuma, etc.), add -f docker-compose.utilities.yml to both commands
```

> **Ugreen NAS users: turn UGOS's automatic image updates off** (Docker app → Management → Image update → untick **Update detection**). It replaces containers outside compose, and it cannot rebuild the ones that share gluetun's network: it deletes them and fails to create the replacements. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#indexers-all-unavailable-every-monday-morning-ugos-docker-auto-update).

> **Note:** Docker named volumes persist across restarts. All your service configurations (Sonarr settings, API keys, library data, etc.) are preserved.

---

## Migration Notes

When upgrading across versions, check below for any action required.

### v1.18.0 → Unreleased

dnscrypt-proxy's config now lives in the repo as `dnscrypt-proxy/dnscrypt-proxy.toml`, bind-mounted read-only over the copy in the `dnscrypt-config` volume. It is the image default plus `disabled_server_names = ['yunzheng-dns64']`, a DNS64 resolver in the public pool whose synthesised `64:ff9b::/96` answers nothing on a dual-stack LAN can route. `git pull` brings the file; recreating the service applies the mount:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml up -d --no-deps dnscrypt-proxy
```

Pi-hole answers from its cache while dnscrypt-proxy comes back (about 25 seconds to a full server list). An answer Pi-hole already cached from the DNS64 resolver expires with its TTL; `docker exec -u pihole pihole pihole reloaddns` flushes the cache now without restarting the DNS server (as the `pihole` user: FTL runs as that user, and with every capability dropped root in the container can't signal it).

If you keep a customised copy of `docker-compose.arr-stack.yml`, add the `group_add` and the second `volumes:` line to the service yourself before the `up -d`. The group matters on a NAS whose shares admit only its own accounts (UGOS): without it the image's uid 65532 gets `permission denied` on the mounted file and the container restart-loops, leaving Pi-hole with no upstream.

```yaml
    group_add:
      - "${PGID}"
    volumes:
      - dnscrypt-config:/config
      - ./dnscrypt-proxy/dnscrypt-proxy.toml:/config/dnscrypt-proxy.toml:ro
```

Or leave compose alone and change the copy in the volume. The image has no shell, so copy the file out and back:

```bash
docker cp dnscrypt-proxy:/config/dnscrypt-proxy.toml /tmp/dnscrypt-proxy.toml
sed -i "s/^disabled_server_names = \[\]/disabled_server_names = ['yunzheng-dns64']/" /tmp/dnscrypt-proxy.toml
docker cp /tmp/dnscrypt-proxy.toml dnscrypt-proxy:/config/dnscrypt-proxy.toml
docker compose -f docker-compose.arr-stack.yml restart dnscrypt-proxy
```

That edit lives in the volume and is lost when the volume is recreated; the mount is the durable fix.

Seven image bumps arrive with the same `git pull` and need nothing beyond a pull and an `up -d` per compose file. Two of them change behaviour you may rely on:

- **Uptime Kuma 2.5.8 removes TLS from the TCP Port monitor.** A TCP monitor that had TLS switched on becomes a plain port check and stops checking the certificate. Look at your TCP monitors before upgrading, and replace any you need with an HTTP(S) monitor (which checks certificate expiry). The stack's own monitors are all HTTP or push, so nothing changes for them.
- **Prowlarr 2.7.0 drops `0.0.0.0` and `[::]` from Allowed Hosts** and logs "Ignoring … in Allowed Hosts, bind addresses are not host names". If those were the only entries, the list is now empty and Prowlarr accepts any Host header, as it does when the setting is left blank (the default here). Put real hostnames there if you meant to filter.

### v1.17.0 → v1.18.0

Eight image bumps. Pi-hole's gravity database migration is one-way and qBittorrent rewrites its config file to a newer layout, so back up those two volumes first, with the services stopped. Jellyfin 12.3 runs no migration; back it up only if you want to, and know that `jellyfin-config` is about 4 GB (almost all `metadata/`), so a gzip takes around 12 minutes on a NAS CPU with Jellyfin down. Use `tar cf` or `--exclude=./metadata`. Check that nothing is playing or downloading first: recreating Pi-hole takes every `.lan` name and LAN DNS down for about 35 seconds, and stopping qBittorrent pauses its downloads.

Pass only the services you mean, each through its own compose file, and never `--remove-orphans`:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml pull pihole qbittorrent jellyfin dnscrypt-proxy
docker compose -f docker-compose.arr-stack.yml stop pihole qbittorrent
mkdir -p backups
for v in pihole-etc-pihole qbittorrent-config; do
  docker run --rm -v arr-stack_$v:/src:ro -v "$PWD/backups":/bak alpine tar cf /bak/$v-$(date +%Y%m%d).tar -C /src .
done
docker compose -f docker-compose.arr-stack.yml up -d --no-deps pihole qbittorrent jellyfin dnscrypt-proxy

docker compose -f docker-compose.cloudflared.yml pull cloudflared
docker compose -f docker-compose.cloudflared.yml up -d --no-deps cloudflared
docker compose -f docker-compose.tailscale.yml pull tailscale
docker compose -f docker-compose.tailscale.yml up -d tailscale
docker compose -f docker-compose.utilities.yml pull uptime-kuma
docker compose -f docker-compose.utilities.yml up -d --no-deps uptime-kuma
```

configarr is opt-in and is pulled the next time you run it. Afterwards:

- **Pi-hole:** `http://pihole.lan/` now answers 404. Use `http://pihole.lan/admin/`, and point any monitor or bookmark of your own at `/admin/` too. Pi-hole's own 17 fixes are in; nothing to configure. Over the first night it deletes queries older than `database.maxDBdays` (91), which may take a while on a large `pihole-FTL.db`.
- **qBittorrent:** settings carry over (port, server domains, auth whitelist, categories, VueTorrent). If you sit it behind a reverse proxy that sets `X-Forwarded-For`, 5.3.0 stops trusting that header for authentication, which is the point of the fix.
- **Jellyfin:** wait for `Startup complete` in `docker logs jellyfin`. A script of your own that authenticates with `X-Emby-Token` gets 401 from Jellyfin 12; send `Authorization: MediaBrowser Token="<key>"` instead.
- **Tailscale, cloudflared, Uptime Kuma, dnscrypt-proxy:** nothing to do.

### v1.16.1 → v1.17.0

One image bump. Seerr's release is security-only with no database migration, so `git pull`, then recreate it through its own compose file:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml pull seerr
docker compose -f docker-compose.arr-stack.yml up -d --no-deps seerr   # v3.5.1
```

On a NAS CPU, Seerr takes a few minutes from container start to `Server ready on port 5055` in `docker logs seerr`, and its page answers nothing until then. The healthcheck allows for it; don't recreate it again.

Nothing else in this release touches a running container.

- **The daily stuck-request check** is new and optional. It posts through `HA_WEBHOOK_URL` in `.env` (set up in v1.16.0). Prove the webhook with `./scripts/check-stuck-requests.sh --test` and look for the notice in the Home Assistant panel, run it once by hand with `-v` to see what it would report, then add the cron line from [MAINTENANCE.md § Stuck Requests](MAINTENANCE.md#stuck-requests). Only `--apply` changes anything in an app: it queues a Sonarr or Radarr search for a release RSS missed.
- **Uptime Kuma:** if you set up Kuma's notification from the earlier steps and alerts arrive twice, delete the older notification ([HOME-ASSISTANT.md](HOME-ASSISTANT.md)).
- **e2e tests on your dev machine:** `npm ci` picks up dotenv 18.

### v1.16.0 → v1.16.1

DIUN is removed. `git pull`, then delete what an earlier version left behind. Compose no longer knows the service, so remove it by name:

```bash
docker rm -f diun                      # if it is still there
docker volume rm arr-stack_diun-data   # only its record of tags it has seen
```

Delete `DIUN_SCHEDULE` and `DIUN_WEBHOOK_URL` from `.env`. In Home Assistant, the automation's DIUN branch is now dead code and does no harm. To drop it, delete the lines that mention `diun` (or re-paste [HOME-ASSISTANT-notifications.yaml](HOME-ASSISTANT-notifications.yaml), keeping your `CHANGE-ME` values and any changes of your own).

### v1.15.0 → v1.16.0

**On a Ugreen NAS, first turn off UGOS's image updater** (Docker app → Management → Image update → untick **Update detection** → Apply). It deletes containers it can't rebuild.

Eight image bumps. Jellyfin's and Beszel's database changes are one-way, so back up their config volumes first, with both stopped (the `up -d` below starts them again on the new images). Pass only the services you mean, each through its own compose file, and never `--remove-orphans`:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml stop jellyfin
docker compose -f docker-compose.utilities.yml stop beszel
mkdir -p backups
for v in jellyfin-config beszel-data; do
  docker run --rm -v arr-stack_$v:/src:ro -v "$PWD/backups":/bak alpine tar czf /bak/$v-$(date +%Y%m%d).tgz -C /src .
done

docker compose -f docker-compose.arr-stack.yml pull jellyfin qbittorrent
docker compose -f docker-compose.arr-stack.yml up -d --no-deps jellyfin qbittorrent seerr bazarr   # seerr/bazarr: depends_on changed
docker compose -f docker-compose.cloudflared.yml pull cloudflared
docker compose -f docker-compose.cloudflared.yml up -d --no-deps cloudflared
docker compose -f docker-compose.utilities.yml pull gluetun-recover uptime-kuma beszel beszel-agent
docker compose -f docker-compose.utilities.yml up -d --no-deps gluetun-recover uptime-kuma beszel beszel-agent
```

Wait for `Startup complete` in `docker logs jellyfin`; its healthcheck goes green before the migrations finish.

- **Notifications:** set up the one automation and point every sender at it ([HOME-ASSISTANT.md](HOME-ASSISTANT.md)). If Uptime Kuma uses its *Home Assistant* notification type, switch it to the webhook described there, then press **Test** and check your phone.
- **DIUN:** removed in v1.16.1; see above.
- **Backups grow** (the Sonarr, Radarr and Jellyfin databases are now in them), and a backup with a failed volume exits 1.

### v1.14.0 → v1.15.0

`git pull`, then recreate the two services whose definitions changed, each through its own compose file:

```bash
docker compose -f docker-compose.arr-stack.yml up -d --no-deps seerr        # v3.5.0
docker compose -f docker-compose.tailscale.yml up -d tailscale               # hardened capabilities
```

Re-run `./setup-hooks.sh` if you use the pre-commit hook. `check-vpn.sh` keeps its contract (exit 0 means the VPN checked out), so a cron line or Kuma push monitor keeps working; its output wording has changed. Backups no longer leave a plain-text working copy in `/tmp`, but copies left by earlier versions stay until you delete them (`/tmp/arr-stack-backup-<date>` directories): check your latest archive first.

### v1.13.5 → v1.14.0

Twelve image bumps. Back up the config volumes first (Jellyfin 12.1's database migrations are one-way), then pull and recreate as usual. Pass only the services you mean to recreate, and never `--remove-orphans`:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml pull sonarr radarr prowlarr bazarr jellyfin pihole
docker compose -f docker-compose.arr-stack.yml up -d --no-deps sonarr radarr prowlarr bazarr jellyfin pihole
```

Do the same for `uptime-kuma beszel beszel-agent duc` in `docker-compose.utilities.yml`, and for `docker-compose.cloudflared.yml` and `docker-compose.tailscale.yml` if you run them. Jellyfin is ready when its log says `Startup complete`, not when the healthcheck turns green. Recreating Pi-hole drops DNS for your network for a few seconds.

Two things may need a hand:

- **Sonarr, Radarr or Prowlarr asks for a login at its `.lan` address.** They now trust forwarded headers only from their *Trusted Networks* setting, so *Authentication Required: Disabled for Local Addresses* no longer applies through Traefik. Set Settings → General → Security → Authentication Required to **Enabled**. Don't add `172.20.0.0/24` to Trusted Networks: Cloudflare Tunnel traffic arrives from inside it.
- **configarr no longer runs on `up -d`.** Run it on purpose with `docker compose -f docker-compose.utilities.yml run --rm -e DRY_RUN=true configarr` (drop `DRY_RUN` to apply). If your `configarr/config.yml` came from the example before this release, change `base_url` from `http://gluetun:8989` / `:7878` to `http://sonarr:8989` / `http://radarr:7878`, dry-run, and read what it would change first: it has not reached Sonarr or Radarr since v1.7.23, and it will create the profiles your config names.

### v1.13.4 → v1.13.5

Recreate Seerr so it picks up its new start command:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml up -d seerr
```

That clears the "/app/config volume mount was not configured properly" banner if you had it. Your Seerr settings, users and requests are untouched.

### v1.13.3 → v1.13.4

Nothing to recreate; one Jellyfin setup step, described in [APP-CONFIG.md §4.1 step 4](APP-CONFIG.md#41-jellyfin-media-server): install the TheTVDB plugin, restart, tick *Import season name*, and move TheTVDB above TheMovieDb for Series, Seasons and Episodes in the TV library. Shows already in the library keep their current metadata and artwork; refresh an individual show with *Replace all images* if TMDB had mislabelled it.

### v1.13.2 → v1.13.3

Nothing to recreate. `configure-apps.sh` gained a Seerr step that points its TV and anime metadata at TVDB, so the seasons Seerr offers are the seasons Sonarr fetches. Apply it to a running stack with:

```bash
cd $NAS_STACK_DIR && git pull
./scripts/configure-apps.sh --only seerr
```

It is idempotent and touches nothing else. Anime that Seerr previously showed as one season may now show several (TVDB's numbering, which is what Sonarr uses); existing requests are unaffected.

### v1.13.1 → v1.13.2

Nothing to recreate: this release adds a script, tests and docs. `git pull` and carry on. If you want audiobooks on the Jellyfin TV app, add the Music library and the cron entry described in [MAINTENANCE.md](MAINTENANCE.md#audiobooks-on-the-tv) — both are opt-in; the web's Books library is unchanged.

### v1.13.0 → v1.13.1

One image pin. Pull and recreate uptime-kuma (its data volume is small; back it up first if you like):

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.utilities.yml up -d uptime-kuma
```

### v1.12.2 → v1.13.0

The three core compose files now pin `name: arr-stack`. If your deploy directory is already called `arr-stack` (the documented layout, `$NAS_STACK_DIR=/volume1/docker/arr-stack`) nothing changes — `git pull` and carry on. Volumes are unaffected either way; they have had explicit names since 1.7.

If your directory is called something else, the project name changes on your next `up`, and Compose will refuse to start containers whose names already belong to the old project. Two ways through:

- **Keep your old name (no migration):** add `COMPOSE_PROJECT_NAME=<your-directory-name>` to `.env`. The environment overrides the `name:` key.
- **Adopt `arr-stack`:** the containers have to be recreated under the new project, and that means `down` — the one exception to the core file's own banner. Pi-hole goes down with it, so anything on your network that uses it for DNS loses resolution until `up` completes: pull first while DNS still works, then take the files down in reverse order (the shared `arr-stack` network belongs to the core file and cannot be removed while traefik or the utilities are still attached), then bring them up. Named volumes survive `down`.

  ```bash
  OLD=$(basename "$PWD")
  for f in docker-compose.arr-stack.yml docker-compose.traefik.yml docker-compose.utilities.yml; do docker compose -f "$f" pull; done
  for f in docker-compose.utilities.yml docker-compose.traefik.yml docker-compose.arr-stack.yml; do docker compose -p "$OLD" -f "$f" down; done
  for f in docker-compose.arr-stack.yml docker-compose.traefik.yml docker-compose.utilities.yml; do docker compose -f "$f" up -d; done
  ```

  If a container from another compose project sits on the `arr-stack` network (CLAUDE.md's neighbouring project does), the network cannot be removed and `up` adopts it with a warning about the old project label. That is harmless; the label clears when that container is next recreated.

CI is new (`.github/workflows/ci.yml`); nothing to do for it on the NAS.

### v1.12.1 → v1.12.2

Jellyfin's mount widens from `/data/media` to the whole data root (read-only), so a Books library can index the `other` download lane. Pull and recreate Jellyfin:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml up -d jellyfin
docker logs -f jellyfin 2>&1 | grep -m1 "Startup complete"   # the healthcheck goes green early on 12.0
```

Then, if you want audiobooks grabbed via Prowlarr to appear in Jellyfin: Dashboard → Libraries → add (or edit) a *Books* library with folders `/data/media/audiobooks`, `/data/usenet/complete/other` and `/data/torrents/other` — [APP-CONFIG.md § 4.1](APP-CONFIG.md#41-jellyfin-media-server).

### v1.12.0 → v1.12.1

Two routine image bumps and one folder fix. Pull, recreate the two bumped containers, re-run the script:

```bash
cd $NAS_STACK_DIR && git pull
docker compose -f docker-compose.arr-stack.yml up -d flaresolverr
docker compose -f docker-compose.cloudflared.yml up -d cloudflared   # only if you run the tunnel
./scripts/configure-apps.sh
```

The script corrects SABnzbd's `other` category, which 1.12.0 created with an empty folder: Prowlarr search-page grabs now land in `<complete_dir>/other/` as documented. Anything that already completed sits directly in the completed folder — move it by hand.

### v1.11.0 → v1.12.0

No compose changes. Pull, then re-run the configuration script — it is what changed:

```bash
cd $NAS_STACK_DIR && git pull
./scripts/configure-apps.sh --dry-run   # shows exactly what would change
./scripts/configure-apps.sh
```

What to expect from the Bazarr section: it now manages one subtitle profile — the one named **English**, or an existing profile whose languages are exactly English whatever it's called — points both series/movie defaults at that profile's real id, and leaves any other profiles alone. On a stack configured by earlier versions this is a no-op ("already configured" throughout). If you want a different language set, `SUBTITLE_LANGUAGES="en fr" ./scripts/configure-apps.sh` — the script owns that one profile's contents. Bazarr is no longer restarted after the section; it applies settings inside each write.

New on the command line: `--only <section>` runs one section and touches nothing else, and `BAZARR_CONTAINER=<name> --only bazarr` is a genuinely isolated way to test the section against a throwaway. Prowlarr's search page can now download directly (category `other`, see [APP-CONFIG.md § 4.6](APP-CONFIG.md#46-prowlarr-indexer-manager)); the script creates the category in qBittorrent and SABnzbd and adds both as Prowlarr's own clients.

### v1.10.1 → v1.11.0

Hardening against poisoned public-indexer results, a `--dry-run` that works, and image bumps including **Jellyfin 12.0** — a major version that rewrites its database on first start. Order matters: fix Jellyfin's config *before* the new image boots.

#### 1. Pull

```bash
cd $NAS_STACK_DIR && git pull
```

#### 2. Jellyfin: fix the preset before 12.0 starts

12.0 refuses to parse the `encoding.xml` that 10.11 writes when the encoder preset was never touched — `<EncoderPreset xsi:nil="true" />` is an empty value to its stricter parser. It logs one line, `[ERR] Error loading configuration file: /config/config/encoding.xml`, then **rewrites the file with defaults**: hardware acceleration `none`, VPP tonemapping off, HEVC encoding off, hevc/vp9/vp8/mpeg2 dropped from hardware decoding. Playback keeps working — in software — so nothing alerts you.

Back up the config volume first (a 4 GB volume took ~13 minutes on the NAS), then fix the preset with Jellyfin stopped:

```bash
docker run --rm -v arr-stack_jellyfin-config:/src:ro -v /path/to/backups:/bak alpine \
  tar czf /bak/jellyfin-config-backup-$(date +%Y%m%d-%H%M%S).tgz -C /src .
docker stop jellyfin
docker run --rm -v arr-stack_jellyfin-config:/src alpine \
  sed -i 's|<EncoderPreset xsi:nil="true" />|<EncoderPreset>auto</EncoderPreset>|' /src/config/encoding.xml
```

Already on 12.0 and transcoding has quietly moved to the CPU? Compare `/config/config/encoding.xml` with your backup's copy and put the values back, or re-enter them in Dashboard → Playback → Transcoding.

#### 3. Recreate, and wait for the log — not the healthcheck

```bash
docker compose -f docker-compose.arr-stack.yml up -d
docker logs -f jellyfin 2>&1 | grep -m1 "Startup complete"
```

`/health` answered 200 about ten seconds into a migration that took 3m41s, so `docker ps` reports healthy long before the server is usable. Seerr logs a `503` if its sync lands in that window; it recovers on the next run.

#### 4. Re-run the configuration script

```bash
./scripts/configure-apps.sh --dry-run   # preview — this now reports real deltas
./scripts/configure-apps.sh
```

Two new steps: qBittorrent's executable exclusion list (`*.exe`, `*.scr`, … rejected at the metadata stage, before any bytes transfer), and Bazarr's subtitle languages — the script now manages one profile (named English, or adopted by contents), points both defaults at it and enforces what it contains. Bazarr applies each write immediately; nothing restarts.

#### 5. Optional: indexer hygiene and a standing scan

Using public torrent indexers? Read the note in [APP-CONFIG.md § 4.6](APP-CONFIG.md#46-prowlarr-indexer-manager) on what hit this stack and how to rank them. `scripts/scan-executables.sh` reports any executables already sitting under `/data`; [MAINTENANCE.md](MAINTENANCE.md#executable-scan) has the cron line.

### v1.7.9 → v1.7.10

Docs-only fix. No migration needed — just `git pull`.

The clone block in SETUP.md (Ugreen and Synology sections) referenced `$NAS_STACK_DIR` in `chown` before `.env` existed, causing `chown: missing operand`. Fixed by setting the variable at the top of the block so volume2 users only change one line.

### v1.7.8 → v1.7.9

Fixes Pi-hole startup failure on multi-volume NAS setups (#16) and adds `NAS_STACK_DIR` env var.

#### 1. Pull and redeploy

```bash
cd $NAS_STACK_DIR
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

#### 2. Migrate Pi-hole DNS config

```bash
# Move your DNS config into the new dnsmasq.d directory
mkdir -p pihole/dnsmasq.d
mv pihole/02-local-dns.conf pihole/dnsmasq.d/02-local-dns.conf
```

#### 3. Add NAS_STACK_DIR to .env

```bash
# Add your stack path (adjust volume number if needed)
echo 'NAS_STACK_DIR=/volume1/docker/arr-stack' >> .env
```

#### 4. Clean up orphaned volume

```bash
docker volume rm arr-stack_pihole-etc-dnsmasq 2>/dev/null || true
```

### Container Security Hardening

All containers now run with hardened Linux defaults:
- **`cap_drop: ALL`** — All Linux capabilities dropped, re-added only where needed
- **`no-new-privileges: true`** — Prevents privilege escalation via setuid/setgid binaries

This applies automatically when you pull and redeploy. No action required unless you've customized the compose files to add services or capabilities — in that case, review the [Container Security](ARCHITECTURE.md#container-security) section in the architecture docs.

### v1.7.2 → v1.7.3

Fixes `.lan` DNS resolution inside VPN-tunneled containers, adds a script to fix duplicate Jellyfin entries after enabling TRaSH naming, and improves Seerr configuration.

#### 1. Pull and redeploy

```bash
cd $NAS_STACK_DIR
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

#### 2. Fix .lan DNS for VPN-tunneled services

If you use `.lan` domains (local DNS setup), add the IPv6 wildcard to prevent DNS failures inside Gluetun:

```bash
# Check if already present
grep 'address=/lan/::' pihole/dnsmasq.d/02-local-dns.conf || echo 'address=/lan/::' >> pihole/dnsmasq.d/02-local-dns.conf
docker restart pihole
```

Without this, webhooks and notifications from Sonarr/Radarr to `.lan` hostnames (e.g., `homeassistant.lan`) silently fail. This is the standard dnsmasq approach for IPv4-only local domains — it returns a proper AAAA response (the `::` unspecified address) instead of NXDOMAIN. Alpine/musl-based containers like Gluetun treat AAAA NXDOMAIN as a hard failure, even when the A (IPv4) record resolves fine.

#### 3. Fix duplicate Jellyfin entries (if applicable)

If you enabled TRaSH naming in v1.7 and have duplicate show entries in Jellyfin:

```bash
# Preview what will be renamed (dry run — review output carefully)
./scripts/fix-sonarr-folders.sh

# Apply only after reviewing the dry run
./scripts/fix-sonarr-folders.sh --apply
```

> **Note:** This script is LLM-generated and human-reviewed. Review [fix-sonarr-folders.sh](../scripts/fix-sonarr-folders.sh) before running — you are responsible for verifying it against your setup.

#### 4. Jellyfin library scan + Seerr sync

After the folder rename above, scan Jellyfin and sync Seerr so everything is consistent:

1. **Jellyfin:** Dashboard → Libraries → Scan All Libraries
2. **Seerr:** Settings → Jellyfin → toggle **Movies** and **TV** on → Save → click **Sync Libraries** then **Start Scan**
3. **Seerr quality profiles:** Settings → Services → edit Radarr server → Quality Profile: `UHD Bluray + WEB`. Edit Sonarr server → Quality Profile: `Ultra-HD`

#### 5. Whitelist local networks in qBittorrent

Prevents API scripts and Sonarr/Radarr from getting IP-banned after container restarts:

Tools → Options → Web UI → Authentication:
- **Bypass authentication for clients on localhost:** ✅
- **Bypass authentication for clients in whitelisted IP subnets:** ✅
- **Whitelisted subnets:** `172.20.0.0/24, 192.168.1.0/24, 127.0.0.0/8` (adjust `192.168.1.0/24` to match your LAN subnet)

---

### v1.7.1 → v1.7.2

Container rename: `jellyseerr` → `seerr` (completes the Seerr rebrand from v1.6.4). App configuration docs restructured into three files — existing `APP-CONFIG.md` anchor links still work.

#### 1. Pull and redeploy

```bash
cd $NAS_STACK_DIR
git pull origin main
```

#### 2. Migrate the Docker volume

```bash
# Stop the old container
docker stop jellyseerr && docker rm jellyseerr

# Create new volume and copy data
docker volume create arr-stack_seerr-config
docker run --rm \
  -v arr-stack_jellyseerr-config:/source:ro \
  -v arr-stack_seerr-config:/dest \
  alpine sh -c "cp -a /source/. /dest/"

# Start with new name
docker compose -f docker-compose.arr-stack.yml up -d seerr

# Verify Seerr works, then remove old volume
docker volume rm arr-stack_jellyseerr-config
```

#### 3. Update Uptime Kuma monitor (if using)

If you have an Uptime Kuma monitor for Seerr, update the URL from `http://jellyseerr:5055/api/v1/status` to `http://seerr:5055/api/v1/status`.

---

### v1.7 → v1.7.1

Infrastructure cleanup and backup consolidation.

#### 1. Pull and redeploy

```bash
cd $NAS_STACK_DIR
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
docker compose -f docker-compose.traefik.yml up -d --force-recreate
docker compose -f docker-compose.utilities.yml up -d --force-recreate
```

> **Note:** Start arr-stack first — it now owns the `arr-stack` network. Traefik and utilities reference it as `external: true`.

#### 2. Update backup crontab (if using automated backups)

The backup script was renamed from `backup-volumes.sh` to `arr-backup.sh`:

```bash
sudo crontab -l | sed 's/backup-volumes.sh/arr-backup.sh/' | sudo crontab -
```

Verify: `sudo crontab -l` should show `arr-backup.sh`.

---

### v1.6.5 → v1.7

This release adds TRaSH Guides best practices: hardlinks, naming schemes, download directory structure, and download client hardening.

**Breaking change:** Volume mounts changed for 6 services. Docker Compose will handle this automatically on redeploy, but you must reconfigure paths inside the apps.

#### 1. Create new directories and move library files

```bash
ssh your-username@nas-ip
sudo mkdir -p /volume1/data/media
sudo mv /volume1/data/movies /volume1/data/media/movies
sudo mv /volume1/data/tv /volume1/data/media/tv
sudo mkdir -p /volume1/data/torrents/{tv,movies}
sudo mkdir -p /volume1/data/usenet/{incomplete,complete/{tv,movies}}
sudo chown -R 1000:1000 /volume1/data/media /volume1/data/torrents /volume1/data/usenet
```

#### 2. Pull and redeploy

```bash
cd $NAS_STACK_DIR
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

Wait ~30 seconds for services to stabilize.

#### 3. Reconfigure Radarr root folder

1. Settings → Media Management → Add Root Folder → `/data/media/movies`
2. Movies → Select All → Edit → Root Folder → `/data/media/movies/` → Save
3. Settings → Media Management → delete old root folder `/movies`
4. **Fix collections:** If you see "Missing root folder for movie collection" on the Health page, go to Movies → Collections → Select All → Edit → Root Folder → `/data/media/movies/` → Save

#### 4. Reconfigure Sonarr root folder

1. Settings → Media Management → Add Root Folder → `/data/media/tv`
2. Series → Select All → Edit → Root Folder → `/data/media/tv/` → Save
3. Settings → Media Management → delete old root folder `/tv`

#### 5. Reconfigure qBittorrent categories

1. Tools → Options → Downloads → Default Torrent Management Mode: **Automatic**
2. Right-click category `sonarr` → Edit → rename to `tv`, save path `/data/torrents/tv`
3. Right-click category `radarr` → Edit → rename to `movies`, save path `/data/torrents/movies`

> **Active torrents:** If you have active torrents, reassign them to the new category names before deleting old categories.

#### 6. Update download client categories in Sonarr/Radarr

- **Sonarr:** Settings → Download Clients → qBittorrent → Category: `tv` (was `sonarr`)
- **Radarr:** Settings → Download Clients → qBittorrent → Category: `movies` (was `radarr`)

#### 7. Reconfigure SABnzbd paths

Config (⚙️) → Folders:
- Temporary Download Folder: `/data/usenet/incomplete`
- Completed Download Folder: `/data/usenet/complete`

Restart SABnzbd after saving.

#### 8. Reconfigure Jellyfin library paths

Dashboard → Libraries:
- Edit Movies library → add `/data/media/movies`, remove `/media/movies`
- Edit TV Shows library → add `/data/media/tv`, remove `/media/tv`

This triggers a library rescan. NFO files ensure accurate identification.

#### 9. Update Seerr root folders

Seerr stores its own copy of the root folder paths. If not updated, new requests will fail with "Root folder does not exist":

1. Open Seerr → Settings → Services
2. Click Radarr server → change Root Folder from `/movies` to `/data/media/movies` → Save
3. Click Sonarr server → change Root Folder from `/tv` to `/data/media/tv` → Save

> **If requests already failed:** Go to Requests, find any with "Failed" status, and click the retry button. They'll re-submit with the corrected path.

#### 10. Configure TRaSH naming schemes (recommended)

Follow the naming configuration steps in the [App Configuration Guide](APP-CONFIG.md):
- [Sonarr naming](APP-CONFIG.md#44-sonarr-tv-shows) (step 5)
- [Radarr naming](APP-CONFIG.md#45-radarr-movies) (step 5)

After configuring naming, rename existing files and folders:

1. **Rename series folders** (Sonarr only — the TRaSH series folder format adds `[tvdbid-XXXXX]` which existing folders won't have):
   ```bash
   ./scripts/fix-sonarr-folders.sh
   ```
   This uses Sonarr's API to rename every series folder to match the configured format. Dry run by default — review the output before passing `--apply`. LLM-generated and human-reviewed; check the script before running.

2. **Rename episode/movie files:**
   - Radarr: Movies → Select All → Organize
   - Sonarr: Series → Select All → Organize

> **Warning: Do not rename series folders manually** (e.g., with `mv` on the NAS). Sonarr's database won't know about the change, causing it to lose track of your files. Always use the script above or Sonarr's UI — both keep the database in sync.

> **Radarr path mismatches:** The TRaSH naming scheme may rename movie directories (e.g., `Avatar The Way of Water` → `Avatar - The Way of Water`). In rare cases, Radarr's database may not update to match, causing movies to show as "missing" on the Health page.
>
> **Check:** Go to Radarr → System → Health. If you see "missing root folder" or many movies suddenly show as unmonitored/missing, run the path fixer:
> ```bash
> ./scripts/fix-radarr-paths.sh
> ```
> This compares Radarr's database paths against actual directories on disk and fixes any mismatches. LLM-generated and human-reviewed; check the script before running.

#### 11. Enable NFO metadata (recommended)

**In Radarr** (`http://NAS_IP:7878`):

1. Settings → Metadata → Kodi (XBMC) / Emby → **Enable**
2. Movie Metadata: ✅, Movie Images: ❌
3. Save, then refresh the full library: Movies → Update All

**In Sonarr** (`http://NAS_IP:8989`):

1. Settings → Metadata → Kodi (XBMC) / Emby → **Enable**
2. Series Metadata: ✅, Episode Metadata: ✅, all image options: ❌
3. Save, then refresh the full library: Series → Update All

The library refresh writes `.nfo` files for all existing media. New downloads get them automatically.

#### 12. Clean up old `downloads/` directory

The old `/volume1/data/downloads/` directory is still accessible inside containers at `/data/downloads/`. Once all in-progress downloads are imported, verify nothing references it then delete:

```bash
# Check no qBittorrent torrents use the old path
# (all should show /data/torrents/ paths after migration)
# Then delete:
rm -rf /volume1/data/downloads/
```

---

### v1.4 → v1.5

**Breaking change:** Removed all env var fallbacks from compose files.

Previously, compose files had fallbacks like `${MEDIA_ROOT:-/volume1/data}`. Now they use `${MEDIA_ROOT}` — if a variable is missing from `.env`, Docker will fail with a clear error instead of silently using a default.

**Action required:** Ensure your `.env` has all required variables. If you copied from `.env.example` when you first set up, you're fine. If not:

```bash
# Check for missing variables
diff <(grep -oP '^\$\{[A-Z_]+\}' docker-compose.arr-stack.yml | sort -u) <(grep -oP '^[A-Z_]+=' .env | cut -d= -f1 | sort -u)
```

Or just copy the latest `.env.example` and fill in your values.

**Also in v1.5** (non-breaking):

| Change | Details |
|--------|---------|
| SSL simplified | Removed Let's Encrypt DNS challenge. Cloudflare Tunnel handles HTTPS at the edge. |
| `traefik.yml.example` | Now HTTP-only (simpler). Old config still works. |
| `CF_DNS_API_TOKEN` | Removed from `.env.example` (was unused) |
| `acme.json` | No longer needed. Can delete if you have one. |
| `.env.example` reorganized | Now ordered by setup level: Core → + local DNS → + remote access |

**Optional cleanup:**

```bash
# Remove unused certificate file (if it exists)
rm -f traefik/acme.json
```

---

### v1.3 → v1.4

**Network renamed:** `traefik-proxy` → `arr-stack`

The old name was confusing - implied Traefik was required for Core setup. The network is used by all services.

```bash
cd $NAS_STACK_DIR && \
git pull origin main && \
docker compose -f docker-compose.arr-stack.yml down && \
docker compose -f docker-compose.utilities.yml down 2>/dev/null; \
docker compose -f docker-compose.cloudflared.yml down 2>/dev/null; \
docker compose -f docker-compose.traefik.yml down 2>/dev/null; \
docker network rm traefik-proxy && \
docker network create --driver=bridge --subnet=172.20.0.0/24 --gateway=172.20.0.1 arr-stack && \
docker compose -f docker-compose.arr-stack.yml up -d && \
docker compose -f docker-compose.traefik.yml up -d 2>/dev/null; \
docker compose -f docker-compose.cloudflared.yml up -d 2>/dev/null; \
docker compose -f docker-compose.utilities.yml up -d 2>/dev/null; \
echo "Migration complete"
```

> **Other containers on the old network?** Update their compose files to use `arr-stack` instead of `traefik-proxy`.

---

### v1.2.x → v1.3

**Breaking change:** Docker network subnet changed from `192.168.100.0/24` to `172.20.0.0/24`.

Run the full migration as a single chained command to minimize DNS downtime:

```bash
cd $NAS_STACK_DIR && \
git pull origin main && \
docker compose -f docker-compose.arr-stack.yml down && \
docker compose -f docker-compose.utilities.yml down 2>/dev/null; \
docker compose -f docker-compose.cloudflared.yml down 2>/dev/null; \
docker compose -f docker-compose.traefik.yml down && \
docker network rm arr-stack && \
docker network create --driver=bridge --subnet=172.20.0.0/24 --gateway=172.20.0.1 arr-stack && \
docker compose -f docker-compose.traefik.yml up -d && \
docker compose -f docker-compose.arr-stack.yml up -d && \
docker compose -f docker-compose.cloudflared.yml up -d 2>/dev/null; \
docker compose -f docker-compose.utilities.yml up -d 2>/dev/null; \
echo "Migration complete"
```

> **Other containers on arr-stack?** If you have containers from other compose files using this network (e.g., Frigate), stop them first, then update their compose files to use `172.20.0.x` IPs before restarting.

> **Why the change?** The new `172.20.0.0/24` subnet is a Docker-conventional range, less likely to conflict with home LANs (which often use `192.168.x.x`).

**New features:**

| Feature | What it does |
|---------|--------------|
| Jellyfin discovery ports | Apps auto-detect Jellyfin on LAN (7359/udp, 1900/udp) |
| "Adding More Services" docs | Example for adding Lidarr, Readarr, etc. |

**Documentation improvements:**

- README simplified (services table moved to SETUP.md)
- SETUP.md restructured with Stack Overview section
- Section headings now action-oriented
- Consistent `flaresolverr.lan` usage throughout
- TROUBLESHOOTING.md simplified (common issues consolidated into SETUP.md)

---

### v1.1 → v1.2.x

**Breaking changes:** None

**Automatic improvements** (just redeploy to get these):
- Startup order fixes — Gluetun now waits for Pi-hole to be healthy before connecting
- Improved healthchecks — FlareSolverr actually tests Chrome, catches crashes
- Backup script improvements — smart space checking, 7-day rotation
- SABnzbd added — Usenet downloads via VPN (remove from compose if not wanted); configure in [App Configuration Guide](APP-CONFIG.md#43-sabnzbd-usenet-downloads)

**New features (optional, requires setup):**

| Feature | What it does | Setup |
|---------|--------------|-------|
| `.lan` domains | `http://sonarr.lan` etc, no ports | Router DHCP reservation + Pi-hole DNS, see [Local DNS Guide](LOCAL-DNS.md) |
| `MEDIA_ROOT` env var | Configurable media path | Set in `.env` |
| deunhealth | Auto-restart crashed services | Deploy `docker-compose.utilities.yml` |

**New .env variables:**

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `MEDIA_ROOT` | Yes | — | Base path for media storage |
| `TRAEFIK_LAN_IP` | Only for .lan | — | Traefik's dedicated LAN IP for local DNS |
| `LAN_INTERFACE` | Only for .lan | — | Network interface (e.g., `eth0`) |
| `LAN_SUBNET` | Only for .lan | — | Your LAN subnet (e.g., `192.168.1.0/24`) |
| `LAN_GATEWAY` | Only for .lan | — | Router IP |
| `TRAEFIK_LAN_MAC` | Only for .lan | — | Fixed MAC for DHCP reservation |

See [.env.example](../.env.example) for all available variables.
