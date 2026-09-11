#!/usr/bin/env python3
"""Decide what configure-apps.sh must do to Bazarr's subtitle languages.

⚠️  This script was generated with LLM assistance and human-reviewed.
    Read and understand it before running. Do not execute scripts you
    don't understand on your system. It computes a plan and prints it;
    it never talks to Bazarr itself.

Usage:
    bazarr-language-plan.py PROFILES_JSON LANGUAGES_JSON "en fr" "English"

PROFILES_JSON is the body of GET /api/system/languages/profiles and
LANGUAGES_JSON the body of GET /api/system/languages. The third argument is
the space-separated list of language codes the managed profile must contain
(and nothing else); the fourth is the name to give it when creating.

Prints ONE line of JSON:
    {"action": "CREATE" | "UPDATE" | "MATCH",
     "profile_id": <int>, "name": <str>,
     "send_profiles": <bool>,   # the managed profile was created or its languages changed
     "send_ticks": <bool>,      # the Languages Filter must change
     "enabled": [<code>, ...],  # what the Languages Filter should hold
     "summary": <str>,          # e.g. "languages +fr, ticks -lv" — for the run output
     "profiles": [...]}         # the full list, to POST as languages-profiles
Exits non-zero, printing nothing, if either body is not the list Bazarr
returns on a 2xx, or the wanted-language list is empty — the caller treats
that as "could not plan", never as "already configured".

WHICH PROFILE IS MANAGED

Exactly one: the profile whose name is PROFILE_NAME; failing that, any
profile whose languages are exactly the wanted set (so a hand-made profile
called something else is adopted rather than duplicated); failing that, a
new one with the next free id — max(profileId) + 1, the same rule Bazarr's
UI uses, which is why a hard-coded id 1 was wrong: delete a profile and
that id never comes back.

The managed profile's languages are made EXACTLY the wanted set: a stray
is removed, a missing one added. Every other profile is left alone. An
earlier version pruned every profile down to the wanted languages, which
turned a user's French profile into one that searched for nothing.

THE TWO KEY SPACES

`languages-profiles` is authoritative: Bazarr inserts unknown ids, updates
known ones, and DELETES any existing id missing from the list — so the
full list is always sent back, and it is only sent when a profile actually
changed, because Bazarr rescans the whole library inside that write.
`languages-enabled` (the Languages Filter ticks) zeroes every language and
then enables the listed ones, so the list is: the wanted languages plus
every language any OTHER profile uses. A tick nothing uses is dropped —
that is how a stray Latvian tick is cleared — and a tick another profile
depends on is never dropped.
"""
import json
import sys


def codes(profile):
    return {item["language"] for item in profile.get("items", [])}


def describe(added, removed, tick_add, tick_remove):
    parts = []
    if added or removed:
        parts.append("languages " + " ".join(["+" + c for c in added] + ["-" + c for c in removed]))
    if tick_add or tick_remove:
        parts.append("ticks " + " ".join(["+" + c for c in tick_add] + ["-" + c for c in tick_remove]))
    return ", ".join(parts)


def main(argv):
    try:
        profiles = json.loads(argv[1])
        languages = json.loads(argv[2])
        want = argv[3].split()
        name = argv[4]
    except (IndexError, ValueError):
        return 1
    if not isinstance(profiles, list) or not isinstance(languages, list) or not want:
        return 1
    wanted = set(want)

    managed = next((p for p in profiles if p.get("name") == name), None)
    if managed is None:
        managed = next((p for p in profiles if codes(p) == wanted), None)

    action = "UPDATE"
    if managed is None:
        next_pid = 1 + max((int(p["profileId"]) for p in profiles), default=0)
        managed = {
            "profileId": next_pid, "name": name, "cutoff": None, "items": [],
            "mustContain": [], "mustNotContain": [], "originalFormat": 0, "tag": None,
        }
        profiles.append(managed)
        action = "CREATE"

    have = codes(managed)
    added = [c for c in want if c not in have]
    removed = sorted(have - wanted)

    # Keep the existing rows for wanted languages (their hi/forced flags are
    # the user's), drop the strays, append the missing with fresh item ids.
    items = [i for i in managed.get("items", []) if i["language"] in wanted]
    next_item = 1 + max((int(i.get("id", 0)) for i in items), default=0)
    for code in added:
        items.append({
            "id": next_item, "language": code, "audio_exclude": "False",
            "audio_only_include": "False", "hi": "False", "forced": "False",
        })
        next_item += 1
    managed["items"] = items

    enabled = set(wanted)
    for p in profiles:
        if p is not managed:
            enabled |= codes(p)
    current = {lang["code2"] for lang in languages if lang.get("enabled")}
    tick_add = sorted(enabled - current)
    tick_remove = sorted(current - enabled)

    send_profiles = action == "CREATE" or bool(added or removed)
    send_ticks = bool(tick_add or tick_remove)
    if action == "UPDATE" and not (send_profiles or send_ticks):
        action = "MATCH"

    print(json.dumps({
        "action": action,
        "profile_id": int(managed["profileId"]),
        "name": managed["name"],
        "send_profiles": send_profiles,
        "send_ticks": send_ticks,
        "enabled": sorted(enabled),
        "summary": describe(added, removed, tick_add, tick_remove),
        "profiles": profiles,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
