# Backup & Restore

This stack uses Docker named volumes for service data. This guide covers backing up and restoring your configuration.

## Prerequisites

**USB Drive for Automated Backups (Recommended)**

For the automated daily backup to work, plug a USB drive into your NAS:

1. **Format** the USB drive (ext4 recommended, FAT32 works but has file size limits)
2. **Mount** it at `/mnt/arr-backup` (or update the cron job path)
3. The script will automatically keep 7 days of backups and rotate old ones

> Without a USB drive, backups go to `/tmp` which is cleared on reboot. You'd need to manually pull backups off-NAS.

---

## What Gets Backed Up

The backup script (`scripts/arr-backup.sh`) backs up **state a service cannot rebuild by itself**. Volumes marked *(cache excluded)* are backed up with their regenerable subdirectories skipped — see the exclusion list in the script.

| Volume | Kept | Contents |
|--------|------|----------|
| gluetun-config | ~7MB | VPN provider settings |
| qbittorrent-config | ~15MB | Client settings, categories |
| sabnzbd-config | ~2MB | Usenet provider credentials and settings |
| prowlarr-config | ~14MB | Indexer configs, API keys |
| bazarr-config | ~6MB | Subtitle provider credentials |
| uptime-kuma-data | ~14MB | Monitor configurations |
| seerr-config | ~123MB | User accounts, requests |
| sonarr-config *(cache excluded)* | ~13MB of 1015MB | Series DB, quality profiles, custom formats, API key |
| radarr-config *(cache excluded)* | ~7MB of 190MB | Movie DB, quality profiles, custom formats, API key |
| jellyfin-config *(cache excluded)* | ~9MB of 506MB | Users, watch history, plugin config |
| pihole-etc-pihole *(cache excluded)* | ~5MB of 50MB | `pihole.toml`, gravity DB, custom allow/deny lists |
| decypharr-config *(cache excluded)* | ~3MB | `auth.json`/`config.json` — debrid credentials |
| beszel-data | ~400KB | `data.db` plus `id_ed25519`, the monitoring agent's own private key |
| dnscrypt-config | ~500KB | Hand-edited `dnscrypt-proxy.toml` — resolver and forwarding rules |

Sizes measured on the live NAS 2026-08-30/31. The last three were assessed and added on
2026-08-31 — none is regenerable, and together they're under 4MB.

**The four *(cache excluded)* volumes were previously skipped entirely** on the grounds that they were large and "re-scan to rebuild". That was only ever true of the caches inside them. A re-scan does not rebuild quality profiles, custom formats, release profiles, indexer assignments, Jellyfin users, or watch history. Excluding just the caches buys full protection for those services for roughly 35MB — `sonarr-config`'s 862MB `logs.db` was the bulk of what made the volume look too expensive to back up.

## What's NOT Backed Up

Volumes holding nothing a service cannot rebuild unaided:

| Volume | Size | Why Excluded |
|--------|------|--------------|
| jellyfin-cache | ~12MB | Transcoding cache, fully regenerates |
| duc-index | ~20MB | Disk usage index, regenerates on restart |
| configarr-repos | ~10MB | Git clones of upstream config repos, re-cloned on run |
| magnetio-redis-data | 8KB | Ephemeral cache |

Plus the cache subdirectories inside the four *(cache excluded)* volumes above: `logs.db`, `logs`, `MediaCover`, `Sentry` (*arr), `metadata`/`cache`/`log`/`transcodes` (Jellyfin), `pihole-FTL.db`/`gravity_old.db`/`listsCache` (Pi-hole).

**Homepage** (`homepage/config/`) isn't a Docker volume at all — it's a
bind-mounted, git-tracked directory, so its config is already backed up by
version control. Nothing to add here; restoring it is just `git pull`.

---

## Running a Backup

### On the NAS

```bash
# SSH into your NAS first, then:
cd $NAS_STACK_DIR
./scripts/arr-backup.sh --tar
```

