#!/usr/bin/env bats
# Unit tests for scripts/check-playback-formats.sh: the weekly check that
# reads Sonarr's and Radarr's mediainfo for files the Jellyfin Android TV
# client can't play, and posts one panel-only notice to Home Assistant.
#
# Modelled on November 2026: a Netflix episode in Dolby Vision Profile 5
# (mediainfo "DV", green and magenta on a Fire TV), a film in Profile 5, and
# X-Men: The Last Stand as a DTS-HD MA 6.1 remux, which stopped at 0 ms. Around
# them sit files that must be left alone: Dolby Vision 8.1, HDR10 with
# DTS-HD MA 5.1 and 7.1, TrueHD Atmos, and files with no mediainfo.
#
# `docker` and `curl` are stubbed on PATH, and the script runs from a copy in a
# throwaway stack directory with no .env. The curl stub serves each API call
# from a fixture and logs every call, with its body, to $CURL_LOG.

setup() {
    load helpers/setup
    command -v python3 >/dev/null || skip "python3 not installed"
    unset HA_WEBHOOK_URL

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts"
    cp "$REPO_ROOT/scripts/check-playback-formats.sh" "$STACK/scripts/check-playback-formats.sh"

    export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export HA_NOTICE="$BATS_TEST_TMPDIR/notice.json"
    export FIX="$BATS_TEST_TMPDIR/fixtures"
    export STUB_CONTAINERS="sonarr radarr"
    mkdir -p "$FIX"
    : > "$CURL_LOG"

    python3 - "$FIX" <<'PY'
import json, sys
fix = sys.argv[1]
def dump(name, obj): json.dump(obj, open(f"{fix}/{name}.json", "w"))
def media(rng, codec, channels):
    return {"videoDynamicRangeType": rng, "audioCodec": codec, "audioChannels": channels}
dump("sonarr-series", [
    {"id": 1, "title": "The Beast in Me", "sortTitle": "beast in me", "statistics": {"episodeFileCount": 3}},
    {"id": 2, "title": "Fine Show", "sortTitle": "fine show", "statistics": {"episodeFileCount": 2}},
    {"id": 3, "title": "Nothing Yet", "sortTitle": "nothing yet", "statistics": {"episodeFileCount": 0}},
])
dump("sonarr-episodefile-1", [
    {"id": 11, "seasonNumber": 1, "sceneName": "The.Beast.in.Me.S01E01.Sick.Puppy.2160p.NF.WEB-DL.DDP.5.1.Atmos.H.265-CHDWEB",
     "mediaInfo": media("DV", "EAC3 Atmos", 5.1)},
    {"id": 12, "seasonNumber": 1, "sceneName": "The.Beast.in.Me.S01E02.2160p.NF.WEB-DL.Hybrid.DV.HDR.DDP.Atmos.5.1-HONE",
     "mediaInfo": media("DV HDR10", "EAC3 Atmos", 5.1)},
    {"id": 13, "seasonNumber": 1, "sceneName": "The.Beast.in.Me.S01E03.BluRay.1080p.DTS-HD.MA.6.1.x264-GRP",
     "mediaInfo": media("", "DTS-HD MA", 6.1)},
])
dump("sonarr-episode-1", [
    {"id": 101, "seriesId": 1, "seasonNumber": 1, "episodeNumber": 1, "episodeFileId": 11},
    {"id": 102, "seriesId": 1, "seasonNumber": 1, "episodeNumber": 2, "episodeFileId": 12},
    {"id": 103, "seriesId": 1, "seasonNumber": 1, "episodeNumber": 3, "episodeFileId": 13},
])
dump("sonarr-episodefile-2", [
    {"id": 21, "seasonNumber": 1, "sceneName": "Fine.Show.S01E01.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.HDR10P.H.265-FLUX",
     "mediaInfo": media("DV HDR10Plus", "EAC3 Atmos", 5.1)},
    {"id": 22, "seasonNumber": 1, "sceneName": "Fine.Show.S01E02.1080p.WEB.h264-GRP"},
])
def movie(i, title, year, scene=None, m=None, has_file=True):
    mv = {"id": i, "title": title, "sortTitle": title.lower(), "year": year, "hasFile": has_file}
    if has_file:
        mv["movieFile"] = {"id": i * 10, "sceneName": scene, "relativePath": f"{title} ({year}).mkv"}
        if m:
            mv["movieFile"]["mediaInfo"] = m
    return mv
dump("radarr-movies", [
    movie(31, "X-Men: The Last Stand", 2006,
          "X-Men.The.Last.Stand.2006.UHD.BluRay.2160p.DTS-HD.MA.6.1.HEVC.REMUX-FraMeSToR", media("HDR10", "DTS-HD MA", 6.1)),
    movie(32, "Profile Five Film", 2024, "Profile.Five.Film.2024.2160p.MAX.WEB-DL.DDP5.1.DoVi.H.265-NTb",
          media("DV", "EAC3", 5.1)),
    movie(33, "Coraline", 2009, "Coraline.2009.2160p.UHD.BluRay.DV.REMUX.HDR10.HEVC.TrueHD.7.1.Atmos-UnKn0wn",
          media("DV HDR10", "TrueHD Atmos", 7.1)),
    movie(34, "X-Men", 2000, "X-Men.2000.2160p.BluRay.Remux.HDR.HEVC.DTS-HD.MA-SGF", media("HDR10", "DTS-HD MA", 5.1)),
    movie(35, "Lincoln", 2012, "Lincoln.2012.1080p.BluRay.DTS-HD.MA.7.1.x264-GRP", media("", "DTS-HD MA", 7.1)),
    movie(36, "No Media Yet", 2026, "No.Media.Yet.2026.1080p.WEB.h264-GRP"),
    movie(37, "Not Downloaded", 2026, has_file=False),
])
PY

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/docker" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "ps "*) tr ' ' '\n' <<< "$STUB_CONTAINERS" ;;
  exec\ *) printf '<Config>\n  <Port>8989</Port>\n  <ApiKey>key-%s</ApiKey>\n</Config>\n' "$2" ;;
  *) exit 1 ;;
