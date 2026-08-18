#!/bin/bash
# Propagates the current Sonarr/Radarr/Prowlarr/SABnzbd API keys into every
# app that stores a copy of them as a client credential: Prowlarr's
# Applications and Sonarr/Radarr's SABnzbd download clients via Terraform;
# Bazarr's and Seerr's Sonarr/Radarr connections, and Sonarr/Radarr's own
# Indexer entries (which separately cache Prowlarr's key to query indexers
# through Prowlarr's proxy - the reverse direction from Applications, and
# not covered by the Terraform resources above), via direct API calls, since
# none of the four have a Terraform provider/resource for this. Run this
# after rotating any of those keys, or any time you want to confirm the
# stack matches what's declared here.
#
# Requires: `bw` unlocked with BW_SESSION exported in this shell, `terraform`,
# `curl`, `jq`, and SSH access to the NAS (for the Bazarr/Seerr restarts).
#
# Usage: ./apply.sh [-auto-approve]

set -euo pipefail

bw_note() { bw get notes "$1" --session "$BW_SESSION"; }

# Strips the read-only `id` field Seerr's settings PUT rejects (confirmed
# live 2026-08-17: `400 request/body/id is read-only`) while swapping in the
# current key. Pulled out as its own function so tests/credential-propagation.bats
# can exercise this exact transform against a fixture without a live Seerr.
build_seerr_payload() {
  local settings_json="$1" new_key="$2"
  echo "$settings_json" | jq -c --arg k "$new_key" '.[0] | .apiKey = $k | del(.id)'
}

# Each Indexer entry Prowlarr's sync created in Sonarr/Radarr stores its own
# copy of PROWLARR'S key (used to query indexers through Prowlarr's proxy) -
# a separate credential direction from the prowlarr_application_* resources
# in main.tf, which only propagate Sonarr/Radarr's key TO Prowlarr, never the
# reverse. Nothing else touches this, so it drifts silently whenever
# Prowlarr's key rotates (confirmed live 2026-08-17: this, not the Terraform
# resources, was the actual cause of a real Radarr 401 - terraform apply
# reported "no changes" because it was only checking the other direction).
# No restart needed: unlike Seerr, Sonarr/Radarr re-read indexer config per
# request rather than caching a client at startup.
sync_indexer_keys() {
  local app_name="$1" base="$2" app_key="$3" prowlarr_key="$4"
  local indexers ids id body
  indexers=$(curl -sf -H "X-Api-Key: ${app_key}" "${base}/api/v3/indexer")
  ids=$(echo "$indexers" | jq -r '.[].id')
  for id in $ids; do
    body=$(echo "$indexers" | jq -c --argjson id "$id" --arg k "$prowlarr_key" \
      '.[] | select(.id == $id) | .fields |= map(if .name == "apiKey" then .value = $k else . end)')
    curl -sf -X PUT "${base}/api/v3/indexer/${id}" \
      -H "X-Api-Key: ${app_key}" -H "Content-Type: application/json" -d "$body" >/dev/null
  done
  echo "${app_name} indexer keys synced (ids: $(echo "$ids" | tr '\n' ' '))"
}

