# Home Assistant Integration

Every notification from the stack goes to Home Assistant through **one automation on one webhook**: Sonarr and Radarr, Uptime Kuma, Beszel, the nightly backup's failure alert, the weekly queue-cleanup report and the daily stuck-request check (which also names an imported episode file whose length says it is another show). Each notice says what happened and what, if anything, to do ("Ready to watch: …", "Needs manual import: … Open Radarr → Activity → Queue and import it").

## Prerequisites

- Home Assistant reachable from the NAS on your LAN.
- The Home Assistant companion app on your phone, for pushes.

## Step 1: Add the automation

Copy [HOME-ASSISTANT-notifications.yaml](HOME-ASSISTANT-notifications.yaml) into Home Assistant (Settings → Automations → Create → ⋮ → Edit in YAML), and change its two `CHANGE-ME` values:

- **`webhook_id`**: something nobody could guess, e.g. `arr-stack-notify-` plus a random string (`openssl rand -hex 12`). It is the only credential the webhook has.
- **`notify.mobile_app_…`**: your phone's notify service (Developer tools → Actions, search `notify.mobile_app`).

The automation accepts two shapes of JSON and turns each into one notice:

| Sender | Shape | Level |
|---|---|---|
| The stack's scripts, Uptime Kuma, Beszel, and anything you add | `{"title", "message", "level"?, "url"?, "tag"?}` | as sent: `info`, `warning` (default) or `critical` |
| Sonarr / Radarr | their own webhook payload | `warning` for health problems and manual imports, `info` otherwise |

`info` goes to the notification panel only; `warning` and `critical` also push to the phone (a normal push, so Focus modes still apply). A notice with the same `tag` replaces the earlier one.

### Step 1b: Make a VPN outage one notice (recommended)

When the VPN goes down, a lot else goes down with it, and each one sends its own notice. On one install, a lapsed subscription produced *VPN Check is down*, *qBittorrent is down* (then up and down again a dozen times), Sonarr's *All indexers are unavailable*, Sonarr's and Radarr's *Unable to communicate with qBittorrent*, and a stuck-request report blaming indexer backoff. All of them were the VPN.

With [HOME-ASSISTANT-vpn-fold.yaml](HOME-ASSISTANT-vpn-fold.yaml) added (a package, or the `template:` entry in `configuration.yaml`), the automation folds those into the *VPN Check is down* notice:

- While Kuma's `VPN Check` is down, a follow-on notice gets no notice or push of its own. It is listed in the VPN notice instead, and its own notice is dismissed if one was already there. The follow-ons are Kuma's `qBittorrent`, `Prowlarr`, `SABnzbd` and `FlareSolverr` monitors (the services inside gluetun), Sonarr and Radarr's indexer and download-client health checks, and the stuck-request report.
- A follow-on posted in the 30 minutes **before** the VPN notice is pulled in when that notice opens. A service monitor goes down a few minutes into an outage, sooner than `VPN Check`.
- A recovery takes its line out silently. That includes the ones that arrive just after the VPN is back: *VPN Check is back up* says "Still waiting to recover: …" until the last one clears.
- Anything else posts and pushes as before.

The names it matches are variables at the end of the automation's `variables:` (`vpn_name`, `behind_vpn`, `vpn_checks`, `vpn_reports`). Change them if your monitors are named differently. Recoveries need Sonarr and Radarr's **On Health Restored** (Step 2); without it, a held health warning waits for ever. Without the sensor, the automation posts everything as before.

## Step 2: Point every sender at it

The URL is Home Assistant's **LAN address**, not a `.lan` name through Traefik and not Nabu Casa, because the automation only accepts requests from your network (`local_only`):

```
http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME
```

- **Sonarr and Radarr:** Settings → Connect → + → Webhook. URL as above, method POST. Events: *On Import Complete*, *On Upgrade*, *On Health Issue*, *On Health Restored*, *On Manual Interaction Required*. Skip *On Grab* and *On Movie Added*: they fire before anything is ready.
- **The backup, the queue cleanup and the stuck-request check:** set this line in `.env` on the NAS. The scripts read it themselves.

  ```bash
  HA_WEBHOOK_URL=http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME
  ```

