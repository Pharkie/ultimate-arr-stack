# Test & Deploy Hardening — Project Log

Audited record of the hardening pass merged as `86d5fcf` on 2026-09-01
(branch `fix/nas-sync-silent-failure`, six commits, 13 files, +1651/−69).

**Last updated: 2026-09-01.** Sections 2–6 and 8 are historical and stay true;
**§1 and §7 decay.** Every claim in §1 carries the command to re-check it rather than a
copied value — `docs/EXIT-NODE-PROJECT-LOG.md` learned this by embedding a commit SHA
that its own commit invalidated on landing. If you find a bare number in §1, treat it
as a bug.

Read this before changing anything in `scripts/post-merge`, `scripts/sync-nas.sh`,
`scripts/arr-backup.sh`, or `tests/mutation/`. Its value is not the list of fixes —
those are in the diff. It is the record of **which of this repo's guards turned out
to be incapable of failing**, and the traps that produced them, because every one of
them read as coverage right up until it was watched.

---

## 1. Status at a glance

| | Re-check |
| --- | --- |
| Merged | `86d5fcf`, 2026-09-01, local merge — the `post-merge` hook fired and synced the NAS. `git log --oneline --no-decorate a56d2cc..86d5fcf` |
| pi1 suite | Fully green, 693/693, no exceptions — the 2 pre-existing `jq: command not found` failures closed 2026-09-04 (see §7). `./tests/run-tests.sh` |
| NAS suite | Green at merge. `ssh arr-stack-nas 'cd /volume1/docker/arr-stack && ./tests/run-tests.sh'` |
| Mutation corpus | All killed at merge, none survived. `./tests/mutation/run-mutations.sh` — the count is whatever the corpus holds now, not a number to copy |
| Merge gate | CONTESTED → all findings explicitly accepted or rejected on the record (§6) |
| NAS deploy path | Must be `main`. Re-check the **branch**, not the commit: `ssh arr-stack-nas "docker run --rm -v /volume1/docker/arr-stack:/repo -w /repo alpine/git -c safe.directory=/repo rev-parse --abbrev-ref HEAD"` |

---

## 2. The one defect class

Every bug in this pass is the same shape, and it is worth naming before the list:
**a failure that reports success, or reports the wrong reason.** Not a crash, not a
wrong answer — an `exit 0` and either silence or a cheerful message.

That shape is expensive here specifically because the deploy path is remote. A local
failure gets noticed. A NAS that quietly kept running the old code does not, and the
2026-08-27 outage ran 38 hours on exactly that.

The three stacked deploy bugs are written up in
`docs/TROUBLESHOOTING.md` → *The Deploy Reported Success and Nothing Was Deployed*,
including the check that distinguishes them. Not duplicated here.

---

## 3. Commit-by-commit audit

| Commit | What it changed |
| --- | --- |
| `1c60eb1` | The NAS sync path fails loudly. `sync-nas.sh` no longer `exit 0`s on an unreachable NAS, compares against `origin` before acting, and verifies the **outcome** (NAS branch *and* commit) rather than the exit status of the commands meant to produce it. The `post-merge` hook's `${BASH_SOURCE[0]}` repo-root bug fixed. Mutation framework added. |
| `9156d19` | Every network call in `sync-nas.sh` bounded — `ConnectTimeout=15` on each `ssh`, `timeout 20` on `git ls-remote`. The reachability probe proves the NAS answered *a moment ago*, not that it still will; a bare `ssh` parks on the OS-default connect timeout for ~2 minutes inside a hook that is holding up a merge. |
| `da067a2` | A failed restore in the mutation runner is fatal (exit 3) and keeps the pristine copy, instead of returning 0 and leaving a mutated tree behind. |
| `3f56fd1` | `tests/shellcheck.bats` made capable of running at all (§5.2), and two vacuous-test traps closed. |
| `c479c0d` | Three `scripts/arr-backup.sh` defects (§5.3). |
| `0271c26` | Accepted adversarial-review findings applied. |

---

## 4. The mutation framework, and why it exists

`./tests/mutation/run-mutations.sh` reintroduces a recorded defect into a real file,
asserts the file actually changed, runs the named bats test, and requires it to go
**red**. A mutation that survives means the test cannot fail. Full usage in
`tests/mutation/README.md`.

It is deliberately **not** part of `./tests/run-tests.sh` — it runs the suite twice
per mutation. Run it after touching any guard, and add a corpus entry with any new one.

Corpus: `corpus/nas-sync.sh`, `corpus/backup-and-guards.sh`, `corpus/generative.sh`.
**`tests/mutation/README.md` is the authoritative guide** — design, how to add an entry, and the full write-up of the
lessons summarised below. This section records only what the framework caught here.

### What it caught that human review did not

This is the part worth keeping. Each of these was read, by me and by an adversarial
reviewer, and passed.

1. **A guard that could not fail, at all.** `runner-ignores-a-failed-cp` survived.
   The runner checked `cp`'s exit status *and* compared bytes with `cmp`. Belt and
   braces — except every case where a failed `cp` matters is a case where the bytes
   differ, so `cmp` always fires first and the status check is unreachable. The fix
   was to **delete the guard**, not to write a test for it. A survivor is not always
   a missing test; sometimes it is a redundant guard confessing.
2. **An assertion satisfied by its own fixture.** `runner-vanished-backup-is-silent`
   survived while asserting the output contained `"vanished"` — which it did, because
   the fixture was named `demo-vanishedbackup` and the id was printed inside the
   backup path. The test passed with the guard disabled. Renamed the fixture and
   asserted on `"nothing left to restore"` instead.
3. **A test harness missing the function it was exercising.** The awk-extracted
   harness for `ensure_services_running` never defined `notify_failure`, so the alert
   path died with `command not found` while the test passed. Stubbed, asserted, and
   given its own corpus entry.

### 4.1 The generated half, added 2026-09-01

The corpus can only re-ask a question someone already thought to ask. `run-generated.sh`
is the other half: universalmutator perturbs a file systematically and anything the suite
fails to kill is a gap nobody had to think of first.

**The worked example is the reason this was built.** `grep -Fxq` → `grep -Fq` in the
backup volume resolver survived all 18 tests around it. Whole-line matching was
load-bearing — volume names nest, so a substring match silently mis-resolves and a volume
fails to back up — and nothing proved it. Neither review nor the corpus would ever have
asked. The comment recording it is at `tests/backup-volume-resolution.bats:729`.

The first sweep found the *same defect again*, in a different file: `grep -qx "$var"` →
`grep -q "$var"` in `check-env-vars.sh:46`. With `-q`, an undocumented `${NAS_IP}` passes
because `.env.example` mentions `NAS_IP_RANGE`. Two independent instances of one defect
shape, both invisible to reading, both found the same mechanical way.