esac
STUB
    cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
method=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d|--data-binary) data="$2"; shift 2 ;;
    -H|-m) shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
printf '%s %s %s\n' "$method" "$url" "$data" >> "$CURL_LOG"
serve() { [ -f "$FIX/$1.json" ] && cat "$FIX/$1.json" || exit 22; }
serve_or_empty() { [ -f "$FIX/$1.json" ] && cat "$FIX/$1.json" || echo '[]'; }
case "$method $url" in
  "GET http://localhost:8989/api/v3/series") serve sonarr-series ;;
  "GET http://localhost:8989/api/v3/episodefile?seriesId="*) serve_or_empty "sonarr-episodefile-${url##*=}" ;;
  "GET http://localhost:8989/api/v3/episode?seriesId="*) serve_or_empty "sonarr-episode-${url##*=}" ;;
  "GET http://localhost:7878/api/v3/movie") serve radarr-movies ;;
  "POST http://localhost:8989/api/v3/command"|"POST http://localhost:7878/api/v3/command") echo '{"id": 1}' ;;
  "POST http://ha.test/"*) printf '%s' "$data" > "$HA_NOTICE" ;;
  *) exit 22 ;;
esac
STUB
    chmod +x "$STUB_BIN/docker" "$STUB_BIN/curl"
    export PATH="$STUB_BIN:$PATH"
}

# The value of one key in the notice the script posted to Home Assistant.
notice() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$HA_NOTICE" "$1"
}

ha_posts() {
    grep -c '^POST http://ha.test' "$CURL_LOG" || true
}

commands() {
    grep '^POST http://localhost:[0-9]*/api/v3/command' "$CURL_LOG" || true
}

# Every file in the fixtures plays, so nothing is reported.
make_library_clean() {
    python3 - "$FIX" <<'PY'
import json, sys
fix = sys.argv[1]
for name in ("sonarr-episodefile-1", "radarr-movies"):
    data = json.load(open(f"{fix}/{name}.json"))
    for item in data:
        media = item.get("mediaInfo") or (item.get("movieFile") or {}).get("mediaInfo")
        if media:
            media["videoDynamicRangeType"] = "DV HDR10" if "DV" in media["videoDynamicRangeType"] else media["videoDynamicRangeType"]
            if media["audioChannels"] == 6.1:
                media["audioChannels"] = 5.1
    json.dump(data, open(f"{fix}/{name}.json", "w"))
PY
}

