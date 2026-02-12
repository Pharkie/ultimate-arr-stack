# Claude Code Instructions

## NAS Access

**You have SSH access to the NAS.** Credentials are in `.claude/config.local.md`.

To run commands on the NAS:
```bash
sshpass -p 'PASSWORD' ssh -o StrictHostKeyChecking=accept-new USER@HOSTNAME 'command here'
```

Read `.claude/config.local.md` first to get the hostname, user, and password.

## Project Structure

This is a Docker media stack for Ugreen NAS devices. Key paths:

- **Local dev repo**: `/Users/adamknowles/dev/arr-stack-ugreennas/`
- **NAS deploy path**: `/volume1/docker/arr-stack/`

When editing files that need to go on the NAS (like `pihole/02-local-dns.conf`), edit them **on the NAS**, not in this local repo.

## Cross-Stack: Therapy Stack

A separate Docker Compose project (`therapy-stack`) runs on the same NAS at `/volume1/docker/therapy-stack/`. It has its own network (`therapy-net`, 172.21.0.0/24) but Baserow is also connected to the `arr-stack` network (static IP 172.20.0.20) so Traefik can route to it.

**Files in this project that reference therapy-stack:**

| File | What it does |
|---|---|
| `pihole/02-local-dns.conf` | DNS entry for `baserow.lan` (points to Traefik macvlan IP) |
| `traefik/dynamic/therapy.local.yml` | Traefik route for baserow.lan → 172.20.0.20:80 |

**IMPORTANT:** Baserow's static IP (172.20.0.20) on the arr-stack network is critical. Without it, Docker can dynamically assign Gluetun's IP (172.20.0.3) to Baserow on reboot, breaking the entire VPN stack. The `ip_range: 172.20.0.128/25` in `docker-compose.traefik.yml` provides a safety net by confining dynamic IPs to 128-255.

The therapy-stack project lives at `/Users/adamknowles/dev/n8n Therapybot/Git repo/`.