Output:
```
=== Arr-Stack Backup ===
Volume prefix: arr-stack_*
Backup dir:    /tmp/arr-stack-backup-20241217

Backing up gluetun-config... OK (7.1M)
Backing up qbittorrent-config... OK (8.9M)
...
Summary: 8 backed up, 0 skipped, 0 failed
Total size: 58M

Created: /tmp/arr-stack-backup-20241217.tar.gz (13M)
```

### Copying Off-NAS

**Ugreen NAS** (scp doesn't work with /tmp):
```bash
ssh user@nas "cat /tmp/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
```

**Other systems** (Synology, QNAP, Linux):
```bash
scp user@nas:/tmp/arr-stack-backup-*.tar.gz ./backup.tar.gz
```

> **Important:** Backups in `/tmp` are cleared on reboot. Copy off-NAS promptly!

---

## Restore

### Full Restore (New Installation)

1. Deploy the stack normally (see [Setup Guide](SETUP.md))
2. SSH into your NAS and stop the services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml down
   ```
3. Extract backup and restore each volume:
   ```bash
   tar -xzf backup.tar.gz
   cd arr-stack-backup-20241217

   for dir in */; do
     vol="arr-stack_${dir%/}"
     echo "Restoring $vol..."
     docker run --rm \
       -v "$(pwd)/$dir":/source:ro \
       -v "$vol":/dest \
       alpine cp -a /source/. /dest/
   done
   ```
4. Start services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml up -d
   ```

### Single Volume Restore

```bash
# On NAS via SSH - example: restore seerr config
docker compose -f docker-compose.arr-stack.yml stop seerr

docker run --rm \
  -v ./backup/seerr-config:/source:ro \
  -v arr-stack_seerr-config:/dest \
  alpine cp -a /source/. /dest/

docker compose -f docker-compose.arr-stack.yml start seerr
```

---

## Script Options

```bash
./scripts/arr-backup.sh [OPTIONS] [BACKUP_DIR]

Options:
  --tar           Create .tar.gz archive (recommended)
  --prefix NAME   Pin every volume to prefix NAME instead of resolving each one

Examples:
  ./scripts/arr-backup.sh --tar                    # Default location
  ./scripts/arr-backup.sh --tar /path/to/backup    # Custom location
  ./scripts/arr-backup.sh --prefix media-stack     # Pin all volumes to one prefix
```

### Environment knobs

| Variable | Default | Effect |
| --- | --- | --- |
| `SAFETY_TIMEOUT` | `120` | Seconds allowed for the exit-trap restart of any service the backup stopped. |
| `HA_WEBHOOK_URL` | unset | Where `notify_failure` posts. Unset on this NAS, so it degrades to `echo` — see *Exit status* below. |

`SAFETY_TIMEOUT` is an **operator knob, not a test hook.** 120s is chosen against a
measured full-stack `compose up -d` on this NAS settling in ~50s. Raise it if the
stack grows; do not lower it to make a test faster.

It bounds `ensure_services_running`, which runs from the **EXIT trap** to restart
anything the backup stopped. On timeout or failure it says so distinctly and raises
`notify_failure` — **so if you see `SAFETY: TIMED OUT` or `SAFETY: FAILED`, services
are still down and need restarting by hand.**

It still **returns 0 on failure, deliberately.** `cleanup_on_exit` invokes it under
`set -e`, where a non-zero return becomes the script's own exit status — that once
made a successful backup exit 42, and would make a `backup && prune` cron chain stop
pruning permanently. The gap was never the status; it was the missing signal.

### Staging directory

The archive is assembled in `/tmp/arr-stack-backup-<timestamp>` (tmpfs — roughly
220 MB per run) and moved to the destination at the end. **`/tmp` therefore needs room
for a full copy of the archive**, on top of the destination.

If `mkdir` on that directory fails, the script distinguishes **"it already exists —
another backup may be running"** from any other cause (permissions, missing parent,
full filesystem), printing `mkdir`'s own stderr for the latter. If you see the
collision message, check for a concurrent run before deleting anything.

