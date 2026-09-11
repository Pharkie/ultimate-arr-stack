# Quality control map

Where each check in this repository is enforced, and where it is not. One row
per capability, one cell per surface, filled in from what the workflows and
scripts actually run rather than from intent. Phase 6 of the quality plan.

Written 2026-09-11 against `chore/quality-plan`. The tool versions come from a
`project-quality-inventory.sh` run on this Mac; the invocations, pins and gates
come from reading `tests/run-tests.sh`, `tests/mutation/*.sh`, `scripts/pre-commit`,
`.github/workflows/ci.yml` and `.github/workflows/nas-auto-deploy.yml`. When a
cell and a workflow disagree, the workflow is right and the cell is a bug.

## Legend

`YES` runs and gates. `DIAG` runs and reports, and cannot fail the build.
`N/A` deliberately does not run here. `MISSING` should run here and does not.
A bracketed name is the tool's runtime: `[img]` is a pinned container image,
`[sub]` is the vendored `tests/bats-core` submodule, `[host]` is a binary on the
machine, `[script]` is this repository's own shell code.

One `YES` carries an asterisk. `tests/shellcheck.bats` prefers a host
`shellcheck` and falls back to the container image when there is none, so on a
Mac with no Docker daemon and no host `shellcheck` the row is a skip rather
than a verdict. That is the census's job to say out loud, and it does.

## The surfaces

**Local** is `./tests/run-tests.sh` plus the hooks, run by a person. **CI** is
every push and pull request: four jobs in `ci.yml`. **Nightly** is the `heavy`
job, schedule or manual dispatch. **NAS** is `nas-auto-deploy.yml`, manual
dispatch only, which runs a subset on the host it deploys.

`./tests/run-tests.sh` is the entry point on all three hosts. There is no npm
path to it: pi1 and the NAS have no npm at all.

## The map

| capability | Local | CI | Nightly | NAS | kind |
| --- | --- | --- | --- | --- | --- |
| Compose validity, ports, IPs, secrets hygiene, env documentation | YES | YES | N/A | YES | bats `[sub]` |
| ShellCheck over every script and bats file at `error` severity | YES* | YES | N/A | YES | `[host]`, or `[img] koalaman/shellcheck:stable` |
| shfmt formatting | N/A | MISSING | N/A | N/A | `[host] 3.14.1` |
| hadolint (Dockerfiles) | N/A | MISSING | N/A | N/A | `[host] 2.15.1` |
| actionlint on the workflow files | N/A | YES | N/A | N/A | `[img] rhysd/actionlint:1.7.7` |
| `terraform fmt -check` | N/A | YES | N/A | N/A | `[img] hashicorp/terraform:1.9.8` |
| Python modules in `scripts/lib/` | YES | YES | N/A | YES | `[img] tests/toolkit` via `pytest.sh` |
| Regression corpus, entries that guard the change | YES | YES | N/A | YES | `[script] run-mutations.sh` |
| Regression corpus, all entries | YES | N/A | YES | N/A | `[script] run-mutations.sh` |
| Discovery sweep (universalmutator) | MISSING | N/A | DIAG | N/A | `[img] tests/mutation` |
| Coverage within a file (kcov) | DIAG | N/A | DIAG | N/A | `[img] tests/toolkit` |
| Secret pattern scan over tracked files | YES | MISSING | N/A | MISSING | `[script] check-secrets.sh` |
| Dependency and misconfiguration scan (trivy) | MISSING | YES | N/A | N/A | `[img] aquasec/trivy:0.74.0` |
| Container image scan (trivy) | MISSING | N/A | DIAG | N/A | `[img] aquasec/trivy:0.74.0` |
| SBOM (syft, SPDX + CycloneDX) | MISSING | YES | N/A | N/A | `[img] anchore/syft:v1.51.1` |
| Live router segmentation assertions | VLAN20 host only | N/A | N/A | skip | bats `[sub]` |
| E2E through the real services (Playwright) | N/A | N/A | N/A | YES | `[img] tests/e2e` |
| `.env` grammar on the real values | N/A | N/A | N/A | YES | bats `[sub]` |
| Recreate services, wait for health | N/A | N/A | N/A | YES | `[script] nas-auto-deploy` |

Two entries in the Local column are not "the suite does this": the regression
corpus is a separate command that is deliberately not part of `run-tests.sh`
because it runs each entry's oracle twice, and the secret scan is the pre-commit
hook. Both are `YES` because a person running the documented commands gets a
verdict, not because they fire automatically.

