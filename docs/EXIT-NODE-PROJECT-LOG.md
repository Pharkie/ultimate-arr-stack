# ProtonVPN Tailscale Exit Node — Project Log

**Audit of the exit-node work, merged to `main` on 2026-08-23 (PR #38).**
Written as a
handoff record: what was attempted, what actually happened, where the plan was
wrong, and what is still open. If you are picking this work up cold, read
[§1](#1-status-at-a-glance), [§5](#5-live-only-state-that-is-not-in-this-repo)
and [§8](#8-traps) first — those three carry the knowledge that is expensive to
rediscover.

Last updated: **2026-09-05**. Sections 2, 5, 6 and 8 are historical and stay
true; **§1 and §7 decay.** Every claim in §1 now carries the command to re-check
it rather than a copied value, because the first version of this document
embedded a commit SHA and a commit count that its own commit invalidated the
moment it landed. If you find a bare number in §1, treat it as a bug.

**2026-09-05: the NAS-based exit node described below is decommissioned.**
Sections 1-9 describe the original `gluetun-exit`/`tailscale-exit` build and
stay as the historical record of how the architecture was arrived at and what
it cost to build — nothing below is rewritten to pretend otherwise. §10
records what replaced it and why.

---

## 1. Status at a glance

| | |
|---|---|
| Status | **Superseded 2026-09-05.** The `gluetun-exit`/`tailscale-exit` build described below (merged to `main` in `5fc6776`, PR #38, 2026-08-23) was decommissioned — see §10. The exit-node role now runs natively on `arr-stack-router` |
| HEAD | **Do not trust a number written here.** Re-check: `git rev-parse --short HEAD`. When counting commits, compare against `origin/main`, *never* a local `main` ref — see §8 trap 11 |
| Deployed | NAS tracks `main`. Re-check on the NAS: `arrgit rev-parse --short HEAD`, compare to local |
| Merge gate | **Cleared.** MergeGate `adversarial-review` ran against the full branch diff and returned CONTESTED; both accepted findings were fixed in `57d11e8` before the merge. See §9 |
| Tests | Green at merge: bats 44/44, and the e2e suite on the NAS at 51 passed / 3 skipped / 0 failed. Re-check: `npm run test:bats` — static, needs no NAS or Docker access |
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
| **3** — Repo change: drop `--reset`, add relay sidecar | Make the peer relay declarative | ⚠️ **Split.** `--reset` itself is dropped (#77/#79 ✅ done). The relay sidecar (#78/#80/#81) remains open — justification is now latency-only, and weak — see §4.6 |
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

> **A contradicting comment used to live in `docker-compose.tailscale.yml`.
> It is fixed — do not go looking for it.**
> The comment stated that a client taking up `::/0` "sees nothing to fail fast
> on and burns a full connect timeout instead", citing the same 25 s `curl -6`
> measurement this section calls worthless. It came in with `6677e0d` — the
> failed IPv4-only experiment (§4.5) — and `71a7a47` reverted the *flag* while
> keeping the *rationale*. Its premise is refuted by the routing sidecar's
> rule 5, a blanket `ip6tables-nft -A OUTPUT -o tailscale0 -j ACCEPT` (ICMPv6
> included), so the unreachable errors do reach the client and IPv6 fails fast.
> Corrected in `66ecac1`; the comment now says so and points back here.
>
> An adversarial reviewer read *this box* on the next pass, took "still live"
> at face value, and re-raised the contradiction as a finding against an
> already-fixed file. **A note telling a future reader to go fix something is
> a claim with a shelf life.** Close it when you close the work, or it
> manufactures the very re-investigation it was written to prevent.

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
| 1 | **`tailscale set --relay-server-port=41641`** on node 1 | node 1's in-memory prefs ONLY | ✅ **Self-healed as of #91** — `scripts/ensure-tailscale-relay-port.sh`, run every 30 min via `ensure-tailscale-relay-port.timer` (a `--user` systemd unit, same pattern as `detect-credential-drift.timer`), re-applies this automatically after any node-1 restart. Still wiped by ANY node-1 restart or recreate, not just `--reset` ones — confirmed live 2026-08-25: after recreating node 1 with `--reset` already dropped (#77/#79), `RelayServerPort` was still gone, and `grep -c RelayServerPort /var/lib/tailscale/tailscaled.state` inside the container returned `0` both before and immediately after re-applying it. This setting is not written to `tailscaled.state` at all in this tailscaled version — it lives purely in the running daemon's memory; the timer masks this, it doesn't fix the underlying `tailscaled` behavior. `--reset` was never the actual mechanism destroying it; #77/#79 only fixed the *original* stated problem (a stale `AdvertiseRoutes` resurrecting on `tailscale up --reset`). A container-level `post_start:` hook was considered and rejected (see #91 in §7) — the timer covers a wider set of restart paths, notably NAS reboots, where Compose is not involved at all. Check: `ssh arr-stack-nas 'docker exec tailscale tailscale debug prefs'` → `RelayServerPort`. Manual re-apply is no longer needed but still works if urgent: `ssh arr-stack-nas 'docker exec tailscale tailscale set --relay-server-port=41641'` |
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
| Phone (Android), exit node, `185.107.44.149` (good draw), **after** `rx-udp-gro-forwarding on` on NAS `eth0` | **2.85 Mbps** (1 sample, 2026-09-04) |
| Phone, **router-based exit node** (`arr-stack-router`, London), client in remote Brazil Airbnb, ~245ms idle ping, 3.7% loss | **68.6 ↓ / 47.6 ↑ Mbps** (Speedtest app, 1 sample, 2026-09-05) — 8–10× the old ceiling, despite far worse network conditions than any prior sample |

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
- **Root cause identified, 2026-09-04:** `gluetun-exit`'s own Proton tunnel is
  already kernel-mode WireGuard (`[wireguard] Using available kernelspace
  implementation` in its logs; `ip -d link show tun0` reports `link/none ...
  wireguard` with populated `gso_max_size`/`gro_max_size`/`tso_max_size`) — that
  layer is not the bottleneck. Tailscale's own UDP-GSO/GRO batching throughput
  work needs Linux kernel 6.2+; the NAS is on **6.1.84**. Confirmed empirically,
  not just by kernel-version inference: enabling `rx-udp-gro-forwarding on
  rx-gro-list off` on the NAS's `eth0` (via a throwaway `--net=host` container,
  since the vendor OS has no `ethtool`) made **no measurable difference** — the
  phone-through-exit-node sample taken right after was 2.85 Mbps, same band as
  every prior sample. `ethtool -k eth0` shows why: `generic-segmentation-offload:
  off [requested on]` — the driver refuses to actually enable GSO regardless of
  the forwarding flag, a hardware/driver ceiling underneath the kernel-version
  one. This is a dead end on this NAS; not worth retrying.
- **The real lever is architectural, not a config fix:** running Tailscale
  nested inside `gluetun-exit`'s netns, inside Docker, on a NAS that also runs a
  dozen unrelated services, versus running it natively on dedicated routing
  hardware. See task #86's row in §7 — a router-based exit node
  (`GL-MT6000`/Flint 2, already has `kmod-wireguard` + `tailscale` installed,
  independently benchmarked at ~810–900 Mbps real-world WireGuard client
  throughput) is being piloted as the replacement, staged so the NAS path stays
  up until it's proven end-to-end.

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
| #86 | The ~6–9 Mbps per-flow ceiling | ✅ **Closed (2026-09-05)** — resolved by decommissioning the NAS-based path entirely rather than fixing its ceiling. Kernel-6.2 UDP-GSO wall + driver-level `generic-segmentation-offload: off [requested on]` confirmed dead end empirically (§6); the router-based replacement (`arr-stack-router`, native `kmod-wireguard` + `tailscale`) measured 68.6 ↓ / 47.6 ↑ Mbps under adverse conditions, 8–10x the old ceiling. See §10 |
| — | `autoApprovers.exitNode: ["tag:nas-router"]` covers `arr-stack-router` too | ✅ **Closed (2026-09-05)** — confirmed via the admin console's Machines list that `arr-stack-router` already carries `tag:nas-router`, the same tag `autoApprovers.exitNode` already grants. No ACL edit needed; exit-node approval survives a re-auth the same way node 1's does. The offline `tailscale-exit` node (`arr-stack-vpn-exit`) was also deleted from the admin console the same day |
| — | No leak/kill-switch test exists for the router-based exit-node path | **Open, new (2026-09-05).** §6 Gate check I proved the NAS-based path (`gluetun-exit`) failed closed rather than leaking on VPN drop; that test (`tests/e2e/vpn-security.spec.ts`'s exit-node chaos test) was deleted along with the container it exercised, and no equivalent exists for `arr-stack-router`. The decommission plan explicitly did not close this gap — it inherited it, on the user's explicit choice to proceed on the throughput margin alone (see §10). Next action: devise a way to test router-side kill-switch behavior (e.g. drop the router's WireGuard interface while a Tailscale client is using it as exit node, confirm traffic fails closed rather than falling back to the router's raw WAN route) |
| #90 | Android does not recover when `tailscale-exit` restarts | ✅ **Moot (2026-09-05)** — `tailscale-exit` no longer exists; see §10. If the router-based exit node ever needs to restart, this class of bug (Android not re-establishing the tunnel afterward) may resurface and would need re-verifying fresh, not assumed fixed by this closure |
| #77 | Drop `--reset` from node 1 | ✅ **Done** — dropped from `docker-compose.tailscale.yml`'s `TS_EXTRA_ARGS`, verified live on the NAS |
| #79 | bats guard against `--reset` returning | ✅ **Done** — `node 1 (tailscale) does NOT pass --reset in TS_EXTRA_ARGS` in `tests/compose-validation.bats` |
| #78, #80, #81 | Relay sidecar, docs, commit | ✅ **Dropped (2026-09-04)** — premise weakened (§3), latency-only justification, decided not to build. Closed, not revisiting without new evidence of a throughput benefit |
| #91 | `RelayServerPort` doesn't survive ANY node-1 restart | ✅ **Done** — `scripts/ensure-tailscale-relay-port.{sh,service,timer}`, a `--user` systemd timer re-applying it every 30 min. Discovered while deploying #77/#79 (2026-08-25) — dropping `--reset` did not fix this, it was never the cause. A `post_start:` container hook was considered and rejected: NAS reboots restore containers via Docker's own `restart: always` policy, not through Compose (see `docs/TROUBLESHOOTING.md`'s DNS-after-reboot section, the same fact that motivated `boot-compose-up.service`), so a Compose-only hook would never fire on that path. Live-verified end-to-end: `docker restart tailscale` reproduces the loss, the service restores it without any manual `tailscale set`, per §5 item 1 |
| — | ACL grant still `autogroup:member` | ✅ **Closed (2026-09-04)** — stays `autogroup:member`. Narrowing to `tag:personal-device` was only motivated by the relay sidecar, which was dropped above |
| #92 | `gluetun-exit`'s WireGuard tunnel dropped on its own (2026-09-04), no error logged | ✅ **Moot (2026-09-05)** — `gluetun-exit` no longer exists; see §10. Root cause was never found before decommission. If the router's own ProtonVPN tunnel ever drops silently, treat this as unexplained precedent, not a solved problem — the underlying "why" here was never answered, only removed |

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

12. **Gluetun's control server has two status endpoints for one tunnel, and
    only one of them matches this container's config.** `/v1/openvpn/status`
    is the legacy endpoint — `PUT {"status":"running"}` there launches the
    **openvpn** client specifically, regardless of `VPN_TYPE`. This container
    runs WireGuard (`VPN_TYPE=wireguard`, real `WIREGUARD_PRIVATE_KEY` set,
    zero OpenVPN credentials anywhere). Recovering a genuinely-dropped tunnel
    (#92) by hitting `/v1/openvpn/status` made gluetun try to start openvpn
    with no auth method configured, which failed immediately and pushed the
    tunnel from a recoverable `"stopped"` into a hard `"crashed"` state.
    `/v1/vpn/status` is the generic, type-respecting endpoint and is the one
    that should be used going forward — but even that could not clear
    `"crashed"` once reached (`PUT` returned `{"outcome":"already crashed"}`
    on every stop/start toggle tried). **The operational hard rule below
    ("use the control-server API, which swaps the WireGuard peer in place")
    is true only for `/v1/vpn/status`, and even then has no recovery path out
    of `"crashed"` — a `docker compose restart gluetun-exit` was the only
    thing that actually worked.** That restart cascaded to
    `gluetun-exit-rotator`, `tailscale-exit-routing`, and `tailscale-exit`
    (all `network_mode: service:gluetun-exit`), and the phone did **not**
    reconnect from a simple Tailscale on/off toggle afterward — it needed a
    full app close-and-relaunch before it showed up as online on the tailnet
    again. That's a new, sharper data point for #90: the existing entry
    describes restart-avoidance as the mitigation, but when a restart is
    unavoidable, "toggle Tailscale" is not sufficient recovery guidance on
    Android — say "fully close and reopen the app."

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
  clients until Tailscale is fully closed and reopened** (a simple on/off
  toggle was not enough — see trap 12). For rotation, use the control-server
  API — but hit `/v1/vpn/status`, not `/v1/openvpn/status`; this container
  runs WireGuard and the openvpn-named endpoint tries to launch openvpn with
  no credentials configured. Note the API has no way out of a `"crashed"`
  status once reached — that state needs the real restart this rule warns
  against, so avoiding "crashed" in the first place (right endpoint, don't
  toggle blind) matters more than this rule's phrasing implied.
- **Recreating node 1 severs every path to the NAS at once** (§4.7). Do it
  detached, with a state-volume backup and an auto-rollback.
- Every containerized-git invocation on the NAS needs `-c safe.directory=/repo`.
- `scp` fails opaquely against this NAS's BusyBox `sftp-server`; pipe through
  `ssh ... 'tee dest'` instead.

---

## 9. What the merge review changed

The MergeGate `adversarial-review` ran against the full branch diff (11 files,
1565 insertions) with three reviewers. Verdict **CONTESTED** — no two reviewers
agreed on any high-severity finding, and the Minimalist returned none at all.
Recorded here because the *rejections* are the part that would otherwise be
re-litigated by the next reviewer.

**Accepted and fixed in `57d11e8`:**

1. **The killswitch had no regression test.** The property this whole feature
   exists to provide — tunnel dies, traffic stops rather than falling back to
   the home IP — had been verified by hand exactly once (§6, gate check I),
   while the equivalent chaos test for the *main* gluetun sat forty lines away
   in the same file. `tests/e2e/vpn-security.spec.ts` now carries the mirror of
   it, opt-in behind `ALLOW_DISRUPTIVE_TESTS` like its counterpart, and its
   cleanup restarts the netns dependents rather than leaving them on a dead
   namespace for deunhealth to find ~2 minutes later. It states its own limit:
   it cannot drive a real tailnet client, so the client-side half of check I
   stays a manual test.
2. **§4.4 told readers to go fix an already-fixed comment** — see the box there
   for what happened and the lesson.

**Rejected, with reasons, so they do not come back:**

- **`set -e` on the routing sidecar.** The finding claimed a failed rule is
  never retried. It is a reconciler on a 30 s loop, so the next cycle retries
  it; `set -e` would instead kill the container on a single transient failure.
  What survives is weaker and still unfixed: a *persistently* failing rule
  install produces no log line and no unhealthy signal.
- **Redesigning away from `network_mode: service:gluetun-exit`.** Sharing the
  netns is precisely what makes traffic fail closed when the tunnel dies —
  proven by check I. The proposed alternative (exit node outside the namespace,
  explicit routing rules) trades away the property the feature exists for. Its
  real cost is already known and tracked: restarts strand Android clients
  (#90), which is why the rotator drives the control-server API instead of
  restarting anything.
- **Deleting the compose file's section headers and the "never restart
  gluetun-exit" comment as duplication.** That comment sits exactly where
  someone would type `docker restart gluetun-exit`. `CLAUDE.md` is skimmed at
  session start; a compose comment is read at the edit site at 2am. Redundancy
  across two different read-triggers is protective, not wasteful.

---

## 10. Decommission: the NAS-based exit node is gone (2026-09-05)

**What happened.** §1's build (`gluetun-exit` + `tailscale-exit` on the NAS)
was removed from `docker-compose.tailscale.yml`, along with
`tailscale-exit-routing` and `gluetun-exit-rotator`. The exit-node role now
runs natively on `arr-stack-router` (a GL-MT6000: its own Tailscale +
WireGuard config, set up directly on the device, not tracked in this repo —
see §5's pattern for why). Everything above this section stays as written; it
is the accurate record of how the NAS-based build was designed, debugged, and
hardened, not a description of what is currently running.

**Why now, on this evidence.** Only one router-based throughput sample
existed at decision time — 68.6 ↓ / 47.6 ↑ Mbps, logged in `2e7142c`, taken
over a remote, high-latency (~245ms), lossy (3.7%) connection. That is one
sample, not the n≥3 same-methodology set every other row in §6's table used,
and it was taken under worse conditions than any prior sample rather than the
same conditions. Asked explicitly whether to gather more validation (a proper
n≥3 set, plus a router-side leak/kill-switch test mirroring §6 Gate check I)
before cutover, the user chose to proceed immediately: an 8–10x margin under
adverse conditions was judged convincing enough on its own. That is a
reasonable call, but it is a judgment call, not a measurement — recorded here
so a future reader doesn't mistake this decommission for having cleared the
same bar as the NAS build did.

**What this closes and what it does not.** #86 (the ~6–9 Mbps ceiling) is
closed — not by fixing it, but by removing the path that had it. What is
*not* closed, and must not be read as closed by proximity to this section: no
kill-switch/leak test exists for the router path. §6 Gate check I proved the
NAS build failed closed (killing `gluetun-exit` blocked egress rather than
leaking via the host route); `tests/e2e/vpn-security.spec.ts`'s chaos test
that proved it was deleted along with the container it exercised, and nothing
replaced it. This is tracked as a new open item in §7, not silently dropped.

**What was removed, concretely:**
- `docker-compose.tailscale.yml`: the `gluetun-exit`, `tailscale-exit`,
  `tailscale-exit-routing`, and `gluetun-exit-rotator` services, their
  `tailscale-exit-state`/`gluetun-exit-config` volumes, and the `arr-core`
  external-network declaration those services alone had needed.
- `tailscale/gluetun-exit-post-rules.txt` (only `tailscale-exit-routing` read
  it).
- The exit-node env vars in `.env.example`
  (`GLUETUN_EXIT_ROTATE_INTERVAL_SECONDS`, `GLUETUN_EXIT_MIN_MBPS`,
  `GLUETUN_EXIT_MAX_ATTEMPTS`, `VPN_EXIT_WIREGUARD_PRIVATE_KEY`,
  `VPN_EXIT_WIREGUARD_ADDRESSES`, `VPN_EXIT_COUNTRIES`, the commented
  `TS_EXIT_HOSTNAME`/`TS_EXIT_AUTHKEY` lines).
- `scripts/detect-vpn-zombies.sh`'s `EXIT_DEPENDENTS` array and its
  `gluetun-exit`-presence conditional; `scripts/arr-backup.sh`'s
  `tailscale-exit-state`/`gluetun-exit-config` backup entries.
- The corresponding bats coverage (`tests/compose-validation.bats`,
  `tests/vpn-zombies.bats`, `tests/backup-volume-resolution.bats`,
  `tests/ensure-relay-port.bats`) and the e2e exit-node describe blocks in
  `tests/e2e/vpn-security.spec.ts`.
- Doc references in `CLAUDE.md`, `docs/TAILSCALE.md`, `docs/REFERENCE.md`,
  `TODO-home.md`.

**What was live-only state, per §5's pattern, and its current status:**
the NAS-side `tailscale-exit-state`/`gluetun-exit-config` Docker volumes were
backed up then removed directly on the NAS; the offline `tailscale-exit`
node (listed in the tailnet as `arr-stack-vpn-exit`) was deleted from the
Tailscale admin console by the user on 2026-09-05, confirmed gone from the
device list. The `tagOwners`/`autoApprovers.exitNode` question is also
closed — confirmed via the admin console that `arr-stack-router` already
carries `tag:nas-router`, the same tag `autoApprovers.exitNode` already
grants (see §7's table for the closure record). The phone-side check —
confirming `arr-stack-router` is selectable and actively working as the
exit node post-cutover — is also confirmed done (2026-09-05, connected with
LAN access on).