@test "a dry run names each file and its problem, and changes nothing" {
    run "$STACK/scripts/check-playback-formats.sh"
    assert_success
    assert_output --partial "Mode: DRY RUN"
    assert_output --partial "⚠ The Beast in Me S01E01: Dolby Vision Profile 5 (The.Beast.in.Me.S01E01.Sick.Puppy.2160p.NF.WEB-DL"
    assert_output --partial "⚠ The Beast in Me S01E03: DTS 6.1"
    assert_output --partial "⚠ X-Men: The Last Stand (2006): DTS 6.1"
    assert_output --partial "⚠ Profile Five Film (2024): Dolby Vision Profile 5"
    assert_output --partial "Summary: 4 files to replace"
    assert_output --partial "Notice: would post (dry run; use --post):"
    assert_output --partial "Unplayable files: 4 files to replace"
    [ -z "$(commands)" ]
    [ "$(ha_posts)" -eq 0 ]
}

@test "Dolby Vision 8.1, HDR10+, TrueHD and DTS 5.1 and 7.1 are left alone" {
    run "$STACK/scripts/check-playback-formats.sh"
    assert_success
    refute_output --partial "S01E02:"
    refute_output --partial "Fine Show"
    refute_output --partial "Coraline"
    refute_output --partial "X-Men (2000)"
    refute_output --partial "Lincoln"
}

@test "files with no mediainfo are counted, not judged" {
    run "$STACK/scripts/check-playback-formats.sh"
    assert_success
    assert_output --partial "4 files judged, 2 to replace; 1 with no mediainfo, not judged"
    assert_output --partial "5 files judged, 2 to replace; 1 with no mediainfo, not judged"
    refute_output --partial "No Media Yet"
    refute_output --partial "Not Downloaded"
}

@test "a series with no files is never fetched" {
    run "$STACK/scripts/check-playback-formats.sh"
    assert_success
    run grep -c 'episodefile?seriesId=3' "$CURL_LOG"
    assert_output "0"
}

@test "--apply queues a search for each Profile 5 file, and none for DTS 6.1" {
    # A Profile 5 file scores -1000 on the DV (Profile 5) format through its
    # [DV] name, so the app's own search takes any release without it. The
    # DTS 6.1 format reads titles only, so a search there would take nothing.
    run "$STACK/scripts/check-playback-formats.sh" --apply
    assert_success
    assert_output --partial "Searches queued: 2 (The Beast in Me S01E01, Profile Five Film (2024))"
    run commands
    assert_line --partial 'POST http://localhost:8989/api/v3/command {"name": "EpisodeSearch", "episodeIds": [101]}'
    assert_line --partial 'POST http://localhost:7878/api/v3/command {"name": "MoviesSearch", "movieIds": [32]}'
    [ "$(commands | wc -l | tr -d ' ')" -eq 2 ]
}

@test "--post sends one panel-only notice with a fixed tag, and says what to do" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    run "$STACK/scripts/check-playback-formats.sh" --post --apply
    assert_success
    assert_output --partial "Notice: posted to Home Assistant at"
    [ "$(ha_posts)" -eq 1 ]
    [ "$(notice level)" = info ]
    [ "$(notice tag)" = playback-formats ]
    [ "$(notice title)" = "Unplayable files: 4 files to replace" ]
    run notice message
    assert_output --partial "• The Beast in Me S01E01 (Sonarr): Dolby Vision Profile 5: no HDR10 fallback, so the picture is green and magenta. Search queued"
    assert_output --partial "• X-Men: The Last Stand (2006) (Radarr): DTS 6.1: the Jellyfin client on a Fire TV stops at once. Replace it by hand"
}

@test "with nothing to replace, --post posts nothing" {
    make_library_clean
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    run "$STACK/scripts/check-playback-formats.sh" --post --apply
    assert_success
    assert_output --partial "Summary: 0 files to replace"
    assert_output --partial "Notice: nothing to post"
    [ "$(ha_posts)" -eq 0 ]
    [ -z "$(commands)" ]
}

@test "--test posts a test notice even when nothing is found" {
    make_library_clean
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    run "$STACK/scripts/check-playback-formats.sh" --test
    assert_success
    [ "$(ha_posts)" -eq 1 ]
    [ "$(notice title)" = "Playback-format check: test" ]
    run notice message
    assert_output --partial "can reach Home Assistant. Nothing to do. (This run found 0 files to replace.)"
}

@test "only Radarr running: films are still checked" {
    export STUB_CONTAINERS="radarr"
    run "$STACK/scripts/check-playback-formats.sh"
    assert_success
    refute_output --partial "--- Sonarr ---"
    assert_output --partial "Summary: 2 files to replace"
}

@test "--post without a webhook fails before any API call" {
    run "$STACK/scripts/check-playback-formats.sh" --post
    assert_failure
    assert_output --partial "--post needs HA_WEBHOOK_URL"
    [ ! -s "$CURL_LOG" ]
}