It also found that static-IP conflict detection had **no test at all** — both existing
`check_conflicts` tests used ports, and nine mutants across the whole IP half survived —
and that `-gt 1` → `-ge 1` survived because both tests asserted the expected message
appeared while neither asserted the wrong one did not.

40 mutants, 21 killed. Five new tests took it to 35 killed / 5 survived, the five triaged
`wontfix` or `equivalent` in `tests/mutation/survivors.tsv`.

> The survivor ledger shipped a second instance of the same class, caught by the merge
> review rather than by the tool. It was rebuilt from the current run's survivors alone,
> so any run that did not sweep everything — a `-k` filter, a SKIPped target, an ERRORed
> one — silently deleted every row it had not just regenerated. Five hand-assigned
> verdicts were lost. The verification that should have caught it, *"two consecutive
> sweeps produce an identical ledger"*, passed: both sweeps were full ones, so the check
> could not fail. Identity also included the line number, which would have orphaned every
> verdict on the next edit above a mutation. Both are fixed, both are asserted in
> `tests/mutation-framework.bats`, and both have corpus entries.
>
> The extraction of `lib-mutate.sh` — the shared backup/restore core — shipped a bug of
> exactly the class this directory exists to catch, and the corpus caught it on the next
> run. `take_backup` returned its path by echoing it, so every caller wrote
> `backup="$(take_backup ...)"`: a command substitution is a **subshell**, the
> `CURRENT_FILE`/`CURRENT_BACKUP` globals were set inside it and died with it,
> `restore_current` took its legitimate "nothing to restore" branch, and the run finished
> having left five mutated files in the working tree. Reading the diff did not catch it.
> A function whose entire purpose is a side effect on globals now refuses to run where
> those globals go nowhere (`BASHPID != $$`), with a corpus entry proving the refusal
> can fail.

---

## 5. What each fix actually changed

### 5.1 The sync path

`./scripts/sync-nas.sh` now exits non-zero and says **`NAS NOT synced`** for an
unreachable NAS, a local commit `origin` does not have, or a NAS that did not end up
on the intended commit *and branch*. `tests/nas-sync.bats` runs the hook the way git
runs it — cwd at the work tree top, invoked by its path inside the git dir — against
a throwaway repo with a real origin, and asserts on the side effect.

The predecessor test, `tests/hooks-installed.bats`, asserted the symlink existed, was
executable, and pointed at the right target. All three were true for the hook's entire
inert life. **Presence is not behaviour.**

### 5.2 `tests/shellcheck.bats` had never executed on any machine in this project

It skipped when `shellcheck` was absent, and it is absent on pi1 and the NAS both — so
it had been counted as coverage while never once running. Now it falls back to
`koalaman/shellcheck:stable` in a container (the same pattern this repo already uses
for `alpine/git` and the Playwright runner) and skips only when neither is available,
naming which.

Discovery widened from `scripts/*.sh` plus `terraform/apply.sh` to every tracked file
that is a shell script: **16 → 43 files**. Clean at `-S error`. Widening the severity
is a separate deliberate decision, not done here.

What the old glob missed matters more than the count. A shell glob is **not**
recursive, so `scripts/*.sh` never descended into `scripts/lib/` — all **13** check
scripts that `scripts/pre-commit` sources (`check-secrets.sh`, `check-env-vars.sh`,
`check-conflicts.sh`, …) were unchecked, as were `scripts/post-merge` and
`scripts/pre-commit` themselves, both extensionless and both load-bearing.

> Two numbers for this were published wrong before the right one: commit `3f56fd1`'s
> own message says "19 files -> 43", and the first draft of this document said 29. Both
> came from `git ls-files 'scripts/*.sh'`, whose pathspec `*` matches across `/` and so
> counts the `lib/` files the real glob could never see. The correct comparison runs the
> glob the test actually ran: `ls -1 scripts/*.sh | wc -l` → 15, plus `terraform/apply.sh`.
> Checking a proxy instead of the thing itself is the defect class this whole document is
> about, committed while documenting it.

### 5.3 `scripts/arr-backup.sh` — three defects

1. **The exit-trap restart was unbounded and silent.** `ensure_services_running` is
   called from the EXIT trap; a hung `docker compose up -d` held cleanup open
   indefinitely and a failed one was invisible (`2>/dev/null`). Now bounded by
   `SAFETY_TIMEOUT` (default 120s), reports timeout and failure distinctly, and calls
   `notify_failure`. **It still returns 0, deliberately** — see §6.
2. **The staging-dir collision message misreported every other failure.** A `mkdir`
   failure printed *"already exists — another backup may be running"* for a
   permissions error or a missing parent equally. `create_staging_dir` now tests the
   directory's existence to distinguish, and surfaces `mkdir`'s own stderr otherwise.
3. **`BACKUP_DIR` held two different roles.** It was the user's destination for the
   first half of the script, then reassigned partway through to the `/tmp` staging
   path — with `TARBALL` deriving from whichever meaning was current. Split into
   `FINAL_DEST` and `STAGING_DIR`; `BACKUP_DIR` now holds only the destination.
   The two must **stay** separate: the EXIT trap does `rm -rf` on the staging
   directory, and a single shared variable points that `rm -rf` at the user's
   backup destination.

---

### 5.4 The `scripts/lib/*` coverage pass — a separate, later branch

Not part of `86d5fcf`. Recorded here because it closes §7's largest open item and
because every defect below was found by *writing the test*, not by reading the code —
the same result §4 reports for the mutation framework, from the other direction.

Branch `feat/test-coverage-safety-harness`. Eleven new bats files, one per check,
each with a `TARGETS` entry and named corpus entries proving the tests can fail.

