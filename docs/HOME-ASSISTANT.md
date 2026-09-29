# Home Assistant Integration

Every notification from the stack goes to Home Assistant through **one automation on one webhook**: Sonarr and Radarr, DIUN's image updates, the nightly backup's failure alert and the weekly queue-cleanup report. Each notice says what happened and what, if anything, to do ("Ready to watch: …", "Needs manual import: … Open Radarr → Activity → Queue and import it"). Uptime Kuma uses Home Assistant's own integration instead (see below).

## Prerequisites

- Home Assistant reachable from the NAS on your LAN.
- The Home Assistant companion app on your phone, for pushes.

## Step 1: Add the automation

Copy [HOME-ASSISTANT-notifications.yaml](HOME-ASSISTANT-notifications.yaml) into Home Assistant (Settings → Automations → Create → ⋮ → Edit in YAML), and change its two `CHANGE-ME` values:

- **`webhook_id`**: something nobody could guess, e.g. `arr-stack-notify-` plus a random string (`openssl rand -hex 12`). It is the only credential the webhook has.
- **`notify.mobile_app_…`**: your phone's notify service (Developer tools → Actions, search `notify.mobile_app`).

The automation accepts three shapes of JSON and turns each into one notice:

| Sender | Shape | Level |
|---|---|---|
| The stack's scripts, and anything you add | `{"title", "message", "level"?, "url"?, "tag"?}` | as sent: `info`, `warning` (default) or `critical` |
| Sonarr / Radarr | their own webhook payload | `warning` for health problems and manual imports, `info` otherwise |
| DIUN | its own webhook payload | `warning` |

`info` goes to the notification panel only; `warning` and `critical` also push to the phone (a normal push, so Focus modes still apply). A notice with the same `tag` replaces the earlier one.

## Step 2: Point every sender at it

The URL is Home Assistant's **LAN address**, not a `.lan` name through Traefik and not Nabu Casa, because the automation only accepts requests from your network (`local_only`):

```
http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME
```

- **Sonarr and Radarr:** Settings → Connect → + → Webhook. URL as above, method POST. Events: *On Import Complete*, *On Upgrade*, *On Health Issue*, *On Health Restored*, *On Manual Interaction Required*. Skip *On Grab* and *On Movie Added*: they fire before anything is ready.
- **DIUN, the backup and the queue cleanup:** set both lines in `.env` on the NAS, then recreate DIUN (`docker compose -f docker-compose.utilities.yml up -d --no-deps diun`). The scripts read `HA_WEBHOOK_URL` from `.env` themselves.

  ```bash
  DIUN_WEBHOOK_URL=http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME
  HA_WEBHOOK_URL=http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME
  ```

- **Beszel:** Settings → Notifications → Add URL. Its JSON template sends `title` and `message`, the generic shape:

  ```
  generic+http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME?template=json
  ```

## Step 3: Prove it on your phone

Home Assistant answers `200 OK` to *any* webhook ID, including one with no automation behind it, so a sender saying "sent" proves nothing. Fire each one and look at the panel and the phone:

| Fire | Expect |
|---|---|
| Sonarr and Radarr: Settings → Connect → the webhook → **Test** | Panel only: "Radarr: test notification / Radarr can reach Home Assistant. Nothing to do." |
| `docker exec diun diun notif test` | Push: "Image update available" |
| `./scripts/arr-backup.sh --tar --usb no-such-dir` (fails before touching anything) | Push: "Arr Stack: Backup Failed / Failed during: finding USB device…" |

A notice titled "Arr stack: unrecognised notification" means the body wasn't understood. Most often the sender didn't send `Content-Type: application/json`, which Home Assistant needs before it parses a body at all.

## Adding your own sender

POST JSON to the same webhook with a `Content-Type: application/json` header:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"title":"Disk nearly full","message":"/volume1 is at 92%.","level":"warning","tag":"disk"}' \
  "$HA_WEBHOOK_URL"
```

## Uptime Kuma → Home Assistant

Requires `docker-compose.utilities.yml` deployed.

In Uptime Kuma: Settings → Notifications → Setup Notification
- Type: Home Assistant
- URL: `http://homeassistant.lan:8123`
- Long-Lived Access Token: (create in HA → Profile → Long-Lived Access Tokens)

Beszel's alert thresholds are set per system: click the system in Beszel and set CPU, memory, disk and load limits.