main() {
  cd "$(dirname "${BASH_SOURCE[0]}")"

  if [[ -z "${BW_SESSION:-}" ]]; then
    echo "BW_SESSION is not set — run 'bw unlock' and export BW_SESSION first." >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  source ../.env

  SONARR_KEY=$(bw_note "arr-stack: Sonarr API key")
  RADARR_KEY=$(bw_note "arr-stack: Radarr API key")
  PROWLARR_KEY=$(bw_note "arr-stack: Prowlarr API key")
  SABNZBD_KEY=$(bw_note "arr-stack: SABnzbd API key")
  SEERR_KEY=$(bw_note "arr-stack: Seerr API key")

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
  # Bazarr's private /api/system/settings POST does not reliably persist a
  # partial sonarr/radarr update (confirmed live 2026-08-18: returns 204 but
  # silently no-ops on the apikey field, most likely a JSON-vs-form-payload
  # mismatch in its undocumented settings-save endpoint -- it was also
  # sending the wrong "ip" value, "gluetun", which Bazarr can't resolve
  # since it isn't on Gluetun's network namespace, though that turned out
  # not to be the actual blocker). Editing config.yaml directly and
  # restarting is the same mechanism already proven for rotating Bazarr's
  # own key. Section-scoped via awk (not an absolute line number, which
  # would drift if config.yaml's structure changes) so only the target
  # section's apikey line is touched -- the file has several apikey lines
  # (auth, jellyfin, plex, radarr, sonarr, subsource all have their own).
  # Live-verified idempotent 2026-08-18: re-running against an
  # already-correct key produces a byte-identical file.
  # Validates the awk output contains the new key before copying it into the
  # container, so a section-header regex that stops matching (config.yaml
  # restructured, section renamed) fails loudly instead of silently copying
  # an unchanged file over the container's config while reporting success.
  sync_bazarr_key() {
    local section="$1" new_key="$2"
    ssh -o ConnectTimeout=15 cloud-nas bash -s -- "${section}:" "$new_key" <<'REMOTE'
set -e
section="$1"
new_key="$2"
tmpfile="/tmp/bazarr_config_new.$$.yaml"
trap 'rm -f "$tmpfile"' EXIT
docker exec bazarr awk -v key="$new_key" -v section="$section" '
  /^[a-zA-Z0-9_-]+:$/ { in_section = ($0 == section) }
  in_section && /^  apikey:/ { print "  apikey: " key; next }
  { print }
' /config/config/config.yaml > "$tmpfile"
grep -qF "  apikey: $new_key" "$tmpfile" || {
  echo "sync_bazarr_key: apikey line not found for section $section after awk -- aborting, config.yaml not touched" >&2
  exit 1
}
docker cp "$tmpfile" bazarr:/config/config/config.yaml
REMOTE
  }
  sync_bazarr_key "sonarr" "$SONARR_KEY"
  sync_bazarr_key "radarr" "$RADARR_KEY"
  ssh -o ConnectTimeout=15 cloud-nas "docker restart bazarr" >/dev/null
  echo "Bazarr synced (config.yaml edited directly) and restarted."

  echo
  echo "== Syncing Seerr's Sonarr/Radarr connections (no Terraform provider) =="
  SEERR_BASE="http://${NAS_IP}:5055"
  RADARR_PAYLOAD=$(build_seerr_payload "$(curl -sf -H "X-Api-Key: ${SEERR_KEY}" "${SEERR_BASE}/api/v1/settings/radarr")" "$RADARR_KEY")
  SONARR_PAYLOAD=$(build_seerr_payload "$(curl -sf -H "X-Api-Key: ${SEERR_KEY}" "${SEERR_BASE}/api/v1/settings/sonarr")" "$SONARR_KEY")
  curl -sf -X PUT "${SEERR_BASE}/api/v1/settings/radarr/0" \
    -H "X-Api-Key: ${SEERR_KEY}" -H "Content-Type: application/json" -d "$RADARR_PAYLOAD" >/dev/null
  curl -sf -X PUT "${SEERR_BASE}/api/v1/settings/sonarr/0" \
    -H "X-Api-Key: ${SEERR_KEY}" -H "Content-Type: application/json" -d "$SONARR_PAYLOAD" >/dev/null
  # Seerr caches its Radarr/Sonarr API clients at process start - a settings
  # PUT updates the stored config but not the already-running client, so the
  # background Download Tracker job keeps 401ing against the old key until
  # restarted (confirmed live 2026-08-17: PUT alone was not enough).
  ssh cloud-nas "docker restart seerr" >/dev/null
  echo "Seerr synced and restarted."

  echo
  echo "== Syncing Sonarr/Radarr indexer connections (Prowlarr proxy key) =="
  sync_indexer_keys "Radarr" "http://${NAS_IP}:7878" "$RADARR_KEY" "$PROWLARR_KEY"
  sync_indexer_keys "Sonarr" "http://${NAS_IP}:8989" "$SONARR_KEY" "$PROWLARR_KEY"
}

# Only runs when executed directly, not when sourced by
# tests/credential-propagation.bats - so tests can exercise
# build_seerr_payload/sync_indexer_keys against fixtures without needing
# BW_SESSION, a live NAS, or Terraform installed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