| Where | What was wrong |
| --- | --- |
| `check-image-versions.sh` | `stat -f %m \|\| stat -c %Y` — on GNU `-f` is `--file-system`, a valid flag, so the arithmetic that consumed it threw a syntax error that aborted `_cache_get`. The cache was not expiring early; it was **never read**. Every run re-queried all 31 registries and wrote an entry nothing would look at again. Measured: 11 s → 1 s. |
| `scripts/pre-commit` + 2 libs | `((ERRORS++))` under `set -e`. The hook died at its *first* finding, so the message naming the leak, the summary and checks 6–11 were all unreachable. Status 1 was right for the wrong reason. |
| `configure-helpers.sh` | `return "$http_code"`. 404 → 148, 500 → 244 — and `000`, curl's sentinel for *no response at all*, → **0**. Every call site is `if api_post …; then ok "added X"`, so a service that was simply not up was reported as `✓ added`. |
| `check-doc-links.sh` | `return $errors` truncates to one byte (0 at exactly 256), and the path was interpolated into a `python3 -c` string. |
| `check-yaml-syntax.sh` | The staged-file list was word-split on spaces; same `python3 -c` interpolation; same count-as-status. |
| `scripts/check-dns-duplicates.sh` | Deleted. A divergent second implementation of the lib check — different regex, opposite blocking semantics, invoked by nothing. |
| `check-env-backup.sh` | The remediation told the user to recover with `scp`, which does not work against this NAS's BusyBox sftp-server — two lines below the function's own working `ssh … cat`. |
| `check-dns-duplicates.sh` | `grep -qw` — a hyphen is a word boundary, so `sonarr` matched inside `sonarr-4k` and two names pointing at different hosts were reported as a conflict. |
| `common.sh` | Five: `echo -e` over paths; two caches gated by `if $flag` (executing the value); `cut -d= -f2` truncating at a second `=`; the NAS host interpolated into a `bash -c` string; `$NAS_SSH_PASS` unguarded under `set -u`. |
| `check-domains.sh` | `mktemp -d` unchecked at both sites — on failure all fourteen `.lan` names were reported as not resolving, a DNS verdict manufactured from a local filesystem error. |

Four behaviours were **pinned rather than fixed**, each with the reason written into
the test: a failed repo-root lookup is cached like any other answer; the first `.local`
anywhere in `config.local.md` wins; an `.env` that exists but lacks a key does not fall
through to `.env.nas.backup`; and the 20+ tracked SVGs are classified binary and so
never scanned.


## 6. The merge gate, and the two findings rejected

Three gates were run across the branch. The final full three-lens gate returned
**CONTESTED** — three HIGH findings with no reviewer consensus. Seven findings
accepted and fixed in `0271c26`. Two rejected, recorded here rather than silently
dropped:

- **"`create_staging_dir` taking its path as `$1` is inconsistent with the
  surrounding globals."** Rejected. Taking the path as an argument is better than
  reading a global, and it is what makes the function testable in isolation. The
  inconsistency is in the surrounding code.
- **"`ensure_services_running` should return non-zero on failure."** Rejected, and
  this one is load-bearing. It runs under `set -e` from the EXIT trap, where
  `cleanup_on_exit` calls it as `|| true`. A non-zero return there becomes the
  script's exit status — which once made a *successful* backup exit 42, and would
  make a `backup && prune` cron chain skip pruning permanently. The real problem the
  reviewer sensed was the missing signal, not the status; `notify_failure` closes it.

---

## 7. Open items

**This section decays.** Mark an item done in place rather than deleting it — an
"Open items" list that silently loses entries is indistinguishable from one nobody
has touched.

- **DONE 2026-09-04 — the 04:00 cron log redirection.** Applied via
  `sudo crontab /volume1/docker/arr-stack-backups/root-crontab.proposed-20260831-171220`
  after re-verifying the hash unchanged. `sudo crontab -l` confirmed both `@reboot`
  lines intact and the backup line now redirecting to `/var/log/arr-backup.log` with
  a timestamped header per run.
- **DONE 2026-09-04 — `jq` installed on pi1** (`sudo apt install -y jq`), clearing the
  last 2 known failures in the local suite (`tests/credential-propagation.bats`, both
  previously `exit 127`). `./tests/run-tests.sh` now passes all 693 tests with zero
  known-failure exceptions.
- **DONE 2026-09-01 — generative mutation testing installed.** universalmutator,
  containerised and pinned, wired to the bats suite as `run-generated.sh`. See §4.1.
- **DONE 2026-09-01 — every `scripts/lib/` file now has a bats file and a `TARGETS`
  entry.** `common.sh` plus the nine `check-*.sh` that had no test at all, closed on
  branch `feat/test-coverage-safety-harness`. The measurement that made this the
  largest gap in the suite still stands as the reason: `common.sh` swept on the theory
  that being sourced by tested files made it covered produced 78 mutants and survived
  all 78. Nine real defects were found while writing the tests, listed in §5.4.
  The count is deliberately not restated here — `tests/mutation/README.md`'s no-sweep
  list is derived at run time and asserted by `tests/shellcheck.bats`, so it cannot go
  stale the way this bullet just did.
- **DONE — operational scripts (`scripts/*.sh`, `duc-service/app/*`) now have tests.**
  Closed via `feat/test-coverage-safety-harness` (`301085b`), using the PATH stub harness in
  `tests/helpers/stubs.bash` this bullet originally called for, because those scripts restart
  containers for a living. Verified by content (not filename): every script that lacked
  coverage when this bullet was written is now exercised by a bats file, several under a
  differently-named file (e.g. `detect-credential-drift.sh` → `credential-drift.bats`,
  `fix-radarr-paths.sh`/`fix-sonarr-folders.sh` → `fix-arr-paths.bats`).

---

## 8. Traps

Concrete, each one paid for in this pass. The test traps marked ▸ have their full
write-up in `tests/mutation/README.md`; these are the one-line forms.

**Shell**

- **`rc=$?` immediately inside `if ! cmd; then` reads the status of the negation** —
  always `0`. It printed `FAILED (exit 0)`. Capture with `cmd || rc=$?` instead.
- **`echo "$x" | tr -c 'A-Za-z0-9._-' '_'` converts the trailing newline into `_`**,
  silently yielding `<id>_.orig`. Use `printf '%s'`.
- **`timeout` execs its argument**, so it can never run a shell function. A test that
  needs to intercept a `timeout`-wrapped call must put a real executable on `PATH`.
- **A command substitution is a subshell, so a function that "returns" by setting a
  global cannot be called as `x="$(fn ...)"`** — the assignment lands in the subshell
  and dies with it. If the function's whole purpose is a side effect on globals, make
  it refuse to run where they go nowhere (`[[ "$BASHPID" != "$$" ]]`).
- **`trap` replaces, it does not accumulate**, so sourcing a file that installs an EXIT
  trap twice orphans the first one's cleanup. Guard the file against double-sourcing.
- **A `$PATH` stub cannot intercept an absolute path.** `/usr/bin/curl` reaches the real
  binary however carefully `curl` was stubbed. It matters most for the *delegating*
  tools: `ssh host /usr/bin/docker restart x` runs unstubbed on the far side, where the
  harness has no reach at all. `tests/helpers/stubs.bash` refuses any argv word matching
  `^/(usr/)?(local/)?s?bin/` for exactly this reason.
- **`((n++))` returns exit status 1 when `n` is 0**, because a post-increment evaluates
  to the value *before* incrementing and `((0))` is a failure. Under `set -e` the first
  increment of a counter starting at zero therefore kills the shell — and only the
  first, which is why it reads as an intermittent, input-dependent crash rather than a
  syntax error. Use `n=$((n + 1))`, which is always status 0.
