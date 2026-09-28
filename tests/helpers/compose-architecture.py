#!/usr/bin/env python3
"""Architecture checks on the RENDERED compose model, for tests/compose-validation.bats.

⚠️  This script was generated with LLM assistance and human-reviewed.
    Read and understand it before running. Do not execute scripts you
    don't understand on your system. It only runs `docker compose config`,
    which reads files and starts nothing, and prints what it finds.

Usage:
    compose-architecture.py clients      --env-file ENV FILE...
    compose-architecture.py project-name --env-file ENV --expect FILE=NAME... FILE...
    compose-architecture.py network      --env-file ENV --subnet CIDR
                                         --ip-range CIDR --gateway IP FILE...

Each FILE is rendered on its own with
    docker compose -f FILE --env-file ENV --profile '*' config --format json
and the checks read that JSON. The YAML text is the wrong thing to read:
anchors, merge keys (`<<: *x`) and variables hide what a service really
gets, and a service behind a `profiles:` entry is missing from any render
that does not ask for every profile.

Output is one line per finding:
    OK   <file>: ...    checked and right
    FAIL <file>: ...    a rule is broken
Exit 0 when nothing failed, 1 when a rule is broken, 2 when a file could
not be rendered or the arguments are wrong: a file that cannot be rendered
is never a pass. Each check also FAILs when it finds nothing to check, so
an empty input cannot look like a clean one.

THE RULES

clients: every BitTorrent/Usenet download client runs inside gluetun's
  network namespace (network_mode service:gluetun or container:gluetun),
  so its traffic can only leave through the VPN. A client is recognised by
  service name (the ones this stack ships) or by image, so a client added
  under a new name is still caught. Image matching uses whole tokens of the
  repository basename, and a sidecar token (exporter, ...) disqualifies it:
  sabnzbd-exporter reads SABnzbd's API over the bridge and carries no
  download traffic.

project-name: every file pins a top-level `name:` and it is the one the
  caller expects. The rendered model always HAS a name: without the key,
  compose takes it from the project directory, and the documented deploy
  directory is /volume1/docker/arr-stack, so a file that lost its pin still
  renders `arr-stack` there. This check renders against an empty directory
  whose name no file would pin, so a missing pin shows up as that name
  wherever the checkout lives. COMPOSE_PROJECT_NAME (and the other COMPOSE_*
  overrides) are removed from compose's environment, since they beat the key.

network: the network named NAME (default arr-stack) is defined, by at least
  one file that does not declare it external, with exactly the given subnet,
  dynamic ip_range and gateway; and every static ipv4_address on it lies in
  the subnet but outside the ip_range, where Docker never hands addresses
  out dynamically (CLAUDE.md, "Cross-Stack": gluetun's reserved 172.20.0.3).
"""

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile

GLUETUN_MODES = ("service:gluetun", "container:gluetun")

# The clients this stack ships, matched by service name. This catches one
# whose image was swapped for something the token list below does not know.
NAMED_CLIENTS = frozenset({"qbittorrent", "sabnzbd"})

# Whole tokens of an image's repository basename that mark a download client:
# linuxserver/qbittorrent, qbittorrentofficial/qbittorrent-nox,
# crazymax/rtorrent-rutorrent. Whole tokens only, so qbit_manage (which just
# talks to qBittorrent's API) is not one.
CLIENT_IMAGE_TOKENS = frozenset({
    "qbittorrent", "transmission", "deluge", "rtorrent", "rutorrent",
    "aria2", "sabnzbd", "nzbget",
})

# Tokens that mark a sidecar built around a client rather than the client.
SIDECAR_IMAGE_TOKENS = frozenset({"exporter", "prometheus", "metrics"})

# Environment that would override what the files say.
OVERRIDING_ENV = ("COMPOSE_PROJECT_NAME", "COMPOSE_PROFILES", "COMPOSE_FILE",
                  "COMPOSE_ENV_FILES")

