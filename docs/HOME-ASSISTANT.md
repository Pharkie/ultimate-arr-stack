# Home Assistant Integration

Send notifications from Sonarr/Radarr, DIUN, Uptime Kuma, and Beszel to Home Assistant.

## Prerequisites

- Home Assistant accessible from your Docker network
- Gluetun's `FIREWALL_OUTBOUND_SUBNETS` includes your LAN (e.g., `192.168.0.0/24`)

**Important:** Use `.lan` TLD, not `.local`. Docker containers can't resolve `.local` domains (mDNS reserved).

## Step 1: Create HA Automation

In Home Assistant: Settings → Automations → Create → Edit in YAML:

```yaml
alias: Arr Stack Notifications
trigger:
  - platform: webhook
    webhook_id: arr-notifications
    local_only: false
action:
  - service: notify.persistent_notification
    data:
      title: >
        {% if trigger.json.series %}
          {{ trigger.json.series.title }}
        {% elif trigger.json.movie %}
          {{ trigger.json.movie.title }}
        {% else %}
          {{ trigger.json.eventType }}
        {% endif %}
      message: >
        {% if trigger.json.eventType == "Health" %}
          {{ trigger.json.message }}
        {% elif trigger.json.eventType == "ManualInteractionRequired" %}
          Queue item needs manual import
        {% elif trigger.json.episodes %}
          S{{ trigger.json.episodes[0].seasonNumber }}E{{ trigger.json.episodes[0].episodeNumber }} - {{ trigger.json.episodes[0].title }}
        {% elif trigger.json.movie %}
          ({{ trigger.json.movie.year }}) - {{ trigger.json.eventType }}
        {% else %}
          {{ trigger.json.eventType }}
        {% endif %}
```

Change `notify.persistent_notification` to `notify.mobile_app_your_phone` for push notifications.

## Step 2: Configure Sonarr/Radarr

**Sonarr:** Settings → Connect → Add → Webhook
- URL: `http://homeassistant.lan:8123/api/webhook/arr-notifications`
- Events: On Import Complete, On Upgrade, On Health Issue, On Manual Interaction Required

**Radarr:** Same URL and events.

> **Skip "On Grab" and "On Movie Added"** — these fire when Sonarr/Radarr find a release or add a title to the wanted list, not when files are actually ready. They're noisy and not actionable.

Click **Test** to verify.

## DIUN → Home Assistant

Requires `docker-compose.utilities.yml` deployed.

DIUN monitors all running containers and sends a webhook when a newer image version is available on the registry.

### Step 1: Create HA Automation

Pick a webhook ID nobody could guess (e.g. `diun-image-updates-` plus a random string) and use it in both places. DIUN sends the image under a top-level `image` field, with `status` (`new`: a newer tag appeared; `update`: the pinned tag's digest changed), `hub_link` (may be empty) and `hostname`.

```yaml
alias: DIUN - Arr Stack Image Update Notification
mode: queued
triggers:
  - trigger: webhook
    webhook_id: diun-image-updates-CHANGE-ME
    allowed_methods:
      - POST
    local_only: true
actions:
  - action: persistent_notification.create
    data:
      notification_id: "diun_{{ trigger.json.image | slugify }}"
      title: "Image update available"
      message: >
        {{ trigger.json.image }} ({{ trigger.json.status }}) on {{ trigger.json.hostname }}
        {% if trigger.json.hub_link %}{{ trigger.json.hub_link }}{% endif %}
```

Add a `notify.mobile_app_your_phone` action for push notifications. The `notification_id` makes a repeat for the same image replace the earlier notice.

### Step 2: Configure .env

Point DIUN at Home Assistant's LAN address directly, not through Traefik or Nabu Casa, so `local_only: true` holds:

```bash
DIUN_WEBHOOK_URL=http://192.168.1.20:8123/api/webhook/diun-image-updates-CHANGE-ME
```

Then recreate DIUN (`docker compose -f docker-compose.utilities.yml up -d --no-deps diun`) and test the whole path:

```bash
docker exec diun diun notif test
```

A notice must actually appear in Home Assistant. DIUN's "Notification sent" proves nothing on its own: Home Assistant answers 200 to a webhook ID that has no automation behind it.

DIUN checks registries daily at 6am by default. Customise with:

```bash
DIUN_SCHEDULE=0 6 * * *  # cron format
```

## Uptime Kuma → Home Assistant

Requires `docker-compose.utilities.yml` deployed.

In Uptime Kuma: Settings → Notifications → Setup Notification
- Type: Home Assistant
- URL: `http://homeassistant.lan:8123`
- Long-Lived Access Token: (create in HA → Profile → Long-Lived Access Tokens)

## Beszel → Home Assistant

Requires `docker-compose.utilities.yml` deployed.

### Step 1: Create HA Automation

Beszel sends a different JSON format than Sonarr/Radarr, so create a separate automation:

```yaml
alias: Beszel Alerts
description: System alerts from Beszel monitoring
trigger:
  - platform: webhook
    webhook_id: beszel-alerts
    local_only: false
action:
  - service: notify.persistent_notification
    data:
      title: "{{ trigger.json.title | default('Beszel Alert') }}"
      message: "{{ trigger.json.message | default(trigger.json | string) }}"
mode: single
```

### Step 2: Configure Beszel

In Beszel: Settings → Notifications → Add URL

**Important:** Beszel can't resolve `.lan` domains (uses Docker internal DNS). Use your Home Assistant IP address directly.

```
generic+http://HOME_ASSISTANT_IP:8123/api/webhook/beszel-alerts?template=json
```

Example: `generic+http://192.168.1.20:8123/api/webhook/beszel-alerts?template=json`

Click **Test URL** to verify.

### Step 3: Configure Alerts

In Beszel, click on your system → set alert thresholds for CPU, Memory, Disk, Load Average, etc.

To view/manage alerts: `http://beszel.lan/_/#/collections` → select the alerts collection.