Staging and destination are separate variables (`STAGING_DIR`, `FINAL_DEST`) and must
stay separate — the EXIT trap runs `rm -rf` on the staging path. History in
`docs/TEST-HARDENING-LOG.md` §5.3.

### Volume Resolution

Docker names a volume `<compose-project>_<name>`, and this stack spans **four**
compose projects — `arr-stack`, `arr-utilities`, `tailscale` and `magnetio` — so
there is no single prefix. Each name in the script's curated list is resolved
independently by matching `*_<name>` against `docker volume ls`.

Where a name exists under two prefixes (a live volume plus one orphaned by a past
project rename, e.g. `arr-stack_beszel-data` and `arr-utilities_beszel-data`), the
tie is broken in two tiers:

1. **Which one a container *references*** — running **or stopped** (`docker ps -a`).
   A volume orphaned by a project rename is referenced by nothing in any state;
   that is what makes it an orphan, and it is the distinction this tier draws.
2. **Which one a running container mounts** — used only if tier 1 still leaves
   more than one candidate.

A tie that neither tier breaks is a hard error rather than a guess — restoring from
an orphaned volume is worse than a failed backup, because it looks like it worked.

> **Tier 1 asks "referenced", not "running", on purpose.** Until 2026-08-31 the only
> tie-break was the running-container one, which made the backup's *answer* depend on
> which containers happened to be up at 04:00. With beszel stopped, `beszel-data` had
> two candidates and no signal to separate them, so the nightly run failed that volume
> — a backup whose correctness depends on uptime is the opposite of what a backup is
> for. Measured on the NAS: `arr-stack_beszel-data` is referenced by 1 container,
> `arr-utilities_beszel-data` by 0, running or stopped.

Both tie-break inventories are built through a guarded helper that separates
**"nothing is attached"** from **"I could not ask"**. If `docker ps` fails, or
`docker inspect` fails for every container, the run stops with docker's own error
rather than continuing with an empty set.

> **Why an empty inventory cannot be allowed to mean "no containers".** An empty
> `ATTACHED_VOLUMES` is read by the resolver as proof that every candidate is an
> orphan. A docker failure that returns empty therefore does not produce a vague
> error — it produces a *confident and specific* one, failing every multi-candidate
> volume with `no container references any of them, running or stopped` and sending
> whoever reads it looking for a project rename that never happened. Measured on
> this NAS by stubbing `docker ps` to fail: exactly one curated name, `beszel-data`,
> is multi-candidate, and it failed with precisely that wrong cause while the other
> 16 volumes backed up normally — `16 backed up, 1 failed`, which reads as a
> selective, plausible, already-known problem rather than a broken daemon.
> (`configarr-repos` also exists under two prefixes but is not in the curated list,
> so it is never resolved and cannot produce this.) Single-candidate names resolve
> on the early return and are unaffected, which is what makes the shape so
> convincing.
>
> That is the *mild* case. The stub above left `docker run` working, which is not a
> combination that occurs in practice: whatever denies the containers endpoint denies
> container creation too, and the copy itself is a `docker run`. Stubbing both — the
> realistic shape — gave `0 backed up, 1 skipped, 17 failed` **and still wrote a
> 214-byte tarball into the destination**. `backup-prune.sh` tiers purely by the
> filename's timestamp and never inspects size or contents, so that empty archive is
> an ordinary retention candidate: inside the 7-30 day tier it is eligible to be the
> "newest backup per calendar day" that displaces a real one. The non-zero exit is
> the only thing distinguishing it, and only if something is reading exit codes.
>
> A container disappearing between `docker ps` and `docker inspect` is a race, not
> a broken daemon: `inspect` exits non-zero having still reported every other
> container, and that partial result is used. Only a total failure — nothing back
> at all — stops the run.
>
> Note the asymmetry this closes. `docker volume ls` has been guarded since the
> coverage fix; the container queries were not. `docker-socket-proxy` in this stack
> runs `VOLUMES=0, CONTAINERS=1`, so it fails the *guarded* call — the reverse
> shape, and the one that was already safe.