- **`set -e` is suppressed for the entire body of a function invoked as an `if`
  condition.** So the same `((n++))` is harmless in `if check_x; then` and fatal in a
  bare `check_x`. A library's correctness ends up decided by a property of its *call
  site* that is invisible where the function is defined — `scripts/pre-commit` had 18
  safe sites and 9 live bugs, identical code in both. Pin the contract the library owes
  *any* caller.
- **Every idiom for CATCHING an errexit abort also PREVENTS it.** `run` clears errexit,
  `if` suppresses it in the callee, and `( set -e; f ) || rc=$?` suppresses it too — a
  subshell that is the left operand of `||` runs with errexit disabled no matter what
  `set -e` it contains. A first probe of this bug "disproved" it three ways for that
  reason. Only a separate process (`bash -c '...'`, status read afterwards) observes it.
- **Command substitution strips trailing newlines**, so `x=$(cmd)` can never end in a
  blank line and a fixture appending one to test a blank-line guard never reaches it.
- **A "portable" `stat -f %m || stat -c %Y` fallback is not one.** `-f` is *format* on
  BSD and `--file-system` on GNU, where it is a valid flag that prints a filesystem
  report to **stdout** and exits 1 — so the `||` fires and appends the real mtime to
  that report. The `$(( ))` consuming it throws a syntax error that aborts the enclosing
  function, so the failure surfaces as "the cache is never read", not as a wrong number.
  Try GNU first (`-c` is simply unrecognised on BSD) *and* check the result is an
  integer, so the ordering argument is not the only thing holding it up.

- **`echo -e` on a path interprets escapes *in the path*.** `get_files_to_scan` combined
  two file lists with `echo -e`, so the two characters `\` and `t` in a filename became a
  real tab and every caller scanned a path that does not exist while the real file went
  unscanned. Git already quotes such a name on the way out, so the mangling happens to
  git's quoted form and produces a third string that matches neither. A filename is data:
  `printf '%s\n'`.
- **`if $flag; then` runs the flag's *value* as a command** — unquoted, so it word-splits
  too. `common.sh` gated two caches this way. Nothing was exploitable, because nothing
  untrusted reached those globals; the point is that the check is a command-execution
  path bought in exchange for nothing over `[[ "$flag" == true ]]`.
- **A value interpolated into a `bash -c` string is code, not an argument.**
  `is_ssh_available` built `bash -c "exec 3<>/dev/tcp/$nas_host/22"`, so bash parsed the
  host name before `/dev/tcp` ever saw it. What kept it safe was a `grep -oE` in
  `load_nas_config` constraining the host to `[a-zA-Z0-9_-]+\.local` — a guarantee living
  in a different function, invisible at the call site. Pass it as `$1`. Same class as
  interpolating a path into `python3 -c`.
- **`cut -d= -f2` truncates a value at its second `=`.** Four sites in `common.sh` parsed
  `.env` lines that way; base64 padding is the everyday value that loses its tail. The
  value is not reported as malformed, it is silently shortened. `-f2-`.
- **`grep -w` treats a hyphen as a word boundary**, so `sonarr` matches inside
  `sonarr-4k`. `check-dns-duplicates` reported a conflict between two names pointing at
  different hosts. Without `-F` the name is compiled as a regex too, so a dot in it
  matches any character. `grep -qxF --` is the form that means "this exact name".
- **An unchecked `mktemp -d` manufactures a verdict rather than an error.**
  `check-domains` left `tmpdir` empty on failure, wrote its markers to the filesystem
  root, found none, and reported all fourteen `.lan` names as not resolving — a DNS
  result produced entirely by a local filesystem error, with nothing in the output
  saying so.
- **`return` truncates to one byte, and `return "000"` is 0.** `return 404` is 148 and
  `return 500` is 244, which is the well-known half. The half that bites is curl's
  `%{http_code}` sentinel for *no response at all*: `configure-helpers.sh` returned it,
  so every service that simply was not up was reported to the user as `✓ added`. An HTTP
  code is not a status; keep it in a variable.

- **An awk *pattern* with no action is a print filter, not a predicate.**
  `echo "$SCHEDULE" | awk 'NF==5'` prints the matching lines and exits 0 whatever it
  matched, so `duc-service/app/startup.sh`'s "invalid schedule" fallback was unreachable
  code and any value at all went into `/etc/cron.d`, where cron ignores a malformed line
  in silence. A predicate needs an action and an `END`: `awk 'NF==5 {ok=1} END {exit
  !(ok && NR==1)}'` — and `NR==1` matters as much as the field count wherever the value
  lands in a newline-delimited file.
- **A cleanup `trap` armed before the resource is acquired cleans up somebody else's
  resource.** `scan.sh` takes a lock with `mkdir` and removes it on EXIT; arm the trap
  one line earlier and the invocation that was correctly turned away deletes the
  *running* scan's lock on its way out. Arm it after the acquisition succeeds, never
  before.
- **`read -p` writes no prompt at all unless stdin is a terminal.** The text is real,
  the branch is real, and no test that feeds stdin from a file or a here-string will
  ever see it — so a test asserting on the prompt fails for a reason that has nothing
  to do with the code.
- **`grep -q` piped from a command run under `set -o pipefail` can fail the pipeline
  even after it finds its match.** `queue-cleanup.sh`'s `get_api_key` did
  `docker ps --format '{{.Names}}' | grep -q "^${container}$"`: `grep -q` exits the
  instant it matches, and if the match is not on the *last* line, `docker ps` can still
  be mid-write when the pipe closes under it — the resulting SIGPIPE gives `docker ps`
  a non-zero exit, which `pipefail` reports as the whole check failing, though `grep`
  found exactly what it was looking for. It read as a flaky test — a bats test with two
  containers stubbed (sonarr first, radarr last) failed on the first check maybe 40% of
  the time and never on the second, because only the non-last name is at risk. Isolated
  with a 200-iteration loop: 123/200 failures checking the first name, 0/200 checking
  the last. Fix: capture the producer's output into a variable before grepping it —
  `running=$(docker ps ...); grep -qx "$container" <<< "$running"` — so there is no pipe
  left to race. The same pattern was still live in two more scripts —
  `configure-apps.sh`'s required-container and SABnzbd checks, `arr-backup.sh`'s
  critical-service check — both found by grepping for the shape rather than assuming
  the one fixed call site was the only one. Same fix in both: hoist a single
  `docker ps` capture above the loop that checks each name.