# The project directory used by the project-name check. No compose file here
# pins this name, so seeing it means compose fell back to the directory.
UNPINNED_SENTINEL = "no-project-name-pinned"


class RenderError(Exception):
    pass


def render(path, env_file, project_dir=None):
    """Return the compose model for one file, as `docker compose config` sees it."""
    env = {k: v for k, v in os.environ.items() if k not in OVERRIDING_ENV}
    cmd = ["docker", "compose"]
    if project_dir:
        cmd += ["--project-directory", project_dir]
    cmd += ["-f", path, "--env-file", env_file, "--profile", "*",
            "config", "--format", "json"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env,
                              check=False)
    except OSError as exc:
        raise RenderError("cannot run docker compose: %s" % exc)
    if proc.returncode != 0:
        raise RenderError("%s: docker compose config failed (exit %d): %s"
                          % (path, proc.returncode, proc.stderr.strip()))
    try:
        model = json.loads(proc.stdout)
    except ValueError as exc:
        raise RenderError("%s: docker compose config printed no JSON: %s"
                          % (path, exc))
    if not isinstance(model, dict):
        raise RenderError("%s: rendered model is not an object" % path)
    return model


def label(path):
    return os.path.basename(path)


def image_tokens(image):
    ref = image.split("@", 1)[0]        # drop a digest
    base = ref.rsplit("/", 1)[-1]       # repository basename; a registry:port stays in the prefix
    base = base.split(":", 1)[0]        # drop the tag
    return {t for t in re.split(r"[-_.]", base.lower()) if t}


def client_match(name, image):
    """How a service was recognised as a download client, or [] if it is not one."""
    how = []
    if name in NAMED_CLIENTS:
        how.append("name")
    tokens = image_tokens(image or "")
    if tokens & CLIENT_IMAGE_TOKENS and not tokens & SIDECAR_IMAGE_TOKENS:
        how.append("image")
    return how


def check_clients(files, env_file):
    failures = found = 0
    for path in files:
        services = render(path, env_file).get("services") or {}
        for name in sorted(services):
            svc = services[name] or {}
            how = client_match(name, svc.get("image"))
            if not how:
                continue
            found += 1
            mode = svc.get("network_mode")
            detail = "image %s, matched by %s" % (svc.get("image") or "(none)",
                                                   " and ".join(how))
            if svc.get("profiles"):
                detail += ", profiles: %s" % ",".join(svc["profiles"])
            if mode in GLUETUN_MODES:
                print("OK   %s: download client '%s' runs in gluetun's network "
                      "namespace (%s; %s)" % (label(path), name, mode, detail))
            else:
                failures += 1
                shown = "'%s'" % mode if mode else "not set"
                print("FAIL %s: download client '%s' is outside gluetun's network "
                      "namespace: network_mode is %s, want service:gluetun or "
                      "container:gluetun (%s)" % (label(path), name, shown, detail))
    if not found:
        failures += 1
        print("FAIL no download client found in any file, so nothing was checked")
    return failures


def check_project_names(files, env_file, expected):
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        sentinel_dir = os.path.join(tmp, UNPINNED_SENTINEL)
        os.mkdir(sentinel_dir)
        for path in files:
            name = render(path, env_file, project_dir=sentinel_dir).get("name")
            want = expected.get(label(path))
            if not name or name == UNPINNED_SENTINEL:
                failures += 1
                print("FAIL %s: no top-level project `name:`, so compose takes "
                      "the name from the deploy directory" % label(path))
            elif want is None:
                failures += 1
                print("FAIL %s: pins project name '%s' but no expected name is "
                      "recorded for this file" % (label(path), name))
            elif name != want:
                failures += 1
                print("FAIL %s: project name is '%s', expected '%s'"
                      % (label(path), name, want))
            else:
                print("OK   %s: pins project name '%s'" % (label(path), name))
    return failures


