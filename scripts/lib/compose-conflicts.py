#!/usr/bin/env python3
"""Host-port and static-IP clashes across the compose files, for check-conflicts.sh.

⚠️  This script was generated with LLM assistance and human-reviewed.
    Read and understand it before running. Do not execute scripts you
    don't understand on your system. It only runs `docker compose config`,
    which reads files and starts nothing, and prints what it finds.

Usage:
    compose-conflicts.py [--env-file ENV] FILE...

Each FILE is rendered on its own with
    docker compose -f FILE [--env-file ENV] --profile '*' config --format json
and the checks read that JSON, never the YAML text. The text hid most of
the ports: the old regex wanted `- "HOST:CONTAINER"` and nothing after it,
so a trailing comment, a `/udp` suffix, a host-IP prefix, the long syntax
or a merge key (`<<: *x`) kept a line out of the check, and 3 of the 18
published ports were all it saw. Rendering every profile also brings in
services that only start on demand.

The files are separate compose projects, but they run on one host, and
several of them join the one `arr-stack` network, so each file is checked
against every other as well as against itself.

WHAT CLASHES

Host ports: every services.*.ports entry with a published side binds
  (host_ip, published, protocol). Two bindings clash when the port and the
  protocol match and the host IPs are equal or either is a wildcard (none,
  0.0.0.0 or ::): Docker then fails with "port is already allocated". tcp
  and udp on one port do not clash (Pi-hole's 53). A published range counts
  as every port in it. An entry with no published side gets an ephemeral
  port and cannot clash.

Shared network namespaces: a service with network_mode service:X or
  container:X has no ports of its own. X publishes them, as gluetun does for
  qBittorrent, SABnzbd, Prowlarr and FlareSolverr, so the clash is reported
  against X and names the services behind it. A ports: entry on the sharing
  service itself is an error: Docker refuses to create that container
  ("conflicting options: port publishing and the container sharing network
  namespace").

Host network: network_mode host binds straight onto the host, so what such
  a service listens on is not in the model at all. Those services are
  listed in a NOTE, never counted as checked.

Static IPs: services.*.networks.*.ipv4_address, keyed by the network's real
  name (networks.<key>.name), because arr-stack is one network that several
  files join under the same name. Two services with one address on one
  network clash; the same address on two different networks does not.

OUTPUT

Lines in the pre-commit hook's style, indented four spaces:
    ERROR: ...   a clash, or a file that could not be rendered
    NOTE: ...    something this check cannot see
    OK: ...      nothing clashed, with how many ports and IPs were checked
Exit 0 when nothing clashed, 1 on a clash, 2 when a file could not be
rendered or the arguments are wrong. A file that cannot be rendered is
never a pass: its ports were not looked at.
"""

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict

# Environment that would override what the files say. COMPOSE_PROJECT_NAME
# in particular renames every project-local network, which would merge
# networks from separate files into one.
OVERRIDING_ENV = ("COMPOSE_PROJECT_NAME", "COMPOSE_PROFILES", "COMPOSE_FILE",
                  "COMPOSE_ENV_FILES")

WILDCARDS = ("", "0.0.0.0", "::")


class RenderError(Exception):
    pass


def render(path, env_file):
    """Return the compose model for one file, as `docker compose config` sees it."""
    env = {k: v for k, v in os.environ.items() if k not in OVERRIDING_ENV}
    cmd = ["docker", "compose", "-f", path]
    if env_file:
        cmd += ["--env-file", env_file]
    cmd += ["--profile", "*", "config", "--format", "json"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env,
                              check=False)
    except OSError as exc:
        raise RenderError("cannot run docker compose: %s" % exc)
    if proc.returncode != 0:
        raise RenderError(proc.stderr.strip() or "exit %d" % proc.returncode)
    try:
        model = json.loads(proc.stdout)
    except ValueError as exc:
        raise RenderError("docker compose config printed no JSON: %s" % exc)
    if not isinstance(model, dict):
        raise RenderError("the rendered model is not an object")
    return model


def published_ports(published):
    """'8080' -> [8080]; '8000-8002' -> [8000, 8001, 8002]; '' -> []."""
    text = str(published or "").strip()
    if not text:
        return []
    low, _, high = text.partition("-")
    low = int(low)
    return list(range(low, int(high) + 1)) if high else [low]


def is_wildcard(host_ip):
    return host_ip in WILDCARDS


def clash(a, b):
    return a["ip"] == b["ip"] or is_wildcard(a["ip"]) or is_wildcard(b["ip"])


def describe(binding):
    """gluetun 8085->8085/tcp (for qbittorrent), pihole 192.168.1.100:53->53/udp."""
    ip = binding["ip"]
    if is_wildcard(ip) and ip != "0.0.0.0":
        host = ""                      # compose's default: every address
    elif ":" in ip:
        host = "[%s]:" % ip
    else:
        host = "%s:" % ip
    text = "%s %s%d->%s/%s" % (binding["service"], host, binding["port"],
                               binding["target"], binding["proto"])
    if binding["behind"]:
        text += " (for %s)" % ", ".join(binding["behind"])
    return text