## What each surface runs

Local, in the order the documents give them:

```
./tests/run-tests.sh                      # the suite, one entry point
./scripts/pre-commit                      # manually, since git may not fire it
./tests/mutation/run-mutations.sh         # all corpus entries, after touching a guard
./tests/toolkit/pytest.sh                 # only via python-suite.bats, or by hand
./tests/toolkit/coverage.sh               # by hand, once, then read
```

CI, four jobs. `bats suite` runs the whole suite and prints a census of what
executed, what skipped and why. `mutation guards for this change` runs
`tests/mutation/check-changed-guards.sh origin/main`, which selects the corpus
files guarding the changed paths and refuses an unresolvable base or a run where
everything selected was `SKIPPED`. `workflow and terraform lint` runs actionlint
and `terraform fmt -check`, both from pinned images. `supply chain (trivy and
sbom)` runs syft into an artifact and trivy at `HIGH,CRITICAL` with
`--exit-code 1`. All four run on every push to any branch and every PR, and
as of 2026-09-11 all four are required status checks on `main`.

Nightly, the `heavy` job: the full blocking corpus, a time-bounded
`run-generated.sh` sweep and `coverage.sh`, all three non-blocking except the
corpus, plus the image scan. The sweep is bounded at 150 minutes and coverage at
20, against a six-hour job ceiling.

NAS, `nas-auto-deploy.yml`, manual dispatch: the suite, the changed-guard
mutation run, the changed compose files recreated through their own compose
file, a health wait, `tests/env-vars.bats` against the host's real `.env`, the
Playwright suite inside `tests/e2e`'s image, then the merge and a sync of `main`.
It runs after the checkout and before anything on the host is touched, so a red
check stops the run with the host untouched.

## Pins

Every tool a workflow executes comes from a pinned image. That is the rule, and
the pins are: `rhysd/actionlint:1.7.7`, `hashicorp/terraform:1.9.8`,
`anchore/syft:v1.51.1@sha256:95fe0835…`, `aquasec/trivy:0.74.0@sha256:62b1e65e…`,
`koalaman/shellcheck:stable`, `tests/toolkit` and `tests/mutation` by the
Dockerfile's own content hash, and `tests/e2e` as
`mcr.microsoft.com/playwright:v1.50.0-noble` by tag. The two supply-chain
scanners are pinned by digest because a scanner that floats changes what "clean"
means about one commit.

`koalaman/shellcheck:stable` is the one floating tag left in a gate. It is used
by `tests/shellcheck.bats` when no host `shellcheck` is present, which is the
case in CI. A new ShellCheck release can therefore turn a green suite red with
no change to this repository. Pinning it is a one-line change; leaving it is
also defensible, since ShellCheck's own findings are the point of the gate and a
new finding is usually a real one.

## Gaps this map makes visible

Each of these is a decision, not an oversight, and each stays on the list until
someone decides otherwise.

**No secret scan in CI.** The claim in `ci.yml`'s supply-chain comment that
"gitleaks already owns secret scanning at two levels (pre-commit and this
workflow)" is wrong on both counts. No tracked file invokes gitleaks:
`git grep -i gitleaks` matches that comment and nothing else. What actually
scans is `scripts/lib/check-secrets.sh`, a set of `grep` patterns over every
tracked file, wired into the repository's own `scripts/pre-commit`. So secret
scanning happens at exactly one level, and only where that hook fires. Adding
the scan to CI is the obvious fix and is not in this plan; the plan's "do not
add another secret scanner" line assumed one already ran there.

**The pre-commit hook does not fire on this Mac.** `core.hooksPath` is set
globally to `~/.dsh/git-hooks`, and git reads hooks only from that directory, so
`.git/hooks/pre-commit`, which `./setup-hooks.sh` installs correctly, is never
consulted. `tests/hooks-installed.bats` passes because it asserts the symlink,
not that git runs it: the same class of blind spot `docs/TEST-HARDENING-LOG.md`
§2 describes. Re-check with:

```bash
git config --global core.hooksPath                 # /Users/leo/.dsh/git-hooks
ls -la "$(git rev-parse --git-path hooks)/pre-commit"
```

The consequence is local only. It means a secret pattern or a compose conflict
can reach a push unscreened here, and that "the hook is installed" is not
evidence to the contrary. Running `./scripts/pre-commit` by hand before pushing,
or setting `core.hooksPath` per-repository, closes it.

