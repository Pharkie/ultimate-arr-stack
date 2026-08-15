#!/bin/bash
# Propagates the current Sonarr/Radarr/SABnzbd API keys into every app that
# stores a copy of them as a client credential (Prowlarr's Applications,
# Sonarr/Radarr's SABnzbd download clients via Terraform; Bazarr's Sonarr/
# Radarr connections via a direct API call, since Bazarr has no Terraform
# provider). Run this after rotating any of those keys, or any time you
# want to confirm the stack matches what's declared here.
#
# Requires: `bw` unlocked with BW_SESSION exported in this shell, `terraform`,
# `curl`, and SSH access to the NAS (for the Bazarr restart).
#
# Usage: ./apply.sh [-auto-approve]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -z "${BW_SESSION:-}" ]]; then
  echo "BW_SESSION is not set — run 'bw unlock' and export BW_SESSION first." >&2
  exit 1
fi

# shellcheck disable=SC1091
source ../.env

bw_note() { bw get notes "$1" --session "$BW_SESSION"; }

SONARR_KEY=$(bw_note "arr-stack: Sonarr API key")
RADARR_KEY=$(bw_note "arr-stack: Radarr API key")
PROWLARR_KEY=$(bw_note "arr-stack: Prowlarr API key")
SABNZBD_KEY=$(bw_note "arr-stack: SABnzbd API key")
BAZARR_KEY=$(bw_note "arr-stack: Bazarr API key")

# Provider auth (native env vars, never written to a .tf file or state as
# provider config - only appear in resource attribute values, which
# Terraform already treats as sensitive).
export SONARR_URL="http://${NAS_IP}:8989"
export SONARR_API_KEY="$SONARR_KEY"
export RADARR_URL="http://${NAS_IP}:7878"
export RADARR_API_KEY="$RADARR_KEY"
export PROWLARR_URL="http://${NAS_IP}:9696"
export PROWLARR_API_KEY="$PROWLARR_KEY"

# Resource attribute values (the credential copies being propagated).
export TF_VAR_sonarr_api_key="$SONARR_KEY"
export TF_VAR_radarr_api_key="$RADARR_KEY"
export TF_VAR_sabnzbd_api_key="$SABNZBD_KEY"

terraform init -input=false
terraform apply "$@"

echo
echo "== Syncing Bazarr's Sonarr/Radarr connections (no Terraform provider) =="
BAZARR_BASE="http://${NAS_IP}:6767"
curl -sf -X POST "${BAZARR_BASE}/api/system/settings" \
  -H "X-API-KEY: ${BAZARR_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"sonarr\": {\"ip\": \"gluetun\", \"port\": \"8989\", \"apikey\": \"${SONARR_KEY}\", \"base_url\": \"\"}, \"radarr\": {\"ip\": \"gluetun\", \"port\": \"7878\", \"apikey\": \"${RADARR_KEY}\", \"base_url\": \"\"}}" \
  >/dev/null
ssh cloud-nas "docker restart bazarr" >/dev/null
echo "Bazarr synced and restarted."