A name in the curated list that resolves to nothing is a **failure**, not a skip.
Until 2026-08-31 it was a skip: the script auto-detected one prefix (always
`arr-stack`), so after uptime-kuma moved into the `arr-utilities` project its
volume was never found and every nightly run reported
`11 backed up, 1 skipped, 0 failed` while leaving it unprotected.

`--prefix` restores the old exact-match behaviour for every volume. It is an
escape hatch for a single-project deployment, not the normal path.

### Exit status — and what that means for callers

**The script exits non-zero if any volume failed.** Before 2026-08-31 it always
exited `0`: the loop counted the failure, printed a warning, and then ended on an
`echo`, so `$?` was `0`. Machines read the exit status, and every one of them —
a cron `&&` chain, a CI step, a wrapper — saw a clean run over an unprotected
volume. That is the same lie the single-prefix bug told, moved one layer out.

The archive is **still written** first. The non-zero exit comes after the tarball
is built and moved, so everything that *did* resolve is safely archived and the
status reports what was missed. Withholding the backup because one volume failed
would trade a reporting bug for a data-loss one.

> **Check your cron line when adopting this.** A chained command of the form
> `arr-backup.sh … && backup-prune.sh …` will now **stop pruning** on a partial
> failure, and the destination will grow unbounded. Separate the two commands
> (`;`) so retention still runs, and let the non-zero status surface through the
> log rather than through the chain.

Since `HA_WEBHOOK_URL` is unset on this NAS, `notify_failure` degrades to a plain
`echo` — so the exit status and the cron log are the only failure signals that
actually reach anyone. Redirect cron output to a file (`>> /var/log/arr-backup.log
2>&1`); without it a failure is written to nobody.

### Restoring: read the manifest, don't assume a prefix

Each archive contains `volume-manifest.tsv` mapping every directory to the volume
it was read from. The destination volume name is not derivable from the directory
name — `uptime-kuma-data` restores to `arr-utilities_uptime-kuma-data`, not
`arr-stack_uptime-kuma-data`.

### Request Manager Detection

The script auto-detects which request manager volume exists and backs it up:
- `seerr-config` (Seerr)
- `overseerr-config` (Overseerr, if used instead)

---

## Automated Daily Backup

> **A nightly job to `/volume1/docker/arr-stack-backups` DOES exist as of
> 2026-08-31** — installed in root's crontab at 04:00, and confirmed by its first
> unattended run (`arr-stack-backup-20260831-040002.tar.gz`, 17 volumes in the
> manifest). It is **not** the USB job described below.
>
> **The USB job below is still NOT configured.** There is no `/mnt/arr-backup`, no
> `/var/log/arr-backup.log`, and no `arr-stack-backup-*` file on any of the five
> mounted USB devices (`/mnt/@usb/sd{a,b,c,f,g}1`). Treat the block below as the
> procedure for setting one up, not a description of current state.
>
> **The 04:00 job's cron line needs two edits.** Read in place 2026-08-31 (via a
> read-only mount of `/var/spool/cron`, since `sudo -n` needs a password), it is:
>
> ```
> 0 4 * * * PATH=/usr/bin:/bin; cd /volume1/docker/arr-stack && ./scripts/arr-backup.sh --tar /volume1/docker/arr-stack-backups && ./scripts/backup-prune.sh /volume1/docker/arr-stack-backups
> ```
>
> 1. **`&&` between the two scripts** — see *Exit status* above. `arr-backup.sh`
>    writes its tarball *before* the `FAILED > 0` exit (measured: a run with
>    `0 backed up, 17 failed` still produced a 214-byte archive), so a partial
>    failure adds a file to the GFS directory **and** skips the pruner. Repeated
>    partial nights accumulate with nothing thinning them. Use `;`.
> 2. **No output redirection** — see *Nightly run has no failure signal* below.
>
> The replacement line, keeping `cd … &&` so a failed `cd` still stops:
>
> ```
> 0 4 * * * PATH=/usr/bin:/bin; cd /volume1/docker/arr-stack && { ./scripts/arr-backup.sh --tar /volume1/docker/arr-stack-backups; ./scripts/backup-prune.sh /volume1/docker/arr-stack-backups; } >> /var/log/arr-backup.log 2>&1
> ```
>
> Back the crontab up first — it holds two `@reboot` lines (the tailnet SSH
> iptables rule and the `macvlan-shim` setup) that exist **nowhere in this repo**.
> Losing the shim takes every `.lan` hostname down on the next reboot.

