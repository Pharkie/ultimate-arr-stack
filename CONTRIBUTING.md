# Contributing

For contributors, forks, and anyone wanting to understand the project internals.

---

## Project Structure

```
ultimate-arr-stack/
├── docker-compose.traefik.yml      # Traefik reverse proxy
├── docker-compose.arr-stack.yml    # Main media stack (Jellyfin)
├── docker-compose.utilities.yml    # Optional utilities (monitoring, disk usage)
├── docker-compose.cloudflared.yml  # Cloudflare tunnel
├── traefik/                        # Traefik configuration
│   ├── traefik.yml.example         # Static config template (copy & customize)
│   ├── traefik.yml                 # Your config (gitignored)
│   └── dynamic/
│       ├── tls.yml                 # TLS settings (generic, no customization needed)
│       ├── vpn-services.yml.example    # Jellyfin routing template
│       ├── vpn-services.yml        # Your routing config (gitignored)
│       └── utilities.yml           # Utilities routing (generic)
├── .env.example                    # Environment template
├── .env                            # Your configuration (gitignored)
├── .env.e2e.example                # E2E test env template
├── .env.e2e                        # Your E2E test config (gitignored)
├── docs/                           # Documentation
│   ├── SETUP.md                    # Complete setup guide
│   ├── REFERENCE.md                # Quick reference (IPs, ports, commands)
│   ├── BACKUP.md                   # Backup & restore guide
│   ├── UPGRADING.md                # How to upgrade the stack
│   ├── HOME-ASSISTANT.md           # Home Assistant integration
│   └── LEGAL.md                    # Legal notice
├── .claude/
│   ├── instructions.md             # AI assistant instructions
│   ├── config.local.md.example     # Private config template
│   └── config.local.md             # Your private config (gitignored)
├── scripts/                        # Pre-commit hooks
└── README.md
```

---

## Architecture

### Network Topology

```
Internet → Cloudflare Tunnel (or Router Port Forward 80→8080, 443→8443)
                            │
                            ▼
           Traefik (listening on 8080/8443 on NAS)
                            │
                            ├─► Jellyfin, Seerr, Bazarr (Direct)
                            │
                            └─► Gluetun (VPN Gateway)
                                    │
                                    └─► qBittorrent, Sonarr, Radarr, Prowlarr
                                        (Privacy-protected services)
```

### Multi-File Architecture

This project uses **separate Docker Compose files** for each layer:

| File | Layer | Purpose |
|------|-------|---------|
| `docker-compose.traefik.yml` | Infrastructure | Reverse proxy, SSL, networking |
| `docker-compose.cloudflared.yml` | Infrastructure | External access via Cloudflare |
| `docker-compose.arr-stack.yml` | Application | Media services |
| `docker-compose.utilities.yml` | Optional | Monitoring, disk usage tools |

**Why separate files?**
- Independent lifecycle management
- One Traefik can serve multiple stacks
- Easier troubleshooting with isolated logs
- Optional components can be skipped

**Deployment order**: arr-stack first (creates network) → Traefik → cloudflared → utilities (optional).

### Storage Structure

```
/volume1/
├── Media/
│   ├── downloads/    # qBittorrent
│   ├── tv/           # TV shows
│   └── movies/       # Movies
└── docker/
    └── arr-stack/
        ├── traefik/       # User-edited (bind mount)
        └── cloudflared/   # User-edited (bind mount)
```

**Service data** (Sonarr, Radarr, Jellyfin, etc.) is stored in Docker named volumes (e.g., `arr-stack_sonarr-config`), not in the repo directory. Use `scripts/arr-backup.sh` to back them up.

---

## Documentation Strategy

This project separates public documentation from private configuration:

| Type | Location | Git Tracked | Contains |
|------|----------|-------------|----------|
| **Public docs** | `docs/*.md`, `README.md` | Yes | Generic instructions with placeholders |
| **Config templates** | `*.example` files | Yes | Templates with `yourdomain.com` placeholders |
| **Your configs** | `traefik/*.yml`, `.env` | No | Your actual domain, customizations |
| **Private config** | `.claude/config.local.md` | No | Actual hostnames, IPs, usernames |
| **Credentials** | `.env` | No | Passwords, API tokens, private keys |