- **Two independent readers of the same credential can silently drift apart, and the
  one that looks more authoritative isn't necessarily the one still working.**
  `get_api_key`'s `docker exec <container> cat /config/config.xml | grep -oP
  '(?<=<ApiKey>)[^<]+'` read straight from each app's own on-disk config — as
  authoritative a source as it gets, and the regex itself was correct. `.env`'s
  `SONARR_API_KEY`/`RADARR_API_KEY`, read by `fix-radarr-paths.sh`/
  `fix-sonarr-folders.sh` via `env_value()`, is a second, independent copy of the same
  key. On the live NAS the two had drifted apart: `.env`'s key authenticated fine
  against each app's own API, `config.xml`'s extracted key got 401 from both, despite
  neither container having restarted in two weeks and `config.xml`'s mtime landing
  within seconds of each container's boot (ordinary startup housekeeping, not an
  out-of-band edit). The exact byte-level cause was never confirmed — inspecting
  `config.xml`'s raw bytes, even just to check for a stray trailing `\r`, is exactly as
  classifier-blocked as reading it outright — but `env_value()` already strips one
  hazard the `config.xml` reader never guarded against: a trailing `\r` left by a
  CRLF-authored file, invisible in any terminal trace (see its own comment in
  `scripts/lib/env-file.sh`). Fix: stop maintaining two readers of one credential.
  `queue-cleanup.sh` now reads `SONARR_API_KEY`/`RADARR_API_KEY` out of `.env` via the
  same `env_value()` the other two arr-fixer scripts use, and no longer touches
  `docker` at all. Worth remembering generally: when two independent sources of the
  same secret disagree, the one sourced more directly from the "real" system is not
  automatically the correct one — a reader-side bug can corrupt what looks like the
  more authoritative copy just as easily as the credential itself can go stale.

**Test**

- ▸ **`tests/shellcheck.bats` only sees *tracked* files.** A newly written script passes
  it until the moment it is committed, so "shellcheck clean" is not a statement about
  the working tree. Check a new script explicitly, or `git add` it first.
- ▸ **A determinism check between two *identical* invocations cannot fail.** "Two
  consecutive sweeps produce an identical ledger" passed while a filtered sweep was
  deleting rows, because both sweeps were full ones. Vary the thing the invariant is
  supposed to be robust to, not the clock.
- **`^#!.*(bash|/sh)` misses `#!/usr/bin/env sh`** — no `/sh` substring, no `bash`.
  Match the interpreter *word*: `^#!.*\b(ba|da|k|z)?sh([[:space:]]|$)`.
- **`sed -i` is rename-based**, so a running bash keeps its original inode — the
  mutation runner can safely mutate itself.
- **An exit code can be right for the wrong reason.** The pre-commit hook rejected bad
  commits with status 1 for as long as anyone had looked, while every explanation of the
  rejection — the message naming the leaking file, the summary, the error count, the
  later checks — was unreachable. Asserting the status alone would have passed forever;
  what caught it was asserting on *output* and on *how far the run got*.
- **A counter that is written and never read is not bookkeeping, it is a latent abort.**
  `check-hardcoded-domain.sh` kept a `hostname_errors` tally whose only observable effect
  was killing the hook. Deleting it was the fix.
- **Content filters silently exempt fixtures.** `check-secrets.sh:27` skips `*.md`, so a
  planted secret in a markdown fixture is reported "OK" and the test then asserts against
  a check that never ran. Confirm the fixture's *extension* is one the code under test
  actually scans.
- **A skipped oracle reads as a passing one.** TAP spells a skip as `ok N name # skip`,
  so a mutation runner scores the mutant SURVIVED — a coverage gap invented out of an
  environment condition and filed against a test that never executed. Two entries read
  that way here, both because their oracle skips on a dirty `scripts/lib` while the run
  was measuring a fix to `scripts/lib`. `run-mutations.sh` now reports SKIPPED and the
  reason. **Update 2026-09-11:** the generated half had the same hole and kept it longer —
  it captured the skip count `run_tests` returns at both of its call sites and never read
  it, so a target whose oracle skips wholesale on the host being swept would have filed
  every unexamined mutant as a survivor. `run-generated.sh` now refuses at the control
  run, before generating any mutants, and tallies a wholly-skipped mutant run as SKIPPED.
- **A corpus entry whose verdict depends on the ambient tree is worse than none.**
  `gen-dirty-guard-ignores-the-filter` killed while the tree was dirty and survived once
  it was clean, because the condition it needed was ambient rather than constructed. An
  entry must build the state it measures. Where that state is a dirty tree, build a
  throwaway repo — dirtying a tracked file needs a restore, and a restore has an
  interrupt window that has already cost this repo a corrupted ledger once.
- **An over-broad precondition does not merely block, it launders itself into a false
  measurement.** `run-generated.sh` refused to start over targets a `-k` run would never
  touch; downstream that surfaced not as "refused" but as two coverage gaps that did not
  exist.

- **`cut -d= -f2` truncates any value containing a second `=`.** An env-file parser
  wants `${line#*=}`, which keeps everything after the *first* one. A password is
  exactly the sort of value that contains an `=`, and the truncated half fails
  authentication indistinguishably from a wrong password.
- **`return 1` and `exit 1` inside a function look identical from the caller's shell.**
  Both give status 1. Only `exit` kills the caller mid-flight, so its cleanup trap, its
  summary and every later step never run. The status cannot tell them apart; a trailing
  `echo STILLHERE` after the call can.

**Tests**

- ▸ **A tool built to inject pathological code needs a clock on its own oracle.** A
  generative sweep of `scripts/lib/configure-helpers.sh` ran past a 90-minute external
  cap having scored **3 of its 31 mutants**: there was no per-mutant bound, so one
  mutant that made the oracle loop stalled the entire sweep. "This mutant hangs" is the
  expected case for a mutation runner, not an edge one. The budget is now ten times the
  unmutated control run with a 60-second floor — derived, not hardcoded, so a slow
  oracle is not strangled by a number that was right on another machine.
- **A bound that signals only the direct child is not a bound.** `tests/run-tests.sh`
  forks bats, and bats forks a subshell per test, so killing the direct child would
  leave the hung grandchild holding the command substitution's stdout pipe — the caller
  reports 124 and then waits out the full hang anyway. GNU `timeout` puts its child in
  a new process group and signals the group, which is what makes it work. The test that
  proves it deliberately *forks* its hang rather than `exec`ing it, and asserts on
  elapsed time as well as status; an `exec`ing fixture would pass against a bound that
  does not really bound anything.
- **A timeout and a clean red are the same exit status, and very different problems.**
  Both mean the oracle did not pass, so both are kills — but tallying them together
  hides the only thing that explains a sweep's wall-clock moving. They get one counter
  each and a separate line in the summary.