**shfmt runs nowhere.** It is installed on this Mac at 3.14.1 and no script or
workflow calls it. The plan excludes shell formatters deliberately, so this row
is a no, not a gap: formatting is ShellCheck's `error` severity plus review.

**hadolint runs nowhere.** Installed at 2.15.1, unreferenced. The Dockerfile
count is small and four of them are this repo's own builds. Dockerfiles are
covered by the image pinning test and by the trivy image scan for what they
contain, not by a linter for how they read.

**The discovery sweep, coverage and the image scan cannot fail a build.** All
three are `continue-on-error`, which is intentional and worth stating once:
each one's output is a queue of things to read, and the two that could gate
(corpus, bats) already do.

**One trivy rule is suppressed, for four images.** The per-push trivy scan
failed on its first run with six HIGH or CRITICAL misconfigurations and none of
them a defect in a deployed image. `.trivyignore` now suppresses DS-0002, the
root-user rule, once, with the reason for each of the four Dockerfiles it
applies to. Three are this repository's own test images, which write into a
mounted checkout or read the Docker socket and would fail as a non-root user.
The fourth is `duc-service`, which is deployed: nginx binds port 80 inside it
and `startup.sh` drives dpkg-installed cron, so a real fix means `setcap` and a
privilege drop, which changes how a live service starts.

The other two findings were fixed rather than listed. `.devcontainer/Dockerfile`
had the only apt-get without `--no-install-recommends`, and
`stremio-jellyfin/Dockerfile` carried ENV defaults for three variables the
compose service always sets; those lines are gone, which is both the honest fix
and what stops the scanner flagging the image.

Suppressing by rule id is deliberately blunt: DS-0002 is silenced everywhere,
so a new Dockerfile that runs as root will not be reported. That is the trade
this file makes, and it is why each entry carries what would remove it.

**One security assumption in the stack is not what it reads as.** The e2e audit
on 2026-09-11 found that `docker-socket-proxy`'s `EXEC=0` gates the GET exec
endpoints only, while creating an exec instance is a POST and `POST=1` is
enabled for gluetun-recover's restart. A well-formed POST returns 201 with an
exec id. `tests/e2e/operations.spec.ts` asserts the reachable half and carries a
`PROXY-EXEC-REACHABLE` marker, so the test fails with an instruction rather than
passing silently if the proxy is ever fixed. The full finding, including what it
does and does not allow, is in `docs/DEPLOY-WORKFLOW-THREAT-MODEL.md` section 9.

**BSD userland: two guards were fixed, one constraint remains.** The suite is
meant to give the same verdict on the Mac, on pi1 and on the NAS, but the Mac is
the only one of the three with BSD userland, and two tests had picked up
GNU-only spellings that fail there while passing in CI. `shellcheck.bats`'s
scripts-tree check derived its file list with `find -printf`, which BSD `find`
does not have: find exits non-zero having printed nothing, so the test reported
every documented script as stale, which is the opposite of the truth. The same
file built a regex alternation with `paste -sd'|'`, which BSD `paste` reads as a
filename, so the test died on `usage: paste`. Both are fixed and both report
`ok` here.

What remains is the interpreter, not a command. Several suites use `mapfile`,
which is bash 4 and newer, while macOS ships bash 3.2 as `/bin/bash`. The
suite must therefore be started with a 5.x bash on this Mac --
`/opt/homebrew/bin/bash ./tests/run-tests.sh`, or `bash` from Homebrew's bin
ahead of `/bin` on `PATH`. Starting it with `/bin/bash` fails in the discovery
helpers rather than at the first test, which is the confusing part. pi1 and the
NAS both have bash 5, so this is a Mac-only footnote.

The general shape is worth keeping in view: GNU-isms in a guard produce a false
red on one host and a green skip on the others, and neither outcome says
anything about the code.

## Maintaining this file

The map is checkable rather than trusted. Each column is one command:

```bash
./tests/run-tests.sh                                   # Local
grep -nE 'name:|docker run' .github/workflows/ci.yml     # CI and Nightly
grep -nE 'ssh .*NAS_HOST|docker run' .github/workflows/nas-auto-deploy.yml  # NAS
```

If a workflow gains a job or a suite gains a tool, add the row in the same
change. A map that disagrees with the workflows is worse than no map, because it
is read instead of them.