### Nightly run has no failure signal

**Measured 2026-08-31, and it is the reason the two edits above matter.** Every
failure signal this script emits is discarded on the 04:00 run:

| Path | State |
|---|---|
| Redirection in the cron line | none |
| `MAILTO` in root's crontab | not set |
| MTA on PATH (`sendmail`/`mail`/`ssmtp`/`postfix`/`exim`) | none installed |
| `/var/mail` | empty — no root spool file |
| `notify_failure()` | no-ops unless `HA_WEBHOOK_URL` is set |
| Does `arr-backup.sh` source `.env`? | never — no `source`/`.` in the file |
| `HA_WEBHOOK_URL` in the live `.env` | not present |
| Any log file | none anywhere on the NAS |

So the exit status is discarded by cron, `notify_failure` degrades to an `echo`
into a void, and docker's own error — which `docker_volume_inventory()`
deliberately does not silence — lands nowhere.

This does **not** apply to the deploy path: `.github/workflows/nas-auto-deploy.yml`
runs both scripts under `set -e` twice over with output in the job log, so a failed
backup aborts the deploy before `main` is touched. The exit-status work is
load-bearing there. It is specifically the unattended nightly run that is blind,
and `>> /var/log/arr-backup.log 2>&1` is what closes it.

**On the log's growth, since nothing rotates it.** There is no `logrotate` binary on
this NAS (`/etc/logrotate.d` exists but is unused), so the file grows without bound
once the redirection is added. Measured: a successful run prints **2053 bytes over
41 lines**, so ~0.75 MB/year, against 14 GB free on the 16 GB overlay root that
holds `/var`. That is small enough to leave alone; it is recorded so the decision is
a decision rather than an oversight. A failing run prints more, but a NAS failing
every night has a louder problem than its log size.

Note the division of responsibility, because either half alone leaves failures
silent: the **script** must not swallow stderr, and the **caller** must capture it.
`arr-backup.sh` cannot verify the second half — nothing in a process can tell
whether its stderr reaches a human — which is why that fact lives in this file,
dated, instead of being asserted in a source comment that would quietly go stale
the day the cron line is fixed.

To run a daily backup to USB at 6am:

```bash
# View current cron
sudo crontab -l

# Add:
0 6 * * * $NAS_STACK_DIR/scripts/arr-backup.sh --tar --rotate-days 7 /mnt/arr-backup >> /var/log/arr-backup.log 2>&1
```

Mount the USB drive at `/mnt/arr-backup` first, or use `--usb <dir-name>` so the
script finds the device by content rather than by a letter that changes on reboot.

> **`--rotate-days 7` is required as of 2026-08-30.** Rotation used to happen implicitly whenever a destination was given. It is now opt-in, so a cron line without this flag will fill the USB. Conversely, **never pass `--rotate-days` at a directory managed by `backup-prune.sh`** — see the warning under *Automated Pre-Deploy Backup*.

**Features:**
- ✓ Backs up to `/tmp` first (reliable), then moves to USB
- ✓ Checks actual tarball size vs destination space before moving
- ✓ Falls back to `/tmp` if USB lacks space (with warning)
- ✓ With `--rotate-days N`, deletes backups older than N days and prints each one
- ✓ EXIT trap ensures critical services stay running no matter what
- ✓ Does NOT stop services during backup

