#!/bin/bash
set -uo pipefail
#
# Detects the credential-propagation bug class that has now silently broken
# this stack twice: Seerr's cached Sonarr/Radarr keys going stale after a
# declarative rotation (2026-08-17), and Radarr/Sonarr's Indexer entries
# caching a stale Prowlarr key (also 2026-08-17, found by this script's own
# predecessor) - in both cases nothing surfaced it beyond a UI warning
# nobody was looking at, until background jobs started silently 401ing.
#
# Calls each app's own live "test connection" API directly (indexer/testall,
# applications/test, the service/{app}/0 probe Seerr's own UI uses) rather
# than scanning logs - a real auth check, not a guess from log text. Bazarr
# is the one exception: it has no equivalent live-test endpoint, so it still
# falls back to a log scan.
#
# Runs entirely on the NAS itself (systemd calls this script directly, not
# over SSH) using `docker exec`/`docker logs`/`curl localhost` - needs no
# Bitwarden access of its own. Sonarr/Radarr/Prowlarr's own keys come from
# .env (declarative self-keys, already there for docker-compose - not a new
# secret). Bazarr and Seerr have no declarative self-key, so this reads
# THEIR OWN key straight from their own already-running config each time via
# `docker exec` - the only other place those two keys live is Bitwarden,
# which needs a master password this script deliberately never touches (see
# the detect-and-alert design note in CLAUDE.md/memory, 2026-08-17: the
# user's vault master key must never be stored anywhere but their own head,
# so a scheduled job can fix nothing that needs `bw unlock` - it can only
# detect and point at the manual fix).
#
# Usage:
#   ./scripts/detect-credential-drift.sh
#   (needs RADARR_API_KEY/SONARR_API_KEY/PROWLARR_API_KEY exported - the
#   systemd unit sources these from .env via EnvironmentFile)
#
# Exit codes:
#   0 = every live connectivity test passed
#   1 = one or more apps failed a live auth test (or the check itself
#       couldn't reach an app - treated as a finding, not silently skipped)
#
# Fix for a real finding: from a local checkout (not the NAS),
#   cd terraform && bw unlock && ./apply.sh
#
# Run on a schedule via the systemd timer alongside this script
# (detect-credential-drift.timer). Installed as a --user unit under leoleg
# (no root needed - ~/.config/systemd/user/ is writable by its own user; the
# only extra step is `loginctl enable-linger leoleg`, which a normal user
# can run on themselves without sudo, so the timer keeps firing after SSH
# sessions end and across reboots). See the .timer/.service files next to
# this one, and their `systemctl --user ...` install commands in the repo's
# deploy notes.

: "${RADARR_API_KEY:?RADARR_API_KEY not set - source .env first}"
: "${SONARR_API_KEY:?SONARR_API_KEY not set - source .env first}"
: "${PROWLARR_API_KEY:?PROWLARR_API_KEY not set - source .env first}"

findings=""
add_finding() {
  findings+=$'\n'"-- $1 --"$'\n'"$2"$'\n'
}

# --- Radarr/Sonarr: live indexer test. Also covers Prowlarr's proxy key
# cached in each Indexer entry - the direction that actually broke live on
# 2026-08-17 (terraform apply reported "no changes" because it only checks
# the opposite pairing; this check would have caught it directly). ---
check_indexers() {
  local app="$1" port="$2" key="$3" result bad
  result=$(curl -s -X POST "http://localhost:${port}/api/v3/indexer/testall" \
    -H "X-Api-Key: ${key}" -H "Content-Type: application/json" -d '{}')
  bad=$(python3 -c "
import json, sys
try:
    data = json.loads('''$result''')
except Exception:
    print('could not reach indexer/testall - is the container up?')
    sys.exit()
for i in data:
    if i.get('isValid'):
        continue
    msgs = ' '.join(f.get('errorMessage', '') for f in i.get('validationFailures', []))
    # A bare rate-limit (429) is the indexer site's own throttling, not a
    # stale credential - only flag genuine auth-failure signatures.
    if '429' in msgs and not any(s in msgs for s in ('401', 'nauthorized', 'nvalid credentials')):
        continue
    if any(s in msgs for s in ('401', 'nauthorized', 'nvalid credentials')):
        print(f\"indexer {i.get('id')}: {msgs}\")
" 2>/dev/null)
  [[ -n "$bad" ]] && add_finding "${app} (live indexer test)" "$bad"
}
check_indexers "Radarr" 7878 "$RADARR_API_KEY"
check_indexers "Sonarr" 8989 "$SONARR_API_KEY"

# --- Prowlarr: live Applications test (the Prowlarr -> Sonarr/Radarr
# direction; Terraform manages this pairing but only applies on drift, it
# doesn't alert - this exercises the same live connection Terraform's plan
# would silently no-op on if the credential were actually fine). ---
check_application() {
  local id="$1" name="$2" body result code resp_body
  body=$(curl -sf -H "X-Api-Key: ${PROWLARR_API_KEY}" "http://localhost:9696/api/v1/applications/${id}") || {
    add_finding "Prowlarr application ${name}" "could not fetch application ${id} - is Prowlarr up?"
    return
  }
  result=$(curl -s -w '|%{http_code}' -X POST "http://localhost:9696/api/v1/applications/test" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" -H "Content-Type: application/json" -d "$body")
  code="${result##*|}"
  resp_body="${result%|*}"
  if [[ "$code" != "200" || "$resp_body" != "{}" ]]; then
    add_finding "Prowlarr -> ${name}" "application test failed (HTTP ${code}): ${resp_body}"
  fi
}
check_application 1 "Sonarr"
check_application 2 "Radarr"

# --- Seerr: probes the same live radarr/sonarr connection its own Settings
# UI exercises when you hit "Test" - a genuine round trip through Seerr's
# cached key, not just a settings read. Seerr has no declarative self-key,
# so its own key is read fresh from its own config each run. ---
check_seerr() {
  local seerr_key svc code
  seerr_key=$(docker exec seerr node -e 'console.log(require("/app/config/settings.json").main.apiKey)' 2>/dev/null) || {
    add_finding "Seerr" "could not read Seerr's own key - is the container up?"
    return
  }
  for svc in radarr sonarr; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Api-Key: ${seerr_key}" "http://localhost:5055/api/v1/service/${svc}/0")
    [[ "$code" != "200" ]] && add_finding "Seerr -> ${svc}" "service probe returned HTTP ${code}"
  done
}
check_seerr

# --- Bazarr: no live-test endpoint equivalent to the ones above was found
# (confirmed 2026-08-17) - falls back to a log scan for this one app only.
# Deliberately NOT a bare `401` in the pattern - session IDs, hex memory
# addresses, and stack-trace line numbers all contain stray "401"
# substrings often enough to make that alone pure noise (confirmed live
# against real logs across three other containers before this script moved
# them to live API tests instead).
check_bazarr_logs() {
  local hits
  hits=$(docker logs bazarr --since 35m 2>&1 \
    | grep -iE '[Uu]nauthorized|[Ii]nvalid credentials|[Aa]pi[Kk]ey.*(invalid|incorrect|expired)' \
    | tail -3)
  [[ -n "$hits" ]] && add_finding "Bazarr (log scan - no live-test endpoint)" "$hits"
}
check_bazarr_logs

if [[ -n "$findings" ]]; then
  echo "CREDENTIAL DRIFT DETECTED:"
  echo "$findings"
  echo "Fix: from a local checkout, run 'cd terraform && bw unlock && ./apply.sh'"
  exit 1
fi

echo "OK: all live connectivity tests passed, no cross-app auth failures"