- **Uptime Kuma:** use a **Webhook** notification, not Kuma's *Home Assistant* type. That type calls a notify action directly (every device, unless you name one), so Kuma's alerts skip this automation: no consistent wording, no levels, and nothing replaces a "down" notice when the monitor recovers. In Kuma, Settings → Notifications → **Setup Notification**:
  1. **Notification Type:** Webhook. **Friendly Name:** anything, e.g. `Home Assistant webhook`.
  2. **Post URL:** the webhook URL above, the same value as `HA_WEBHOOK_URL` in `.env`. To copy it from the NAS to a Mac clipboard without typing it out: `ssh <nas> "sed -n 's/^HA_WEBHOOK_URL=//p' <stack dir>/.env" | tr -d "\"'\n" | pbcopy`
  3. **HTTP Method:** POST.
  4. **Request Body:** Custom Body, and paste:

     ```
     {%- if heartbeatJSON == nil -%}{%- assign level = "warning" -%}{%- capture title -%}Uptime Kuma test{%- endcapture -%}{%- capture message -%}Kuma can reach Home Assistant. Nothing to do.{%- endcapture -%}
     {%- elsif heartbeatJSON.status == 0 -%}{%- assign level = "warning" -%}{%- capture title -%}{{ name }} is down{%- endcapture -%}{%- capture message -%}{{ heartbeatJSON.msg }}{% if monitorJSON.description %}. {{ monitorJSON.description }}{% endif %}{%- endcapture -%}
     {%- else -%}{%- assign level = "info" -%}{%- capture title -%}{{ name }} is back up{%- endcapture -%}{%- capture message -%}Responding normally again.{%- endcapture -%}
     {%- endif -%}
     {"title": {{ title | json }}, "message": {{ message | json }}, "level": "{{ level }}", "tag": "kuma-{{ monitorJSON.id | default: 'test' }}"}
     ```

  5. Tick **Additional Headers** and enter `{"Content-Type": "application/json"}`. Without it Kuma sends the body as a form post and Home Assistant won't read it.
  6. Tick **Default enabled** and **Apply on all existing monitors**, then **Save**.
  7. If an older Kuma notification (such as a *Home Assistant* one) is still there, delete it, or every alert arrives twice.

  A monitor going down sends a `warning`; coming back up sends an `info` that replaces it. A monitor's *Description* is added to its down message, so say there what to check.

- **Beszel:** Settings → Notifications → Add URL. Its JSON template sends `title` and `message`, the generic shape. Alert thresholds are set per system: click the system and set CPU, memory, disk and load limits.

  ```
  generic+http://192.168.1.20:8123/api/webhook/arr-stack-notify-CHANGE-ME?template=json
  ```


## Step 3: Prove it on your phone

Home Assistant answers `200 OK` to *any* webhook ID, including one with no automation behind it, so a sender saying "sent" proves nothing. Fire each one and look at the panel and the phone:

| Fire | Expect |
|---|---|
| Sonarr and Radarr: Settings → Connect → the webhook → **Test** | Panel only: "Radarr: test notification / Radarr can reach Home Assistant. Nothing to do." |
| Uptime Kuma: Settings → Notifications → the webhook → **Test** | Push: "Uptime Kuma test / Kuma can reach Home Assistant. Nothing to do." |
| `./scripts/arr-backup.sh --tar --usb no-such-dir` (fails before touching anything) | Push: "Arr Stack: Backup Failed / Failed during: finding USB device…" |
| `./scripts/check-stuck-requests.sh --test` | Panel only: "Stuck-request check: test / The daily stuck-request check can reach Home Assistant. Nothing to do." |

A notice titled "Arr stack: unrecognised notification" means the body wasn't understood. Most often the sender didn't send `Content-Type: application/json`, which Home Assistant needs before it parses a body at all.

## Adding your own sender

POST JSON to the same webhook with a `Content-Type: application/json` header:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"title":"Disk nearly full","message":"/volume1 is at 92%.","level":"warning","tag":"disk"}' \
  "$HA_WEBHOOK_URL"
```