def check_network(files, env_file, net_name, want):
    subnet = ipaddress.ip_network(want["subnet"])
    dynamic = ipaddress.ip_network(want["ip_range"])
    failures = defined = 0
    for path in files:
        model = render(path, env_file)
        networks = model.get("networks") or {}
        keys = [k for k, n in networks.items() if (n or {}).get("name") == net_name]
        for key in keys:
            net = networks[key]
            if net.get("external"):
                continue
            defined += 1
            configs = (net.get("ipam") or {}).get("config") or []
            if len(configs) != 1:
                failures += 1
                print("FAIL %s: the %s network has %d ipam config entries, "
                      "expected exactly 1" % (label(path), net_name, len(configs)))
                continue
            bad = 0
            for field in ("subnet", "ip_range", "gateway"):
                got = configs[0].get(field)
                if got is None:
                    bad += 1
                    print("FAIL %s: the %s network's %s is missing, expected '%s'"
                          % (label(path), net_name, field, want[field]))
                elif got != want[field]:
                    bad += 1
                    print("FAIL %s: the %s network's %s is '%s', expected '%s'"
                          % (label(path), net_name, field, got, want[field]))
            failures += bad
            if not bad:
                print("OK   %s: the %s network is pinned (subnet %s, ip_range %s, "
                      "gateway %s)" % (label(path), net_name, want["subnet"],
                                       want["ip_range"], want["gateway"]))
        services = model.get("services") or {}
        for sname in sorted(services):
            attached = (services[sname] or {}).get("networks") or {}
            for key in keys:
                ip = (attached.get(key) or {}).get("ipv4_address")
                if not ip:
                    continue
                addr = ipaddress.ip_address(ip)
                if addr not in subnet:
                    failures += 1
                    print("FAIL %s: service '%s' has static IP %s, outside the %s "
                          "subnet %s" % (label(path), sname, ip, net_name, subnet))
                elif addr in dynamic:
                    failures += 1
                    print("FAIL %s: service '%s' has static IP %s inside the dynamic "
                          "ip_range %s, where Docker can hand it to another "
                          "container first" % (label(path), sname, ip, dynamic))
                else:
                    print("OK   %s: service '%s' has static IP %s, outside the "
                          "dynamic ip_range" % (label(path), sname, ip))
    if not defined:
        failures += 1
        print("FAIL no file defines the %s network (only external references), "
              "so nothing was checked" % net_name)
    return failures


def parse_expect(values):
    expected = {}
    for item in values:
        fname, sep, name = item.partition("=")
        if not sep or not fname or not name:
            raise ValueError("--expect wants FILE=NAME, got %r" % item)
        expected[fname] = name
    return expected


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="check")
    sub.required = True

    p = sub.add_parser("clients")
    p.add_argument("--env-file", required=True)
    p.add_argument("files", nargs="+")

    p = sub.add_parser("project-name")
    p.add_argument("--env-file", required=True)
    p.add_argument("--expect", action="append", default=[], metavar="FILE=NAME")
    p.add_argument("files", nargs="+")

    p = sub.add_parser("network")
    p.add_argument("--env-file", required=True)
    p.add_argument("--name", default="arr-stack")
    p.add_argument("--subnet", required=True)
    p.add_argument("--ip-range", required=True)
    p.add_argument("--gateway", required=True)
    p.add_argument("files", nargs="+")

    args = parser.parse_args(argv)
    try:
        if args.check == "clients":
            failures = check_clients(args.files, args.env_file)
        elif args.check == "project-name":
            failures = check_project_names(args.files, args.env_file,
                                           parse_expect(args.expect))
        else:
            want = {"subnet": args.subnet, "ip_range": args.ip_range,
                    "gateway": args.gateway}
            failures = check_network(args.files, args.env_file, args.name, want)
    except (RenderError, ValueError) as exc:
        sys.stdout.flush()
        print("ERROR %s" % exc, file=sys.stderr)
        return 2
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
