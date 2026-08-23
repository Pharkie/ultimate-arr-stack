# ProtonVPN Tailscale Exit Node — Project Log

**Audit of the `feat/tailscale-protonvpn-exit-node` branch.** Written as a
handoff record: what was attempted, what actually happened, where the plan was
wrong, and what is still open. If you are picking this work up cold, read
[§1](#1-status-at-a-glance), [§5](#5-live-only-state-that-is-not-in-this-repo)
and [§8](#8-traps) first — those three carry the knowledge that is expensive to
rediscover.

Last updated: **2026-08-23**. Sections 2, 5, 6 and 8 are historical and stay
true; **§1 and §7 decay.** Every claim in §1 now carries the command to re-check
it rather than a copied value, because the first version of this document
embedded a commit SHA and a commit count that its own commit invalidated the
moment it landed. If you find a bare number in §1, treat it as a bug.

---

## 1. Status at a glance

| | |
|---|---|
| Branch | `feat/tailscale-protonvpn-exit-node` |
| HEAD / commits ahead | **Do not trust a number written here.** Re-check: `git rev-parse --short HEAD` and `git rev-list --count origin/main..HEAD`. Compare against `origin/main`, *never* a local `main` ref — see §8 trap 11 |
| Deployed | NAS tracks this branch. Re-check on the NAS: `arrgit rev-parse --short HEAD`, compare to local |
| Merged to `main` | **No.** Blocked on the MergeGate `adversarial-review` (task #76) |
| Tests | Green at last run, 2026-08-23. Re-check: `npm run test:bats` — static, needs no NAS or Docker access |
| Go/No-Go gate | **Satisfied**, including the leak test (check I) |
| Works from the phone | **Yes** — 22.6 Mbps ↓ / 22.9 Mbps ↑ / 0.0 % loss, Proton NL egress, on cellular |

**What it does.** The NAS runs a second, dedicated ProtonVPN tunnel
(`gluetun-exit`) whose only job is to be the internet egress for a second
Tailscale node (`tailscale-exit`). Selecting that node as a Tailscale exit node
gives a client Proton's IP for internet traffic *and* home `.lan` access over
the same tunnel — which is the whole point, because Android permits only one
VPN at a time.

**The one-line summary of the two days.** The build worked early. Almost all the
elapsed time went into diagnosing a performance problem that turned out to be
two unrelated problems wearing a trenchcoat: a TCP MSS/MTU nesting bug (real,
fixed in `f3f60a5`), and the user having accidentally selected a *different,
non-functional* exit node (`arr-stack-nas`). Several confident intermediate
diagnoses in between were wrong; §4 records each one, because the ways they
were wrong are more reusable than the fixes.

---

## 2. Commit-by-commit audit

| Commit | When | What it did | Verified by |
|---|---|---|---|
| `9505229` | 08-21 21:18 | Add `gluetun-exit`, `tailscale-exit`, `tailscale-exit-routing`; `.env` placeholders; zombie-detector + e2e coverage | bats, NAS deploy |
| `0ec1773` | 08-21 21:20 | Docs: verified compose behaviour for the external `arr-core` network | — (docs) |
| `29dd412` | 08-22 09:39 | Docs: record the nft/legacy iptables split found on the NAS | live NAS inspection |
| `2c7d712` | 08-22 09:51 | Stop `tailscale-exit` restart-looping when it has no way to log in | container stable |
| `1a3db89` | 08-22 10:20 | Docs: tailnet DNS is a hard prerequisite | — (docs) |
| `1503515` | 08-22 21:32 | Exit node must resolve DNS for its clients, not defer to gluetun's DoT | DNS from client |
| `c314de4` | 08-22 21:36 | Kill switch must permit the tailnet IPv6 ULA | rule present |
| `ac776a7` | 08-22 21:40 | Put the IPv6 OUTPUT rule where it can take effect | rule present |
| `26cfb13` | 08-22 21:44 | Write that rule to the **nft** backend, not legacy | `ip6tables-nft -S` |
| `2f6343f` | 08-22 21:48 | Grant tailnet ranges in OUTPUT instead of via gluetun's subnet list | rule present |
| `f184e45` | 08-22 21:52 | Docs: exit-node DNS resolves on the NAS, not the client | — (docs) |
| **`f3f60a5`** | 08-22 22:54 | **Clamp TCP MSS to the `tailscale0` path.** The single most important fix in the branch | phone: 41.4 % loss → 0.0 % |
| `6677e0d` | 08-23 10:38 | Attempt an IPv4-only exit node (drop `::/0`) | **FAILED — see §4.5** |
| `71a7a47` | 08-23 10:40 | Revert the above; document that Tailscale forbids it | exit node restored |
| `24d0771` | 08-23 12:46 | `gluetun-exit-rotator` — throughput-aware Proton server rotation via the control-server API | 40 Mbps probe, no rotation, netns intact |
| `a87400c` | 08-23 13:10 | Stop node 1 advertising its non-functional exit node | survives `--reset` recreate |

Note `6677e0d` → `71a7a47` are **two minutes apart**. That failed experiment is
deliberately left in history rather than squashed, because the constraint it
discovered is not documented clearly upstream (§4.5).

---

## 3. The plan's phases — planned vs actual

The plan was authored around a peer-relay port-forward as the central fix. That
premise did not survive measurement. Phases 0–2 completed; Phases 3–5 were
**superseded, not abandoned** — the problem they existed to solve was solved
another way.

| Phase | Planned | Outcome |
|---|---|---|
| **0** — Deploy MSS clamp, re-measure | Decide everything downstream on one number | ✅ **Done.** The number came back 22.6 Mbps. This is the phase that invalidated Phases 3–5 |
| **1** — Narrow the ACL grant, baseline the phone | Tighten `src` to `tag:personal-device` | ⚠️ **Partial.** Phone baselined; the ACL grant narrowing was **not done** — still `autogroup:member` |
| **2** — Restore access | Fix NAS SSH, confirm router admin | ✅ **Done** (task #82). SSH port 22 was being DROPped by a UGOS firewall rule |
| **3** — Repo change: drop `--reset`, add relay sidecar | Make the peer relay declarative | ❌ **Superseded.** Tasks #77–#81 remain open but the justification is now latency-only, and weak — see §4.6 |
| **4** — Deploy, add router port-forward UDP 41641 | Make node 1 publicly reachable | ❌ **Not done, deliberately.** No router change was ever made |
| **5** — Verify from phone, then gate | Go/No-Go | ✅ **Gate satisfied** by a different route than planned |

**Why Phases 3–5 died.** The port-forward existed to move the phone from DERP
to a peer relay, on the theory that DERP was the throughput bottleneck. Three
independent measurements refuted that:

1. The phone reached 22.6 Mbps **over plain DERP** once the MSS clamp landed.
2. The Mac's ~8 Mbps ceiling was measured **over the peer relay itself** — so
   the relay cannot lift a ceiling that sits above it.
3. On 08-23, a controlled comparison on one Proton server found DERP
   *faster* than the peer relay (8.7 vs ~6.0 Mbps).

The peer relay's surviving benefit is **latency only** (2 ms vs 50 ms measured
locally; 300–630 ms on the phone's DERP earlier). That is a real interactive-use
argument, but it is an optimisation, not a rescue, and it does not obviously
justify opening inbound UDP to a host that is simultaneously subnet router and
exit node. **This is a judgment call, not a measurement — leave it to the user.**

---

## 4. Corrections — where the plan was wrong

This is the highest-value section. Each entry: what was believed, what was
actually true, and how it was caught.

### 4.1 "DERP is throttling the phone to 0.17 Mbps"
**Believed:** the 0.17 Mbps / 41.4 % loss was DERP relay congestion.
**Actually:** TCP MSS/MTU nesting. 41.4 % loss is an MTU black-hole signature —
a congested relay is slow but does not shred *large* packets specifically while
small ones pass. Every check that passed (`.lan`, `ifconfig.me`, DNS) involved
only small responses; no bulk transfer had ever been measured.
**Caught by:** noticing that the branch's own HEAD commit attributed the
identical number to MSS, and that no bulk measurement existed.
**Fix:** `f3f60a5`. Loss 41.4 % → **0.0 %**, throughput 0.17 → **22.6 Mbps**.

### 4.2 "The peer relay will fix throughput"
**Believed:** moving the phone DERP → peer relay would restore app-parity speed.
**Actually:** the ~8 Mbps ceiling was measured **over the peer-relay fast path**
(`tailscale ping` confirmed `peer-relay(...) in 2ms` mid-transfer). The ceiling
sits above the relay, so the relay cannot lift it.
**Caught by:** checking which path the slow measurement had actually used,
instead of assuming.

### 4.3 "Node 1 is a safe rollback target"
**Believed:** the plan's rollback step 1 — "Exit Node → `arr-stack-nas` or None".
**Actually:** node 1's exit node is **completely non-functional**, and always
was. Tailscale writes exit-node rules to the *legacy* iptables tables while
Docker/UGOS enforce the *nft* backend, where `filter` carries `-P FORWARD DROP`.
Nothing accepts new forwarded flows from `tailscale0`. Subnet routing is
unaffected and keeps working, which is exactly what makes it invisible.
**Cost:** the user selected it by mistake and reported "barely connects". Days
of debugging — including the entire IPv6 thread in §4.4 — chased that phantom.
**Fix:** task #84 / commit `a87400c`. Node 1 no longer advertises it.
**Do NOT "fix" node 1's forwarding instead:** a *working* node-1 exit node
egresses via the **home IP**, precisely the leak the Go/No-Go check I exists to
catch.

### 4.4 The IPv6 black hole (a whole thread that led nowhere)
**Believed:** the exit node advertises `::/0` with no IPv6 egress, silently
black-holing client IPv6 and stalling every AAAA-first connection.
**Actually:** the *defect* is real and unavoidable, but the *symptom* was never
demonstrated:
- ICMPv6 errors were **already permitted out** by an existing rule, so IPv6
  already failed fast rather than stalling. Nothing to fix.
- The IPv6-nameserver stall theory was refuted by upstream docs: Tailscale
  queries all nameservers **in parallel and takes the quickest**, so dead IPv6
  resolvers lose the race rather than blocking.
- The `curl -6` reading that looked like proof (25 s stall) was worthless: the
  **baseline with no exit node stalled for the same 25 s**. It did not
  distinguish the two cases.
**Measured cleanly:** dual-stack through the exit node carried **zero penalty** —
0.045 s connect, identical to forced `-4`.
**Caught by:** running the zero-change experiment *to completion* and actually
comparing against the baseline.
**Closed with no action** (task #88).

> **Two different IPv6 threads live in this branch. Do not merge them.**
> An adversarial reviewer conflated them within minutes of reading this section,
> so the distinction is written out here:
>
> 1. **The tailnet IPv6 ULA (`fd7a:115c:a1e0::/48`) — real, fixed, shipped.**
>    Commits `c314de4`, `ac776a7`, `26cfb13`, `2f6343f`. `tailscaled` writes
>    *both* `100.100.100.100` and `fd7a:115c:a1e0::53` as resolvers, so
>    gluetun's kill switch must permit the ULA or the exit node cannot resolve
>    for its own clients. This is about the node's **own control/DNS traffic**.
> 2. **The `::/0` exit-egress black hole — investigated, no action (this
>    section).** About **client internet traffic** the node advertises a route
>    for and cannot carry.
>
> Both say "IPv6" and both touch `ip6tables`; they are unrelated. Seeing the
> shipped ULA commits is *not* evidence that thread 2 was acted on.

> **⚠️ A contradicting comment is still live in the repo.**
> `docker-compose.tailscale.yml:284-289` still states that a client taking up
> `::/0` "sees nothing to fail fast on and burns a full connect timeout
> instead", citing the same 25 s `curl -6` measurement this section calls
> worthless. That comment was introduced by `6677e0d` — the failed IPv4-only
> experiment (§4.5) — and `71a7a47` reverted the *flag* while keeping the
> *rationale*. The comment's own premise is refuted by
> `docker-compose.tailscale.yml:454`, which installs a blanket
> `ip6tables-nft -A OUTPUT -o tailscale0 -j ACCEPT` — ICMPv6 included — so the
> unreachable errors do reach the client and IPv6 fails fast.
>
> **This document is right and that comment is wrong**, but the comment is what
> a reader hits first when editing the service. If it is still there when you
> read this, fix it rather than re-opening the investigation.

### 4.5 "Just advertise IPv4-only" — refuted by the client itself
**Believed:** replacing `--advertise-exit-node` with `--advertise-routes=0.0.0.0/0`
would stop advertising IPv6 the node cannot serve.
**Actually:** `tailscale up` **refuses outright**:
```
0.0.0.0/0 advertised without its IPv6 counterpart, please also advertise ::/0
```
The container never came up and the exit node went down until the revert.
**There is no supported IPv4-only Tailscale exit node.** Upstream's wording
("may not be recognised as a traditional exit node") badly understates it.
**Caught by:** deploying it. Reverted in `71a7a47`; the constraint is now
documented inline in `docker-compose.tailscale.yml` so nobody retries it.
**Watch the revert's blast radius:** `6677e0d` added both the flag *and* a long
rationale comment. `71a7a47` reverted the flag and left the comment, so a
refuted claim survived as an authoritative-looking comment (see the box in
§4.4). A revert that only undoes the executable half of a commit leaves the
prose half lying — check both.

### 4.6 "Unapprove node 1 in the admin console — zero-risk, no recreate"
**Believed:** the cheapest way to remove the node-1 footgun.
**Actually:** **not durable.** The tailnet ACL contains
`autoApprovers.exitNode: ["tag:nas-router"]`, and *both* nodes carry
`tag:nas-router` — node 1 would be auto-re-approved the moment it advertised
again. Scoping the auto-approver away from node 1 would require retagging node 2
and rewriting every grant that references that tag.
**Caught by:** reading the ACL before acting on the recommendation.
**Fix:** don't advertise it at all (`a87400c`), guarded by three bats tests.

### 4.7 "The UGOS admin UI is the escape hatch if the recreate fails"
**Believed:** `https://192.168.110.246:9443` gives a way back in if recreating
node 1 cuts SSH.
**Actually:** `route -n get 192.168.110.246` → **`utun7`**. That address rides
node 1's *own* subnet route, same as SSH. Node 1 is the tailscaled serving both
paths; recreating it severs everything simultaneously. There is no escape hatch
short of physical access or moving a machine onto VLAN10.
**Handled by:** running the recreate detached (`setsid nohup`) with a
state-volume backup and an automatic rollback that re-adds the flag if the node
does not return with its subnet route. It returned in 5 s; rollback never fired.

### 4.8 A self-inflicted one: "53 % packet loss"
An earlier session reported 53 % packet loss on the Proton path and treated it
as a finding. **It was an artifact** — Proton rate-limits ICMP. Proven when a
later run reported **60 % "loss" and 98 / 78 / 92 Mbps in the same minute**.
See §8.1.

---

## 5. Live-only state that is **not** in this repo

**Read this before assuming a fresh deploy reproduces the working system.**
Each of these was applied directly to live infrastructure and is not tracked in
git. Several are load-bearing.

| # | What | Where it lives | Notes / what destroys it |
|---|---|---|---|
| 1 | **`tailscale set --relay-server-port=41641`** on node 1 | node 1's prefs | ⚠️ **Wiped by `--reset` on EVERY node-1 restart**, and **nothing detects the loss** — no bats test, no healthcheck, no log line. This document is the only guard. Check: `ssh arr-stack-nas 'docker exec tailscale tailscale debug prefs'` → `RelayServerPort`. Re-apply: `ssh arr-stack-nas 'docker exec tailscale tailscale set --relay-server-port=41641'`. Task #77 removes `--reset`; task #79 adds the guard. Until both land, assume it is gone after any node-1 restart |
| 2 | Tailnet **ACL policy** — `tagOwners`, grants, `autoApprovers` | Tailscale admin console | Includes `autoApprovers.exitNode: ["tag:nas-router"]` (see §4.6) and the relay grant, still at `autogroup:member` rather than the narrower `tag:personal-device` the plan wanted |
| 3 | Split DNS for `*.lan` | Tailscale admin console | Prerequisite for `.lan` names through the tunnel |
| 4 | **macvlan shim** on the NAS | Root's crontab on the NAS (`@reboot`), idempotent — it checks the link exists before recreating. Inspect the live entry with `ssh arr-stack-nas 'crontab -l'` **before** rebuilding from memory; the shape is `ip link add macvlan-shim link eth0 type macvlan mode bridge` + `192.168.8.251/32` on the shim + a host route to Traefik's `192.168.8.250/32` via it | A Linux host can never reach its own macvlan containers by kernel design. Without this, Traefik `.lan` e2e tests fail `EHOSTUNREACH`. Verify with `ip route get 192.168.8.250` on the NAS |
| 5 | UGOS firewall: allow inbound Tailscale → SSH/Docker ports | UGOS admin UI | Blocked the CI deploy workflow until fixed |
| 6 | UGOS firewall: the port-22 DROP rule, removed | UGOS admin UI | Task #82. Symptom was `:22` timing out while `:2375`/`:2222` returned RST |
| 7 | `cloudflared` restart crash-loop, fixed | NAS-side config | Was consuming NAS resources during health-check waits. **The fix was not recorded** — if it recurs, start from `docker logs cloudflared` rather than looking for a documented remedy here |
| 8 | Prowlarr's current API key written into 4 indexer entries | Radarr ids 2,3 / Sonarr ids 2,3 | Prowlarr pushes its key at setup and never re-pushes if it later changes, so the entries hold a stale key and every indexer 401s. Get the current key from Prowlarr's `/config/general` (or its `config.xml`), then `PUT /api/v3/indexer/{id}` on each. **Diagnose with `/api/v3/indexer/testall`, not `/api/v3/health`** — health is cached and reports stale success |
| 9 | **No router port-forward exists** | — | UDP 41641 was *never* opened. This is a decision (§3), not an omission |

---

## 6. Measurements

Every figure below is a completed-bytes-over-elapsed-time measurement. **None
are ping-derived** — see §8.1.

### Throughput by path

| Path | Throughput |
|---|---|
| NAS host, no VPN | 579–698 Mbps |
| Mac, no VPN | ~486 Mbps |
| Main `gluetun` (different Proton server, same box) | 105–144 Mbps |
| `gluetun-exit` raw, good draw `185.107.44.149` | 78–98 Mbps |
| `gluetun-exit` raw, **bad draw `103.69.224.76`** | **0.5–3 Mbps**; 100 MB flows never completed |
| Mac → exit node, **peer-relay**, 1 flow | 5.9–9.1 Mbps |
| Mac → exit node, peer-relay, 4 flows | 22.3 Mbps aggregate |
| Mac → exit node, peer-relay, 8 flows | 15.1 Mbps aggregate (*degrades*) |
| Mac → exit node, **DERP(ams)**, 1 flow | **8.7 Mbps** (1 sample) |
| Phone, cellular, DERP, **before** MSS clamp | 0.17 Mbps / 41.4 % loss |
| Phone, cellular, DERP, **after** MSS clamp | **22.6 ↓ / 22.9 ↑ Mbps / 0.0 % loss** |
| Phone, ProtonVPN app alone (no `.lan`) | 55 Mbps |
| Phone, no VPN | 103 Mbps |

### What the numbers establish

- **A bad Proton server draw is a ~30× effect** — larger than DERP-vs-relay,
  larger than MTU. This is why `gluetun-exit-rotator` exists.
- **There is a real ~6–9 Mbps per-flow Tailscale ceiling** (task #86),
  independent of server quality. It is *flat*, not a collapse, which is why it
  never presented as breakage.
- **The relay hop is not the bottleneck.** DERP and peer-relay land in the same
  band, and the *lower-latency* path measured *slower*.
- **Ruled out for #86:** CPU (NAS 77.2 % idle under load; `tailscaled` 21.2 %
  while moving 8.5 Mbps), the MSS clamp (`tailscale0` 1280 / `tun0` 1320 /
  clamp 1240 — correct), underlay MTU nesting (`tailscaled` reaches the relay
  over `eth0` at MTU 1500).
- **Remaining hypothesis for #86:** the `tailscaled`-inside-`gluetun`-netns
  nesting. Parallelism nearly tripling aggregate throughput points at a
  per-flow, congestion-control-shaped limit rather than a capacity limit.

### Gate check I — the leak test: **PASS**

`gluetun-exit` stopped for 45 s with the Mac holding the exit node:

| Probe | Result |
|---|---|
| 12 × `ifconfig.me` over 48 s | **no response, every time** (rc=28) |
| Home IP `95.214.228.24` seen | **never** |

Failed fully closed. `.lan` also went down during the outage — expected, not a
leak: with an exit node selected Tailscale uses it as the resolver for *all*
domains.

**Recovery is unattended but slow (~2 min):** stopping `gluetun-exit` gives it a
new netns, briefly orphaning `tailscale-exit`; `deunhealth` noticed at 11:19:11
and restarted it at 11:19:13. **The phone did not recover on its own** and
needed a manual Tailscale toggle — task #90, and the reason
`gluetun-exit-rotator` is API-driven rather than restart-driven.

---

## 7. Open items

| Task | What | Next action |
|---|---|---|
| **#76** | `adversarial-review` on the full branch diff, then merge | **Blocks merge.** MergeGate rule, no exceptions. Reviewers must run as `haiku` subagents |
| #86 | The ~6–9 Mbps per-flow ceiling | Controlled A/B (n≥5 each way, alternating, one server) to confirm the DERP-vs-relay direction, then test the netns-nesting hypothesis. **Biggest remaining lever** |
| #90 | Android does not recover when `tailscale-exit` restarts | Needs the phone. Drive `tailscale-exit` restart frequency toward zero — that is the lever we control |
| #77 | Drop `--reset` from node 1 | **Now unblocked** — `a87400c` has been applied through a `--reset` recreate, so dropping it can no longer resurrect a stale `AdvertiseRoutes` |
| #79 | bats guard against `--reset` returning | Pairs with #77 |
| #78, #80, #81 | Relay sidecar, docs, commit | **Premise weakened** (§3). Latency-only justification. Decide before building |
| — | ACL grant still `autogroup:member` | Plan Phase 1 wanted `tag:personal-device`. Narrow it if the relay work proceeds |

---

## 8. Traps

Methodology lessons. Each one cost real time. Traps **2, 6, 8 and 11** are
specific to this exit-node work; **1, 3, 4, 5, 7, 9 and 10** were paid for by
the NAS CI/deploy effort and are recorded at more length in `CLAUDE.md`'s
*Deploying to the NAS* section. They are repeated here because they are
methodology, not history, and the failure modes recur — but `CLAUDE.md` owns
the detail.

1. **Never judge a Proton path with `ping`.** ICMP is rate-limited. A 60 %
   "packet loss" reading coexisted with 98 Mbps of real throughput. Judge on
   completed bytes and elapsed time only.
2. **Health ≠ speed.** Gluetun's healthcheck probes TCP/TLS to `1.1.1.1:443`,
   which passes fine on a server delivering 0.5 Mbps.
3. **HTTP 200 is not proof you hit the right backend.** A `.lan` test "passed"
   while actually receiving the NAS's own UGOS admin panel. Assert on response
   *content*.
4. **A fix verified against a proxy is not verified.** `--dns-result-order` and
   `/etc/hosts` both fixed a `node -e "dns.lookup(...)"` one-liner and changed
   nothing in the real test — Playwright's `APIRequestContext` resolves via
   `dns.resolve4`/c-ares, bypassing both.
5. **A retry loop with no post-loop check is a false pass.** `for i in 1..10; do
   cmd && break; sleep 3; done` exits 0 whether or not anything succeeded. This
   masked a real connectivity failure for several CI steps.
6. **`SandboxKey` is always empty for `network_mode: service:X` containers** —
   it is an invalid zombie check. Compare `HostConfig.NetworkMode` against the
   target's *current* container id instead.
7. **A test suite written on a configured machine assumes local state CI won't
   have.** `hooks-installed.bats` required `./setup-hooks.sh` to have been run.
8. **A probe that forces IPv4 cannot see an IPv6 problem.** Every `curl -4` in
   this project structurally could not reproduce the phone's condition — and
   then it turned out there was no IPv6 problem anyway (§4.4). Both halves of
   that are worth remembering.
9. **When an infra fix keeps needing another infra workaround, re-read the
   test's own stated intent.** The `.lan` DNS saga ended when the fix turned out
   to be honouring what the test already said it wanted (avoid DNS), not deeper
   DNS plumbing.
10. **DNS bugs masquerade as app or routing bugs one layer up.** A UGOS-HTML
    response looked like a Traefik or Sonarr fault until raw `dns.lookup()`
    output made it obvious.

11. **A commit count is only as good as the ref you diffed against.** An
    adversarial reviewer auditing this document reported the branch as "32
    commits ahead of `main`" and called §1 wrong. It had diffed against the
    *local* `main`, which was 15 commits stale; `origin/main..HEAD` was the
    real answer. Always name the remote ref explicitly. This is trap 4 in a
    new costume — a fact verified against a proxy — and it was produced *by a
    review of this very document*, which is how much this class of error likes
    to recur.

### Operational hard rules

The first four are repeated from `CLAUDE.md` on purpose: that file is skimmed
at session start, this one is opened when you are about to touch the thing.
**`CLAUDE.md` is authoritative if they ever disagree** — fix the divergence
rather than picking one.

- **NEVER pass `--remove-orphans`** to any `docker compose` command on this NAS.
  Services are split across multiple compose files sharing one project name, so
  compose treats every container from the *other* files as an orphan. This took
  out 11 containers on 2026-08-01.
- **Only recreate a service via the compose file that defines it.** Traefik must
  go through `docker-compose.traefik.yml` or it loses its `traefik-lan` macvlan
  and every `.lan` URL dies.
- **Never rotate `gluetun-exit` with `docker restart`.** Its netns is shared by
  `tailscale-exit`; a restart orphans it for ~2 min and **strands Android
  clients until Tailscale is manually toggled**. Use the control-server API,
  which swaps the WireGuard peer in place.
- **Recreating node 1 severs every path to the NAS at once** (§4.7). Do it
  detached, with a state-volume backup and an auto-rollback.
- Every containerized-git invocation on the NAS needs `-c safe.directory=/repo`.
- `scp` fails opaquely against this NAS's BusyBox `sftp-server`; pipe through
  `ssh ... 'tee dest'` instead.