**To modify the schedule:**
```bash
sudo crontab -e
# Change "0 6" to preferred hour (e.g., "0 4" for 4am)
```

---

## Automated Pre-Deploy Backup (GitHub Actions)

`.github/workflows/nas-auto-deploy.yml` (see that file's header comment for the full pipeline, and CLAUDE.md's *Deploying to the NAS* section for how this relates to the manual branch-first workflow) backs up before every deploy it runs, to a separate location from the daily cron backup above: `/volume1/docker/arr-stack-backups/` on the NAS itself, not the USB drive. It reuses `scripts/arr-backup.sh --tar` unchanged (same volume list as above) and runs `scripts/backup-prune.sh` on that directory. `arr-backup.sh` stamps tarballs `arr-stack-backup-YYYYMMDD-HHMMSS.tar.gz` itself, so the workflow no longer renames them; before 2026-08-30 it stamped by day only and the workflow had to rename each tarball to stop same-day runs clobbering each other.

> **Never pass `--rotate-days` at this directory.** Its retention belongs to `backup-prune.sh` alone. On 2026-08-30 a manual `arr-backup.sh --tar /volume1/docker/arr-stack-backups` destroyed the entire backup history: the script then applied a silent, non-optional `find -mtime +7 -delete` to any destination it was given, and every existing tarball was 14 days old. Nothing was printed and stderr was suppressed. That rotation is now opt-in, and this is why.

**Retention is GFS (Grandfather-Father-Son) tiered, not flat 7-day**, since this runs on every deploy rather than once a day and a flat "keep everything for 7 days" policy would grow unbounded over months of frequent deploys:

| Age | Kept |
|-----|------|
| ≤ 7 days | every backup |
| 7–30 days | newest per calendar day |
| 30–180 days | newest per ISO week |
| > 180 days | newest per month, capped at 12 total |

This mirrors the retention scheme restic/BorgBackup/Time Machine use. Run `./scripts/backup-prune.sh <dir>` manually against any directory of `arr-stack-backup-*.tar.gz` files to apply the same thinning elsewhere.

**Required GitHub repo secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `TS_AUTHKEY_CI` | A reusable Tailscale auth key ([admin console](https://login.tailscale.com/admin/settings/keys)) so the GitHub runner can join the tailnet and reach the NAS |
| `NAS_SSH_HOST` | The NAS's Tailscale MagicDNS name (`arr-stack-nas`, per `docker-compose.tailscale.yml`'s `TS_HOSTNAME`) |
| `NAS_SSH_USER` | SSH user on the NAS |
| `NAS_SSH_KEY` | Private half of a **dedicated CI deploy keypair** — generate a fresh one (`ssh-keygen -t ed25519 -f ci_deploy_key -N ""`), add the public half to that user's `~/.ssh/authorized_keys` on the NAS, don't reuse a personal key |

Also requires Settings → Actions → General → Workflow permissions → **Read and write permissions**, so the default `GITHUB_TOKEN` can push to `main` / merge PRs.

The e2e step runs `npm run test:e2e` **on the NAS itself** over SSH (not from the GitHub runner) so the tests gated on local Docker access (VPN egress/leak/killswitch, zombie-container checks — see `tests/e2e/helpers.ts`'s `DOCKER_AVAILABLE`) actually run instead of skipping. This assumes Playwright's browsers are already installed on the NAS (`npx playwright install --with-deps chromium`, one-time) and `.env.e2e` is already populated there, same as for a manual `npm run test:e2e` run.

---

## Troubleshooting

### "Permission denied" errors
The backup script runs docker containers which handle permissions internally. If you see permission errors, ensure:
- You're in the docker group: `groups` should show `docker`
- Docker daemon is running: `docker ps`

### "Volume not found"
- Ensure services have been started at least once (volumes are created on first run)
- Check the volume prefix matches: `docker volume ls | grep config`

### Backup too large
If backup exceeds ~60MB, check if optional volumes were accidentally included. The script only backs up essential configs by default.