### Config File Pattern

Files requiring domain customization use the `.example` pattern:

```bash
# On first setup, copy templates and customize
cp traefik/traefik.yml.example traefik/traefik.yml
cp traefik/dynamic/vpn-services.yml.example traefik/dynamic/vpn-services.yml
# Edit both files: replace yourdomain.com with your actual domain
```

The actual `.yml` files are gitignored, so:
- `git pull` updates only `.example` files (won't overwrite your config)
- To get new features, manually merge changes from `.example` to your `.yml`

**Setup**: Copy `.claude/config.local.md.example` to `.claude/config.local.md` and fill in your values.

---

## Pre-commit Hooks

This repo includes validation hooks that run on `git commit`:

| Check | Blocks? | Purpose |
|-------|---------|---------|
| Secrets | Yes | Detects real API keys, private keys, bcrypt hashes |
| Env vars | Yes | Ensures compose `${VAR}` are documented in `.env.example` |
| YAML syntax | Yes | Catches invalid YAML before it breaks deployment |
| Port/IP conflicts | Yes | Detects duplicate ports or static IPs |
| Hardcoded domain | Block | Detects your hostname in tracked files (leaks identity) |
| Hardcoded domain | Warn | Detects your domain in tracked files (may be intentional) |
| NAS .env backup | Warn | Checks `.env.nas.backup` matches NAS |
| Uptime monitors | Warn | Checks Uptime Kuma monitors match services |

**Security note**: The secrets and hardcoded domain checks scan **all tracked files** in the repo, not just staged changes. This catches issues that may have been committed before these checks existed.

### Install

```bash
./setup-hooks.sh
```

### Optional: PyYAML for full YAML validation

The YAML syntax check works best with PyYAML installed. Without it, only basic checks (tab detection) run.

```bash
pip3 install --break-system-packages --user pyyaml
```

### Test manually

```bash
./scripts/pre-commit
```

### Uninstall

```bash
rm .git/hooks/pre-commit
```

### SSH-based Checks (NAS .env backup, Uptime monitors)

The last two checks require SSH access to your NAS. They gracefully skip when:
- NAS is not reachable (ping fails)
- SSH port is blocked/closed
- SSH authentication fails

**To enable these checks:**

1. **SSH key authentication** (recommended):
   ```bash
   ssh-copy-id your-user@your-nas.local
   ```

2. **Docker group membership** (for Uptime monitors check):
   ```bash
   # On NAS - allows docker commands without sudo
   sudo usermod -aG docker your-user
   # Log out and back in for group change to take effect
   ```

3. **Alternative: password auth** via `NAS_SSH_PASS` env var (requires `sshpass` installed)

## Releases

### The flow, end to end (branch-first — prevents version drift)

Every version-changing release follows this order. Doing it as one unbroken flow is what stops the CHANGELOG, tags, and GitHub releases from drifting out of sync with each other (which they have before — e.g. 1.7.19/1.7.20 shipped in commit messages with no CHANGELOG entry or release).

1. **Branch.** Make the change on a feature branch (`fix/…`, `chore/…`), commit, push.
2. **CHANGELOG entry, same branch.** Add a `## [X.Y.Z] - YYYY-MM-DD` section. This is not optional — a version bump with no CHANGELOG entry is an incomplete release. ⚠️ **Do NOT paste your real domain or NAS hostname into the entry** (e.g. `jellyfin.yourhost.cc`) — the pre-commit "Hardcoded domain" check **blocks** the commit on the hostname. Describe verification generically ("Jellyfin returned HTTP 302 through the tunnel"), not by URL.
3. **Deploy + verify on the NAS from the branch** (see CLAUDE.md → "Deploying to the NAS"): `git checkout <branch>` on the NAS, recreate the affected service(s) via compose, run the Pre-release Checklist below. Back up the config volume first for any service with a DB migration (Pi-hole, the \*arrs).
4. **Merge to `main`, push, sync the NAS** (`git checkout main && git pull`).
5. **Publish:** `gh release create vX.Y.Z --title vX.Y.Z --notes "…"` (this also creates the tag). A "tag" always means a full GitHub release with notes — never a bare `git tag`.

### Pre-release Checklist

**Every release MUST pass these checks before merging to `main` and tagging. No exceptions.**

1. **Run all BATS tests** (includes image tag validation):
   ```bash
   tests/bats-core/bin/bats tests/
   ```

2. **Verify all image tags are pullable on the NAS** — a full tear-down and pull:
   ```bash
   # SSH to the NAS, then for each compose file being released:
   cd $NAS_STACK_DIR
   docker compose -f docker-compose.arr-stack.yml pull
   docker compose -f docker-compose.traefik.yml pull
   docker compose -f docker-compose.utilities.yml pull
   ```
   Every image must pull successfully. Cached images mask bad tags — a fresh `pull` is the only way to be sure.

3. **Bring the stack up** and verify services start:
   ```bash
   docker compose -f docker-compose.traefik.yml up -d
   docker compose -f docker-compose.arr-stack.yml up -d
   # Check all containers are healthy
   docker ps --format 'table {{.Names}}\t{{.Status}}'
   ```

4. **Run E2E tests** — verify all UIs load and API responses are correct:
   ```bash
   npm run test:e2e
   ```
   This logs into each service, takes screenshots of every dashboard, and asserts root folders and media libraries are present. All 18 tests must pass. Screenshots are saved to `tests/e2e/screenshots/` for visual review.

### Tagging and Publishing

**Normal path — publish a new release** (creates the tag and the GitHub release together):

```bash
gh release create vX.Y.Z --title "vX.Y.Z" --notes "$(cat <<'EOF'
## Changed
- **Service** old → new. One line on how it was verified on the NAS.
EOF
)"
```

Keep the notes hostname-free (same rule as the CHANGELOG). The release notes are the CHANGELOG entry, lightly trimmed.

**Edge case — moving an existing tag.** Force-pushing a tag resets the GitHub release to Draft status. After moving a tag to a new commit:

```bash
# Move tag to new commit
git tag -d v1.x && git tag v1.x
git push origin :refs/tags/v1.x && git push origin v1.x

# REQUIRED: Fix the release status (force-push sets it to Draft)
gh release edit v1.x --draft=false --latest
```

Without the `gh release edit` step, the release stays Draft and won't show as Latest.

---

## Scripts Structure

```
scripts/
├── arr-backup.sh           # Backup all Docker named volumes
├── fix-radarr-paths.sh     # Fix Radarr paths after TRaSH naming organize
├── pre-commit              # Main hook (symlinked from .git/hooks/)
└── lib/
    ├── common.sh               # Shared functions (NAS config, SSH, file scanning)
    ├── check-secrets.sh        # Detect API keys, private keys
    ├── check-env-vars.sh       # Ensure compose vars are documented
    ├── check-yaml-syntax.sh    # Validate YAML syntax
    ├── check-conflicts.sh      # Detect port/IP conflicts
    ├── check-hardcoded-domain.sh  # Detect domain/hostname in tracked files
    ├── check-env-backup.sh     # Compare .env.nas.backup with NAS
    ├── check-uptime-monitors.sh   # Verify Uptime Kuma monitors
    ├── check-dns-duplicates.sh # Detect duplicate .lan domains
    ├── check-domains.sh        # Verify domain accessibility
    └── check-image-versions.sh # Check for stale Docker image tags
```

The `common.sh` library provides shared functions used by all checks:
- **NAS config**: Reads hostname/user from `.claude/config.local.md`
- **Domain config**: Reads domain from `.env` or `.env.nas.backup`
- **SSH helpers**: Standardized SSH commands with timeouts
- **File scanning**: Functions to get tracked/staged files