- ▸ **An assertion can be satisfied by its own fixture.** Never assert on a string that
  also appears in the test's own data — especially not the fixture's name.
- **`$TMPDIR` is not `/tmp` under bats**, and `mktemp -d` honours it.
- ▸ **One test for one of nine patterns is not coverage of a nine-pattern file, and it
  reads exactly like it is.** `scripts/lib/check-secrets.sh` — the check that gates
  every commit in this repo — had a single test, against pattern 1, using a captured
  fixture. It passed. Writing the other twenty-seven found three defects it could
  never have seen, all of the same shape as the ones this document already catalogues:

  1. **The placeholder allowlist was applied to the joined set of hits, not to each
     hit.** `match=$(echo "$content" | grep -oE "$pattern")` collects every hit in a
     file into one string, and `echo "$match" | grep -qi '(your|here|example|…)'`
     excuses the whole set if any ONE of them looks like a placeholder. So a single
     `PASSWORD=your-password-here` line disarmed that pattern for every real credential
     in the same file. Measured: a file holding that line plus
     `SSH_PASSWORD=hunter2-Tr0ub4dor-real` made `check_secrets` return 0 and print
     nothing. A test that puts one hit in a file cannot see this — the fixture shape is
     the blind spot, not the assertion.
  2. **Pattern 2 could never fire.** Its allowlist carried `token` as a sixth
     placeholder word, and the allowlist is tested against the whole match — which
     always begins with the literal key name `CF_DNS_API_TOKEN`. A real Cloudflare
     token had passed this check since the day it was written. Generalisable: an
     allowlist word that appears in the *key name* the pattern matches on excuses every
     possible value.
  3. **`return $errors` again.** Third instance in this repo (`check_doc_links` was
     `9cc4b2d`). Exactly 256 findings returned 0. The only caller is
     `if check_secrets; then`, so the count was never read by anyone — the wrap was
     pure downside.

  Two patterns also printed `WARNING` while incrementing the same counter every `ERROR`
  fed, so the hook printed a warning and then blocked on it. The label and the effect
  disagreed, and the only way to tell which warning was the error was to count them.
- **A guard's own false positives get fixed at the fixture, not by widening the
  exemption.** `check-secrets.sh` Pattern 9 flags `_PASSWORD=<15+ non-space chars>` in
  any tracked file and exempts only `tests/fixtures/*`. Realistic-looking fixture values
  in `tests/configure-apps.bats` therefore blocked *every* commit in the repo, not just
  their own file. Adding `tests/*.bats` to the skip list would have been one line — and
  a permanent blind spot in exactly the files where a real credential is most likely to
  be pasted while debugging. Renaming the fixture values to spell `example`, which the
  pattern's existing placeholder allowlist already recognises, keeps the guard armed
  everywhere. `tests/lib-secrets.bats` pins that `.bats` files are still scanned.
- **bats `-f <regex>` exits 0 having run nothing** when the filter matches no test.
  The runner parses the TAP `1..N` plan line rather than trusting the status.
- ▸ **A test extracted from a script with `awk` inherits none of its callees.** Anything
  the extracted body calls must be stubbed, or it dies `command not found` while the
  test reports success.
- ▸ **A test that mutates tracked repo state and restores it with a bare `cp` has a
  window.** `tests/mutation-framework.bats`'s ledger-merge test overwrote the real
  `survivors.tsv` and copied it back at the end. A 2026-09-01 timeout killed the sweep
  in between and left two sentinel rows in the working tree that looked enough like
  real triage output to be committed by accident. The fix is a seam, not a trap:
  `MUTATION_LEDGER` lets the test point the runner somewhere disposable, so there is no
  window to interrupt and no restore that can be skipped.
- ▸ **A test needs its isolation seams in the state its own mutation puts it in, not in
  the state it normally passes in.** `mutation-framework.bats`'s "the generative runner
  refuses to start on a dirty target" asserts a *refusal*, so in its passing state the
  runner never reaches the ledger and `MUTATION_LEDGER` looked unnecessary. The corpus
  entry that proves the guard can fail — `gen-dirty-tree-check-removed` — deletes the
  refusal, and the runner then performs a real sweep and appends real rows to the
  repo's tracked `survivors.tsv`. Observed 2026-09-01: three `unreviewed`
  `check-secrets.sh` rows appeared in a working tree that had run nothing but the
  corpus, and they were indistinguishable from genuine triage output. The seam already
  existed; the test simply did not use it, because in the only state anyone looked at
  it was not needed.
- ▸ **A single-word denylist rule cannot test an ordered-subsequence matcher.** The
  first mutation written against `forbid()`'s subsequence walk targeted the one-word
  `restart` rule and SURVIVED: a one-word rule matches wherever the word appears, no
  matter how the walk is written. Only a multi-word rule with argv in between
  (`compose -f x.yml up`) exercises the property. The test read as though it covered
  it — the mutation is what said otherwise.
- ▸ **A unit that defines `fail()` silently disarms every bats-assert assertion in the
  file that sources it.** bats-assert reports every failure by piping its diagnostic to
  bats-support's `fail`, which returns 1. `scripts/lib/configure-helpers.sh:34` defines
  its own `fail` — an output helper that prints a red cross, increments a counter and
  returns 0 — and `tests/lib-configure-helpers.bats` sources the library into the bats
  shell in `setup()`. Twenty-two `assert_output` calls therefore reported `ok` against
  output that plainly contradicted them, and two entries in
  `corpus/configure-helpers.sh` SURVIVED because the tests written to kill them could
  not go red. Running the suite can never reveal this: the file is green either way.
  Proof is two identical `run echo hello; assert_output --partial "not-present"` tests,
  one with the library sourced and one without — the clean one fails, the sourced one
  reports `ok`. Nothing about it is specific to `fail` or to this library: any name
  bats-assert calls is a live collision. `tests/shellcheck.bats` now derives the
  bats-support/bats-assert name set from the submodules, derives what each test file
  sources, and fails on any intersection — with a corpus entry per direction, including
  one for the discovery returning nothing and "passing" by comparing empty against
  empty. The repair is not to rename the library's function but to assert through
  helpers local to the test file that `return 1` themselves; the 33 tests written
  before this used plain `[ ... ]` and were never affected.

- **Two tests that each assert something is NOT reported are both satisfied by a check
  that reports nothing.** Tightening `check-dns-duplicates`'s match produced exactly that
  shape: one test that `sonarr-4k` is not a conflict, another that a dotted name is not a
  regex. A predicate that never matches passes both. Every test that narrows a check
  needs a paired test that the true positive still fires —
  `dns-match-never-matches` in the corpus exists to enforce it.
