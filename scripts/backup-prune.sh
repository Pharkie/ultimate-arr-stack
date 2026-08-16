#!/bin/bash
set -euo pipefail
#
# GFS (Grandfather-Father-Son) tiered retention for arr-stack-backup-*.tar.gz
# files created by arr-backup.sh. Same scheme used by restic/BorgBackup/Time
# Machine, adapted for event-triggered (not scheduled) backups:
#
#   age <= 7 days    keep every backup
#   7-30 days old     keep the newest backup per calendar day
#   30-180 days old    keep the newest backup per ISO week
#   > 180 days old      keep the newest backup per month, capped at 12 total
#
# This is separate from arr-backup.sh's own flat 7-day USB rotation (see
# docs/BACKUP.md's "Automated Daily Backup" cron job) - it's meant for a
# separate, higher-frequency destination such as pre-deploy backups, where
# keeping 7 days of *everything* would grow unbounded over months.
#
# Usage: ./scripts/backup-prune.sh <backup-dir>
#
# Expects filenames of the form arr-stack-backup-YYYYMMDD-HHMMSS.tar.gz
# (optionally .gpg-suffixed). Files without a recognizable timestamp are
# left untouched and reported, never guessed at.

DIR="${1:?Usage: backup-prune.sh <backup-dir>}"
[ -d "$DIR" ] || { echo "ERROR: not a directory: $DIR" >&2; exit 1; }

NOW=$(date +%s)

declare -A keep_day
declare -A keep_week
declare -A keep_month
month_kept=0
MONTHLY_CAP=12

# Newest-first so the first file seen per bucket key is the one kept.
mapfile -t FILES < <(find "$DIR" -maxdepth 1 -type f -name 'arr-stack-backup-*.tar.gz*' | sort -r)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "backup-prune: no arr-stack-backup-*.tar.gz files found in $DIR"
  exit 0
fi

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  ts=$(echo "$base" | grep -oE '[0-9]{8}-[0-9]{6}' || true)
  if [ -z "$ts" ]; then
    echo "backup-prune: skip (no recognizable timestamp): $base"
    continue
  fi

  date_part="${ts%%-*}"
  epoch=$(date -d "${date_part}" +%s 2>/dev/null) || {
    echo "backup-prune: skip (unparseable date): $base"
    continue
  }
  age_days=$(( (NOW - epoch) / 86400 ))

  if [ "$age_days" -le 7 ]; then
    continue # keep - within the always-keep window
  elif [ "$age_days" -le 30 ]; then
    key="$date_part"
    if [ -n "${keep_day[$key]:-}" ]; then
      rm -f "$f"; echo "backup-prune: pruned (daily tier, superseded): $base"
    else
      keep_day[$key]=1
    fi
  elif [ "$age_days" -le 180 ]; then
    key=$(date -d "${date_part}" +%G-W%V)
    if [ -n "${keep_week[$key]:-}" ]; then
      rm -f "$f"; echo "backup-prune: pruned (weekly tier, superseded): $base"
    else
      keep_week[$key]=1
    fi
  else
    key=$(date -d "${date_part}" +%Y-%m)
    if [ -n "${keep_month[$key]:-}" ]; then
      rm -f "$f"; echo "backup-prune: pruned (monthly tier, superseded): $base"
    elif [ "$month_kept" -ge "$MONTHLY_CAP" ]; then
      rm -f "$f"; echo "backup-prune: pruned (monthly cap of $MONTHLY_CAP reached): $base"
    else
      keep_month[$key]=1
      month_kept=$((month_kept + 1))
    fi
  fi
done

REMAINING=$(find "$DIR" -maxdepth 1 -type f -name 'arr-stack-backup-*.tar.gz*' | wc -l | tr -d ' ')
echo "backup-prune: done, $REMAINING backup(s) retained in $DIR"