def namespace_owner(mode):
    """'service:gluetun' -> ('service', 'gluetun'); anything else -> None."""
    kind, _, name = (mode or "").partition(":")
    if kind in ("service", "container") and name:
        return kind, name
    return None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--env-file")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args(argv)

    models = []                        # (label, model)
    unrendered = 0
    for path in args.files:
        label = os.path.basename(path)
        try:
            models.append((label, render(path, args.env_file)))
        except RenderError as exc:
            unrendered += 1
            print("    ERROR: %s could not be rendered by docker compose config,"
                  " so its ports and IPs were not checked:" % label)
            for line in str(exc).splitlines()[:4]:
                print("        %s" % line)

    # Who shares whose namespace. service:X names a service in the same file;
    # container:X names a container, which may belong to another file.
    by_container = {}
    for label, model in models:
        for name, svc in (model.get("services") or {}).items():
            by_container[(svc or {}).get("container_name") or name] = (label, name)
    behind = defaultdict(list)         # (label, owner service) -> [sharing services]
    for label, model in models:
        for name, svc in (model.get("services") or {}).items():
            owner = namespace_owner((svc or {}).get("network_mode"))
            if owner is None:
                continue
            kind, target = owner
            key = (label, target) if kind == "service" else by_container.get(target)
            if key:
                behind[key].append(name)

    errors = 0
    bindings = defaultdict(list)       # (port, proto) -> [binding]
    ips = defaultdict(list)            # (network name, ip) -> [(label, service)]
    host_net = []
    n_bindings = n_ips = 0

    for label, model in models:
        networks = model.get("networks") or {}
        project = model.get("name") or ""
        for name in sorted(model.get("services") or {}):
            svc = model["services"][name] or {}
            mode = svc.get("network_mode") or ""
            ports = svc.get("ports") or []

            if namespace_owner(mode):
                if ports:
                    errors += 1
                    owner = namespace_owner(mode)[1]
                    print("    ERROR: Ports on a service that shares another's network in %s:" % label)
                    print("      - %s has network_mode: %s, so Docker refuses to publish"
                          " ports on it. Publish them on %s instead." % (name, mode, owner))
                continue
            if mode == "host":
                host_net.append("%s (%s)" % (name, label))
                continue

            for p in ports:
                try:
                    published = published_ports(p.get("published"))
                except ValueError:
                    errors += 1
                    print("    ERROR: Unreadable published port in %s:" % label)
                    print("      - %s publishes %r" % (name, p.get("published")))
                    continue
                for port in published:
                    bindings[(port, p.get("protocol") or "tcp")].append({
                        "file": label, "service": name,
                        "ip": p.get("host_ip") or "", "port": port,
                        "target": p.get("target"), "proto": p.get("protocol") or "tcp",
                        "behind": sorted(behind.get((label, name), [])),
                    })
                    n_bindings += 1

            for key, cfg in (svc.get("networks") or {}).items():
                ip = (cfg or {}).get("ipv4_address")
                if not ip:
                    continue
                net = (networks.get(key) or {}).get("name") or "%s_%s" % (project, key)
                ips[(net, ip)].append((label, name))
                n_ips += 1

    for (port, proto) in sorted(bindings):
        group = bindings[(port, proto)]
        involved = [b for b in group
                    if any(o is not b and clash(b, o) for o in group)]
        if not involved:
            continue
        errors += 1
        files = sorted({b["file"] for b in involved})
        if len(files) == 1:
            print("    ERROR: Duplicate ports in %s:" % files[0])
            print("      - Port %d/%s is used multiple times: %s"
                  % (port, proto, "; ".join(describe(b) for b in involved)))
        else:
            print("    ERROR: Port %d/%s used across multiple files:" % (port, proto))
            for b in involved:
                print("      - %s: %s" % (b["file"], describe(b)))

    for (net, ip) in sorted(ips):
        users = ips[(net, ip)]
        if len(users) < 2:
            continue
        errors += 1
        files = sorted({f for f, _ in users})
        if len(files) == 1:
            print("    ERROR: Duplicate static IPs in %s:" % files[0])
            print("      - IP %s on network %s is assigned to multiple services: %s"
                  % (ip, net, ", ".join(s for _, s in users)))
        else:
            print("    ERROR: IP %s on network %s used across multiple files:" % (ip, net))
            for f, s in users:
                print("      - %s: %s" % (f, s))

    if host_net:
        print("    NOTE: not checked: %s use the host's network, so the ports they"
              " bind are not in the compose model" % ", ".join(host_net))

    if unrendered:
        return 2
    if errors:
        return 1
    print("    OK: No conflicts among %d published host ports and %d static IPs"
          " in %d compose files" % (n_bindings, n_ips, len(models)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