- **An injection test whose payload has no observable side effect proves nothing.** The
  first `check-doc-links` mutation SURVIVED because `os.path.normpath("it's/b.md")`
  returns its argument, so the SyntaxError fell through to the `|| echo "$check_file"`
  fallback and both versions produced the identical answer. The payload has to *do*
  something — write a file, whose absence is then the assertion.
- **A test that only asserts on a return value cannot see an argv.** Dropping
  `SSH_OPTS`, `@server`, or `+time=2 +tries=1` changes no result anywhere: the call
  still succeeds against a healthy NAS. What it changes is whether a commit hangs when
  the NAS is down, and whether the answer came from Pi-hole or from the machine's own
  resolver. Assert on what was *asked for* — that is what `$STUB_LOG` is for.

- **A corpus file is *sourced*, so its prose fields are shell.** An unescaped backtick
  inside a double-quoted `--why` runs as a command before any mutation is applied: two
  entries shipped that way and one of them executed `check-vpn.sh || notify` on every
  full corpus run. It found neither name on `PATH`. A prose field naming a real command
  would not have been so lucky. `tests/mutation-framework.bats` now refuses any
  unescaped `` ` `` or `$(` outside `--apply`, which is the one field that is meant to
  be code.
- **`[[ -t 0 ]]` cannot be made true from a test without allocating a pty.** The choice
  is a one-line seam (`stdin_is_tty()`) or leaving the interactive branch — which in
  `check-network.sh` is the one that reaches `docker network rm` — with no test at all.
- **`@` is a poor `sed` delimiter for shell source**, because `"${ARR[@]}"` contains
  one. A mutation whose `s@@@` silently failed to match reported as an ERROR rather than
  a false KILLED only because `run-mutations.sh` checks that the file actually changed.

- **bats' `lines` array silently drops blank lines.** `run` splits `$output` with
  `read -r -a` under `IFS=$'\n'`, and that collapses consecutive delimiters, so a
  28-line help block arrives as 21 elements. `${#lines[@]}` is therefore not a line
  count. Compare `$output` against independently derived text instead — which is the
  stronger assertion anyway, since a count still passes when the block starts or ends
  one line off.
- **A seam added for testability can make the thing it replaced untestable.**
  `CONFIGURE_ENV_FILE` exists so a test can point the script at a fixture — and because
  every test sets it, no test can ever exercise the default it falls back to. A mutation
  of that default is unkillable by construction. Mutate the *call site* instead, and
  write the one test that proves the resolution rule (run it from `/`).
- ▸ **`run` merges stdout and stderr, so a test cannot see which stream a message went
  to.** Moving an error from `>&2` to stdout changed nothing any assertion here could
  observe, and it was the single largest survivor class in the first sweep of the arr
  fixers. For a script cron runs, that is the difference between reaching the operator's
  mail and only ever landing in a log nobody reads. `run --separate-stderr` (and
  `bats_require_minimum_version 1.5.0` at the top of the file) is what makes the stream
  assertable.
- ▸ **When both variants fail, the exit status is not the discriminator — the stream
  is.** A test written to prove `set -e` mattered in `scripts/queue-cleanup.sh` asserted
  only `status -ne 0`, and passed against the mutant: without errexit the script carries
  on, the redirect into the now-empty `$TMPLOG` fails, and the enclosing `if` compound
  returns 1 too. What actually separates them is that errexit aborts silently where the
  other leaves bash's own `: No such file or directory` behind. The test was written to
  catch a "guard that cannot fail" and was one itself until the corpus said so.
- ▸ **Stubbing a tool the harness itself uses breaks the harness, not the code under
  test.** `run --separate-stderr` calls `mktemp` to make its stderr file, so
  `stub_tool mktemp 'exit 1'` failed at the `run` line and looked like a bug in the
  script. Stub conditionally — fail only for the argument the script itself passes, and
  `exec` the real tool otherwise.
- ▸ **A blank-line assertion is vacuous when a second blank line sits next to it.**
  `out[1] == ""` proved nothing about the header's blank line while the library was
  empty, because the summary's blank line was the very next entry. The fixture has to
  put something *between* the two.
- ▸ **A mutation tool will happily rewrite prose, and every one of those mutants
  survives.** universalmutator turned "imported and tested" into "imported and True"
  144 times in one Python module, burying the handful of real findings. `--ignore`
  matches one line at a time and cannot see the interior of a docstring, so the filter
  has to be by line number — `tokenize`, comments plus any multi-line string. Leave
  single-line strings mutable: `RADARR = "http://..."` is code.
- ▸ **An unkillable mutant on a line that is supposed to do something is a finding, not
  a coverage gap — the line is dead.** Three times in this pass: five unused helpers in
  `queue-cleanup.sh`, and `fix_sonarr_folders.py`'s `[tvdbid-{TvdbId}]` replacement,
  which could never fire because the `{TvdbId}` substitution five lines above already
  rewrites the token inside the brackets. Reading the file caught none of them.
- ▸ **Injecting a seam everywhere hides the thing behind it.** Every test of both arr
  fixers passed in a fake updater or a fake API, so the code that actually talks to
  Radarr and Sonarr — the `-X PUT`, the `?moveFiles=true`, the API-key header — had
  never been constructed once, and the sweep said so in about forty survivors. A seam
  needs its own test on the real side of it.
- ▸ **`sys.exit(main(sys.argv))` is unreachable from any import-based test**, so with it
  deleted the script exits 0 having done nothing — indistinguishable from a clean run to
  the bash half. It takes an actual subprocess to pin, with arguments chosen so the
  module dies before it can reach the network.
- **An argv-type mismatch across a process boundary is invisible on both sides.** The
  bash half wrote `true`/`false`; the Python half compared against `"True"`, so
  `--apply` was inert and every run reported a dry run's output. Neither file is wrong
  read on its own. Moving such a boundary (a heredoc to a real module) deserves a proved
  equivalence — byte-identical stdout, stderr and status against the same fixture —
  rather than an assurance.

**Operational**

- **A no-op that returns success is indistinguishable from work completed.**
  `duc-service`'s poller deleted the "scan requested" marker and then called `scan.sh`,
  which exited 0 without scanning whenever a scheduled scan happened to hold the lock.
  The request was gone, no error was produced anywhere, and the user's manual scan
  simply never happened. Give "I did nothing" its own exit status and let the caller
  clear the claim by the *outcome*, not on the way in.

- **`backup-prune.sh` uses `find "$DIR" -maxdepth 1`** and never descends. Anything
  written to a *subdirectory* of the backup root is retained forever by nobody's
  policy. Two 139 MB verification tarballs were parked in `scratch-verify/` during
  this pass and had to be removed by hand. See also the general hazard: two retention
  policies pointed at one directory.
- **"18 backed up" against 17 archive directories is not a defect.** `.env` /
  `dot-env` increments `BACKED_UP` alongside the 17 volumes (`arr-backup.sh:748`).
  Recorded so nobody re-investigates it.
- **A fixed path in a world-writable directory is a shared mutable resource.**
  `configure-apps.sh` kept its qBittorrent session cookie at `/tmp/qbit_configure_cookie.txt`
  with no `trap`: two concurrent runs clobbered each other's session, every early return
  left a live cookie readable by anything on the box, and there are a dozen early returns.
  `mktemp` plus an EXIT trap is what makes "we always clean up" true rather than intended.

- **A test harness that bounds time but not memory will eventually bound the whole
  machine.** `run-generated.sh` caps a mutant's wall clock and says so in its own
  comment: "this mutant loops forever" is the expected case. It is not the worst
  case. The generated mutant `scripts/lib/queue_cleanup.py:209 break ==> continue`
  turned the max-pages guard into a loop that extended `all_records` *and* emitted a
  pytest-captured log line every iteration — two unbounded allocations per pass. It
  exhausted this 1.8 GiB host's RAM and swap and **rebooted the machine**, twice,
  deterministically, at the same mutant, each time destroying ~30 minutes of sweep
  and leaving no ledger. The failure was invisible in exactly the way that costs
  most: the sweep log ends mid-run with no summary, which is indistinguishable from
  an agent teardown or a Ctrl-C, and the first loss was misattributed to precisely
  that. `uptime` was the diagnostic that settled it, and it is now the first thing
  to check when a long local job vanishes without a trailer.
- **`docker run --memory` is accepted and ignored on a host with no memory cgroup.**
  pi1 boots with `cgroup_disable=memory` in `/proc/cmdline`, so cgroup v2 exposes
  only `cpuset cpu io pids`. The obvious containment for the trap above is therefore
  decorative here — it would have read as a fix in review, in the diff, and in the
  Dockerfile, and protected nothing. `ulimit -v` (RLIMIT_AS) is enforced per process
  by the kernel with no cgroup and no privilege, which is why `tests/toolkit/pytest.sh`
  uses it. Check `/sys/fs/cgroup/cgroup.controllers` before believing any
  resource limit on this host.
- **The cap has to be proved from inside the process it caps.** Asserting that
  `pytest.sh` *contains* a `ulimit` line is the presence-is-not-behaviour trap this
  document opens with. `tests/python/test_oracle_environment.py` instead reads its own
  `RLIMIT_AS` back at run time and fails if it is `RLIM_INFINITY`, so deleting the
  cap turns the suite red rather than quietly removing the blast door. Corpus entry:
  `oracle-address-space-uncapped`.
- **The containerised cap doesn't reach the native path, and `run_tests()` in
  `tests/mutation/lib-mutate.sh` is where every mutant scores** — bash-side targets as
  much as the Python ones that route through `pytest.sh`'s container. A native bats
  file never goes through docker, so pytest.sh's cap simply does not apply to it. Found
  by adversarial review of the writeup for the trap above, not by a second incident —
  the review asked whether the fix covered every path the mutant could take, and it
  didn't. Closed with a sibling `ulimit -S -v` around `run_tests()`'s own invocation,
  proved the same way: `tests/mutation-framework.bats`'s `run_tests bounds the
  oracle's memory...` test reads the limit back from inside a fake oracle process via
  a side-channel file (`run_tests` only ever echoes its own summary triple, never the
  oracle's stdout — an early draft tried to read it from bats' `$output` and always
  passed for the wrong reason). Corpus entry: `oracle-native-address-space-uncapped`.
- **`ulimit -v N` without `-S`/`-H` sets the HARD limit too, and a hard limit can never
  be raised again by anything downstream.** `run_tests()` calls itself on every
  mutant, including the control run — so the very first (unmutated) call permanently
  capped the hard ceiling for the whole process tree before a mutated run predicated
  on that same guard ever got a chance to prove anything. The corpus entry for the
  guard was unwinnable for exactly this reason: `ulimit -v unlimited` inside the test
  fixture only raises the *soft* limit, which stays bounded by whatever hard ceiling
  an ancestor already set. Fixed by capping soft-only (`ulimit -S -v`), which is also
  the more correct mechanism on its own merits — RLIMIT_AS enforcement reads the soft
  limit, and nothing here needs an irrevocable hard cap.
- **A Go binary reserves virtual address space up front, independent of what it
  actually uses — so `ulimit -v` and the `docker` CLI are fundamentally at odds.**
  Measured 2026-09-02: `docker version`/`docker info` fail under a 256 MB, 512 MB, or
  even 1 GiB cap, and only succeed at 2 GiB+ — which exceeds this host's entire
  1.8 GiB of physical RAM. Applying `run_tests()`'s new native cap blanket-wide broke
  every bats file that shells out to a real `docker` daemon (`tests/python-suite.bats`,
  `tests/shellcheck.bats`'s fallback, `tests/coverage-tool.bats`,
  `tests/mutation-framework.bats`'s own docker-availability checks) — surfaced as a
  silent, wrong-reason `SKIPPED` on the pre-existing `oracle-address-space-uncapped`
  entry, not a crash, which is its own instance of this document's opening defect
  class. No cap value serves both goals at once, so `NATIVE_MEM_EXEMPT` in
  `lib-mutate.sh` exempts exactly the bats files that genuinely need a real daemon,
  each for a stated reason (either the workload is already capped independently
  inside its own container, or it's a fixed tool invocation with no mutable target of
  its own) — a hardcoded, read-and-verified list rather than a live `grep`, so a new
  docker-shelling file added later fails loudly under the cap instead of silently
  slipping past an exemption nobody wrote for it.
- **A bare redirection on its own line is a complete (no-op) command, and if it's the
  last thing in a command substitution, its own exit status — always 0 — overwrites
  whatever came before it.** `run_tests()`'s native-cap rewrite put `2>&1` on its own
  line after an `if/fi` block inside `out="$( ... 2>&1)"`; bash parsed that as a
  distinct null command, so `$?` after the substitution was always 0 regardless of
  whether the wrapped test suite passed or failed. Every SURVIVED/ERRORED result from
  the native-cap corpus entries during this fix was actually this bug, not the
  mutation logic — three different entries went green for three unrelated reasons
  until the actual test bodies were run by hand outside `run_tests()` and compared.
  Fixed by wrapping the guarded commands in a brace group and redirecting the group:
  `{ cmds...; } 2>&1`, so the group's own exit status (the last real command run
  inside it) is what reaches `$?`.
