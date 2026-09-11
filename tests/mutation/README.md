# Mutation testing

A test that cannot fail is worse than no test, because it is counted as
coverage. This directory holds the machinery for proving each guard in the
bats suite can actually fail, and a corpus recording the specific defects each
one is supposed to catch.

## Why it exists

Four separate times in this project a test was written, reviewed, and merged
while being incapable of failing:

- the `EXTRA_LAN_SUBNETS` grammar guard passed on a trailing comma and on a
  space-separated list, because two silent normalisations upstream of the
  assertion discarded exactly the malformed input it was checking for;
- the deploy-workflow ordering assertion was satisfied by a **fully
  commented-out** validation step;
- `a failing worker teardown does not stop the staging dir from being removed`
  called the handler as `cleanup_on_exit || true` — precisely the position
  where `set -e` does not fire — so it passed against the mutation it exists
  to catch;
- three of the volume-resolution tests were being rescued by a neighbouring
  code path rather than testing the matcher they named.

None of these were caught by reading the tests. In every case they read
correctly. Breaking the thing they guard and watching them stay green is what
found them.

## Two runners, two jobs

|  | `run-mutations.sh` | `run-generated.sh` |
| --- | --- | --- |
| Kind | regression | discovery |
| Mutations | a corpus of defects someone wrote down | generated systematically by universalmutator |
| Answers | "can this guard still fail?" | "what is not guarded at all?" |
| Blocking | **yes** — non-zero on any SURVIVED/ERRORED | **no** — always exits 0 |
| Output | a verdict per corpus entry | `survivors.tsv`, to be triaged by hand |

The corpus can only ever re-ask a question someone already thought to ask; every
entry in it is a bug that was written down after the fact. Generation asks the
questions nobody thought of. Both are needed, and neither substitutes for the
other.

Generation is non-blocking **by design**. Some generated mutants are
*equivalent* — they change the text without changing behaviour — and no test can
ever kill them. A discovery tool that wedges the workflow on an irreducible
false-positive rate gets disabled, and then it finds nothing at all.

## Running it

```sh
./tests/mutation/run-mutations.sh                      # every corpus
./tests/mutation/run-mutations.sh -k sync              # ids containing "sync"
./tests/mutation/run-mutations.sh tests/mutation/corpus/nas-sync.sh

./tests/mutation/run-generated.sh                      # sweep every target
./tests/mutation/run-generated.sh -k check-conflicts   # one target
```

`run-mutations.sh` exits non-zero if anything SURVIVED or ERRORED. Neither is
part of `./tests/run-tests.sh`: they run the bats suite once or twice per
mutation, so they belong to the "changed a guard, or about to trust one" moment
rather than to every commit.

Both share `lib-mutate.sh`, which owns the backup/restore discipline. That is
one file on purpose — a second copy of restore logic would drift, and the copy
that drifted would leave a mutated file in the tree looking like an ordinary
edit.

## The generated half

`mutator.sh` runs universalmutator in a container (`tests/mutation/Dockerfile`,
image and package both pinned). pi1 cannot install it on the host: no pip, no
pipx, PEP 668, and `ensurepip` ships no bundled wheels, so even `python3 -m venv`
cannot bootstrap. Containerising is this repo's standing answer for tools the
host lacks — `alpine/git`, `koalaman/shellcheck`, the Playwright image.

The repo is never bind-mounted. universalmutator writes scratch files into its
working directory, so the target is copied into a throwaway directory instead:
the container cannot reach anything it was not handed.

`shell.rules` is the ruleset. universalmutator ships nothing for bash and its
`universal.rules` fallback is arithmetic-centric — on shell it mutates the
shebang into `#!+bin/bash`. Note that passing `none` as the language does **not**
disable the built-in rules; only `--only shell.rules` does. Measured on
`check-secrets.sh`: `none` alone produced 119 mutants, all of them noise.

### A skipped oracle is refused, in both halves

TAP spells a skip as `ok N name # skip reason`, so an oracle that skipped
*wholesale* exits 0 and looks exactly like one that ran and passed. A mutant it
never examined would be scored SURVIVED and merged into the ledger — a coverage
gap invented out of an environment condition, filed against a test that never
executed. `run-mutations.sh` has refused this since §8 of
[docs/TEST-HARDENING-LOG.md](../../docs/TEST-HARDENING-LOG.md) recorded it; the
generated half captured the same skip count from `run_tests` at both call sites
and never read it, so a target whose oracle skips on the host being swept (the
NAS, for anything git-gated) would have filed every unexamined mutant as a
finding. Since 2026-09-11 `run-generated.sh` refuses at the control run — before
generating anything, so a host that cannot judge a target does not pay to
generate its mutants — and tallies a wholly-skipped mutant run as SKIPPED.

### Triaging a survivor

Survivors land in `survivors.tsv` as `unreviewed`. Each gets one of:

| verdict | meaning |
| --- | --- |
| `real-gap` | the suite genuinely cannot see this defect |
| `equivalent` | the mutation does not change behaviour; nothing can kill it |
| `wontfix` | real but unreachable in practice; the note must say why |
| `unreviewed` | not yet looked at |

A `real-gap` gets a test written, **and then a corpus entry**, so the new test is
itself proved capable of failing.

The ledger is merged, never rebuilt, along both axes:

- a row whose target was **not swept** by this run is carried through untouched,
  so a `-k` filter, a positional target, or a target that SKIPs for want of
  docker cannot delete verdicts it never looked at;
- a row whose target **was** swept keeps its verdict if the same mutation is
  still found, and is dropped if it is not.

Identity is `(file, mutation text)`. The line number is a separate column and is
deliberately **not** part of the key: line numbers shift the moment anything is
inserted above a mutation, and an identity that included one would silently
orphan every hand-assigned verdict on the next edit.

> Both halves of that were paid for. The first version rebuilt the file from the
> current run's survivors alone, so a filtered run deleted every row outside the
> filter — five triaged verdicts, lost silently. The "two consecutive sweeps
> produce an identical ledger" check could not see it, because both sweeps were
> full ones. `tests/mutation-framework.bats` now asserts both directions, with
> corpus entries proving each assertion can fail.

### First sweep, 2026-09-01

40 mutants across the three covered `scripts/lib/` files: 21 killed, 19 survived.
Writing five tests for the survivors took it to **35 killed, 5 survived** — the
remaining five are triaged `wontfix`/`equivalent` in the ledger.

Two of those were real, and both are this repo's recurring shapes:

- **`grep -qx "$var"` → `grep -q "$var"`** in `check-env-vars.sh` survived. This
  is the *same defect* generation already found once here, in the backup volume
  resolver (`grep -Fxq` → `grep -Fq`). Whole-line matching was load-bearing in
  both places and proved in neither: with `-q`, an undocumented `${NAS_IP}` is
  considered documented because `.env.example` mentions `NAS_IP_RANGE`.
- **Static-IP conflict detection had no test at all.** Both pre-existing
  `check_conflicts` tests used ports; nine mutants across the entire IP half
  survived. CLAUDE.md pins static IPs precisely because a collision is silent
  until a container restarts onto an address something else holds.

A third was subtler and worth its own line: `-gt 1` → `-ge 1` survived because
both tests asserted that the *expected* message appeared and neither asserted
that the *wrong* one did not. Getting the right output is not proof — the check
also has to not emit the wrong one.

### Measured kill ratios

Recorded per target and dated, because a ratio with no date is a claim about a
tree that no longer exists. Two ratios are given: the raw one, and the one
against *killable* mutants — a mutant verdicted `equivalent` in the ledger
cannot be killed by any test, so counting it against coverage would set a floor
nobody can reach.

| Target | Swept | Kept | Killed | Survived | Killable |
| --- | --- | --- | --- | --- | --- |
| `scripts/lib/check-secrets.sh` | 2026-09-01 | 11 | 8 | 3 (all `equivalent`) | **8/8** |
| `scripts/lib/configure-helpers.sh` | 2026-09-01 | 31 | 23 | 8 (all `equivalent`) | **23/23** |
| `scripts/lib/env-file.sh` | 2026-09-02 | 8 | 8 | 0 | **8/8** |
| `scripts/queue-cleanup.sh` | 2026-09-02 | 25 | 19 | 6 (all `equivalent`) | **19/19** |
| `scripts/fix-radarr-paths.sh` | 2026-09-02 | 15 | 15 | 0 | **15/15** |
| `scripts/fix-sonarr-folders.sh` | 2026-09-02 | 11 | 10 | 1 (`equivalent`) | **10/10** |
| `scripts/lib/fix_radarr_paths.py` | 2026-09-02 | 113 | 112 | 1 (`equivalent`) | **112/112** |
| `scripts/lib/fix_sonarr_folders.py` | 2026-09-02 | 110 | 108 | 2 (both `equivalent`) † | **108/108** |
| `scripts/lib/queue_cleanup.py` | 2026-09-04 | 372 | 371 | 1 (`equivalent`) | **371/371** |

† Point-in-time measurements from the date in `Swept`, not a live view. `survivors.tsv` is the
ledger and the authoritative record, and it has since gained a third row for
`fix_sonarr_folders.py` (`:125`, `out("") ==> pass`), triaged `real-gap` on 2026-09-10 and closed
with an assertion in `tests/python/test_fix_sonarr_folders.py::test_the_dry_run_summary_says_it_is_a_dry_run`
plus the `sonarr-blank-line-separator-removed` corpus entry. That is why the `Survived` column here
and the row count there can disagree: re-sweep to refresh a ratio, never edit this table from memory.

The four 2026-09-02 rows are the arr fixers, and they took two rounds to get
there: the first sweep killed 36 of 61 (59%). Nine of the survivors were real
gaps and got tests; the largest single class was assertions that could not see
which *stream* a message went to, because `run` merges stdout and stderr. For a
script cron runs, that is the difference between reaching the operator's mail
and only ever landing in a log nobody reads.

Two more survivors closed on a second pass, and both are worth naming because
neither changed an exit status — the usual thing a test asserts on. `-gt` →
`-ge` on the log trim rewrites a live log with a byte-identical copy, so only
the fact that a temp file was made at all can catch it. `-f` → `-e` on the same
guard lets a directory reach `wc -l <`, which prints a 0 *and* fails, so the
`|| echo 0` appends a second one and the arithmetic test throws — same status,
same skipped trim, one bash error in the cron log.

The three `.py` rows are the modules those scripts became, and they are the
first targets swept with universalmutator's own `python.rules`. Two things had
to be fixed before the numbers meant anything. The first was that a mutation
tool will happily rewrite prose: `fix_sonarr_folders.py` generates 561 mutants,
318 of them inside comments and docstrings, every one of which survives by
construction and buried the 110 that are actually scoreable. `--ignore` cannot see a docstring's
interior — it matches one line at a time — so the filter is by line number, from
`tokenize`: COMMENT tokens, plus any STRING spanning more than one line. Single
-line strings stay mutable, because `RADARR = "http://..."` is code.

The second is what the surviving mutants then said, and all three modules said
it identically: **every test injected the seam, so the thing behind it had never
been constructed.** Each module has a class that shells out to curl — `ArrApi`,
`SonarrApi`, `curl_updater` — and every `run()` test passes in a fake, which is
what makes those tests fast and hermetic. It also meant the whole curl argv
could be replaced with `["curl"]`, or `[]`, and nothing went red. `main()` was
unreached for the same reason, and `sys.exit(main(sys.argv))` cannot be reached
by an import-based test at all; it needs a real subprocess, invoked with
arguments chosen so the module dies before it can reach the network.

One survivor was not a gap and not an equivalent: a third thing. In
`fix_sonarr_folders.py` a `[tvdbid-{TvdbId}]` replacement could never fire,
because the `{TvdbId}` substitution five lines above had already rewritten the
token inside the brackets. Nothing could kill it because there was nothing to
kill — the line was dead, and deleting it was the fix. That is the third time
in this repo an unkillable mutant turned out to mean dead code rather than an
equivalent one, which is worth remembering before reaching for the
`equivalent` verdict.

`scripts/queue-cleanup.sh`'s six remaining survivors are all in or around
`get_api_key`, and all six were measured rather than argued: the function
writes the key to stdout before it returns, and every caller discards its status
through `|| true`, so no reachable combination of `return 0`/`return 1`/`&&`/
`||` changes the key the caller ends up with. An absent container and an empty
key already converge on the same "Could not get API keys" exit.

Both files' survivors are the same shape: `cmd || true` → `cmd && true` on a
line whose exit status nothing reads. In `check-secrets.sh` every call site is
an `if` condition, which suppresses errexit for the whole call *including the
callee's body*; in `configure-helpers.sh` the entry point sets `set -uo
pipefail` and deliberately no `-e`. Neither is a coverage gap, and neither can
be closed by writing a test — the ledger says so, with the empirical check that
established it.

`configure-helpers.sh` is also the target that motivated the oracle's time
budget: one mutant (`|| true` → `&& true` inside `wait_for_service`'s HTTP-code
test, `:109`) makes the wait loop unsatisfiable, and the unbounded sweep spent
90 minutes on it. It is now killed at the budget, and the summary says so.

`scripts/lib/queue_cleanup.py` is the fourth `.py` target, swept later than the
other three and for a reason worth recording on its own: the first attempt at
this sweep rebooted the host twice (see `docs/TEST-HARDENING-LOG.md` §8 and the
`oracle-memory-cap` corpus entries) and had to wait on a memory cap for both
the containerised and native oracle paths before it could run at all. Once it
ran, all nine of its survivors were the same shape: an `out(...)` line the
oracle's tests never captured, so the mutant's `pass` produced no observable
difference to anything a test actually checked — the header line, the queue-size
line, the removal/reason/failure lines, the search-summary line, and one early
`return 0, 0` whose fallthrough happened to reach the same return value by a
different path. The fix in every case was the same one-line addition: the file
already runs every scenario through `out=lines.append`, so each gap closed by
adding an `assert any(... in line for line in lines)` rather than by writing
new test infrastructure. The remaining survivor, `_age_hours`'s `114 return
None ==> pass`, is the same equivalent shape as `fix_radarr_paths.py:70` above
— the last statement is already `return None`, so falling off the end returns
it just the same.

## Targets with no oracle

Mutation testing needs a test as its oracle. Against a file with no tests, every
mutant survives by construction — that is not a finding, it is a restatement of
"this file has no tests", and a few hundred guaranteed survivors would bury the
real signal. So the sweep covers only files that have one.

`scripts/lib/common.sh` was swept once on the theory that being sourced by three
tested files made it covered. **78 mutants generated, 78 survived, 0 killed.**
Sourced is not covered: the four `pre-commit-checks.bats` tests exercised none of
its NAS, SSH, or domain helpers. It has an oracle of its own now
(`tests/lib-common.bats`) and is swept; it stayed off `TARGETS` until it did,
because a target with no tests contributes nothing but guaranteed survivors.

Every file under `scripts/lib/` is swept as of 2026-09-01. What is left below is
operational scripts — the ones that restart containers, so they need the stub
harness before they can have an oracle at all.

### What is not swept

The list below is every tracked production shell file with no `TARGETS` entry,
which is to say every one a generated mutant could not be scored against.
Some of them do have bats tests and are simply not swept yet; others have no
test at all. The list does not distinguish the two, because only the first is
mechanically knowable — "has a test" has no honest definition here, as
`setup-hooks.sh` demonstrated, for as long as it was *named* by a bats file that
only asserted the hook symlinks already existed and never ran the script that
creates them.

There is no count written down, and the list is not maintained by hand. It is
derived from field 1 of `TARGETS` at run time by
`tests/shellcheck.bats`, which fails if the two disagree in either direction.
The previous version of this paragraph was a hand-written count that went stale
the day the first of those tests was written, which is the same way `CLAUDE.md`'s
old "14 tests" claim went stale.

<!-- NO-SWEEP-ORACLE: asserted by tests/shellcheck.bats; do not edit by hand -->
- `duc-service/app/duc.cgi`
- `duc-service/app/log.cgi`
- `scripts/arr-backup.sh`
- `scripts/backup-prune.sh`
- `scripts/detect-credential-drift.sh`
- `scripts/detect-vpn-zombies.sh`
- `scripts/post-merge`
- `scripts/pre-commit`
- `scripts/sync-nas.sh`
- `terraform/apply.sh`
<!-- /NO-SWEEP-ORACLE -->

## The stub harness, and why it has its own corpus entries

`tests/helpers/stubs.bash` puts real executables named `docker`, `curl`, `ssh` and
`git` at the front of `$PATH` so a test can drive an operational script without the
script reaching a live daemon. It is the only thing standing between
`tests/restart-stack.bats` and a `docker compose up` against the NAS that serves the
house's DNS.

That makes it a guard, and this repo's whole reason for owning a mutation framework is
that four guards were merged here while being incapable of failing. So the harness is
mutated too, in `corpus/stub-harness.sh`: neuter `forbid()`, remove the absolute-path
rule, silence the breadcrumb, require adjacency in the verb matcher — each one must
turn a named test red. Mutating it is safe to run, because with the denylist disabled
the `docker` stub still runs and that stub does nothing but print and exit 1.

Two rules that are easy to get wrong, both learned here:

- **Match the argv array, not the joined command line.** Word comparison is what lets
  `docker  compose   up` (doubled spaces) trip while `./scripts/restart-stack.sh` does
  not. A substring denylist would refuse to let a test so much as name the script it
  is testing.
- **Reserve an exit status.** `forbid()` exits 99, which none of these tools return. A
  test that means to reach a forbidden call asserts 99 *and* the breadcrumb file; a
  bare `assert_failure` would pass if the script had died for any reason at all.

The breadcrumb exists because the status alone is not enough: a `|| true` or an `if`
in the script under test swallows it. The file does not get swallowed.

## What the runner refuses to do

Each of these is a way a mutation run can report a green result while proving
nothing, and each is a hard ERROR rather than a verdict:

| Refusal | The trap it closes |
| --- | --- |
| the mutation left the file byte-identical | a pattern that stopped matching after a refactor scores a false KILLED. An earlier harness in this project reported **five** passes this way, because its own `cmp` guard inverted its exit status. |
| `--test` matched no tests | `bats -f` exits 0 having run nothing, which is indistinguishable from a pass. |
| the test was already failing unmutated | a red test failing again says nothing about the mutation. |

The target is restored from a byte copy through an EXIT trap and re-checked
with `cmp`, so an interrupt cannot leave a mutated file in the tree — which
would look exactly like an ordinary edit.

**A restore that fails is fatal, in both directions.** The first version of the
runner was not: it printed `FATAL`, carried on, and could still finish with
every mutation KILLED and exit 0 while a mutated file sat in the tree. It then
`rm -rf`'d the backup directory the message had just named as the thing to
restore from. A run that cannot put a file back now exits 3, stops immediately
rather than mutating the next target on top of a tree it could not repair, and
keeps `$WORK`. A backup that has *vanished* is treated the same way, not as
"nothing to restore" — those two were one condition, and both returned 0.

That defect was found by an adversarial review of this very directory, which is
the honest version of the lesson: the tool built to catch silent failure shipped
failing silently. Its own tests are in `tests/mutation-framework.bats` and its
own mutations are at the bottom of `corpus/nas-sync.sh`.

`tests/mutation-framework.bats` holds the runner to its own standard: it is
proved able to emit KILLED, SURVIVED, and all three ERRORs against a fixture
built for the purpose. A mutation runner that cannot report SURVIVED is worse
than none — it turns every vacuous test in the suite into a certificate.

## The oracle runs on a clock

Every mutated oracle run is bounded. The budget is **ten times the unmutated
control run, with a 60-second floor**, computed per mutation rather than
hardcoded, so a slow oracle gets a proportionally longer rope and a fast one is
never strangled by a fixed number that was right on somebody else's machine.

This was not a precaution. A generative sweep of
`scripts/lib/configure-helpers.sh` on 2026-09-01 ran past a 90-minute external
cap having scored **3 of its 31 mutants**; there was no per-mutant bound at all,
so one mutant that made the oracle loop stalled the whole sweep, and only a
`timeout` outside the tool ended it. For a tool whose entire job is injecting
pathological code, "this mutant hangs" is the expected case, not an edge one.

A run that hits the budget comes back as status 124 and is scored a **kill** —
the oracle demonstrably did not pass — but it is tallied and printed separately
(`of those, N hit the oracle time budget`). A hang and a clean red are the same
exit status once the bound fires, and folding them together would hide the only
thing that explains a sweep's wall-clock moving.

Two implementation details are load-bearing and both are asserted:

- **`timeout` wraps `tests/run-tests.sh`, not a shell function.** `timeout`
  execs its argument, so wrapping a function does nothing at all (recorded trap,
  `docs/TEST-HARDENING-LOG.md` §8).
- **The whole process group has to die.** `run-tests.sh` forks bats, and bats
  forks a subshell per test, so signalling only the direct child would leave the
  hung grandchild holding the command substitution's stdout pipe — the bound
  would report 124 and still wait out the full hang. GNU `timeout` puts its
  child in a new process group and signals the group, which is why this works;
  `tests/mutation-framework.bats` drives it against a runner that *forks* its
  hang, for exactly that reason, and asserts on elapsed time and not just status.

`ORACLE_BUDGET_FLOOR` exists only so that the timeout-scoring branch can be
watched firing in seconds instead of a minute. Nothing outside `tests/` sets it.

### Which tool does the bounding

`timeout` is GNU coreutils, and macOS does not ship it. `lib-mutate.sh` resolves
one of `timeout`, `gtimeout`, or a `perl` fallback at source time, and the
runners refuse to start (exit 77) if a host has none of the three, because the
alternative is not "no bound", it is a **lie**: the budget went to a missing
binary, the command substitution came back 127 (*command not found*), and both
runners read any non-zero status as a failing test and scored the mutant
KILLED. Measured 2026-09-11: all 19 entries of the `check-image-versions` corpus
reported KILLED on a macOS host, and replaying them with a `timeout` shim on
`PATH` turned one back into SURVIVED.

The fallback is not a one-line `alarm` + `exec`. It forks, puts the child in its
own process group, and kills the group. The second load-bearing detail above
applies to it exactly as it applies to GNU `timeout`, and dropping it was worth
30 seconds of wall clock against a 1-second budget in the replay that found it
(`tests/mutation/corpus/oracle-bound.sh`). It exits 124 on timeout so the
scoring branch needs no translation.

## Adding a mutation

A corpus file is an ordinary shell script calling `mutation`. There is no
bespoke format to parse and get subtly wrong.

```sh
mutation some-stable-id \
  --file scripts/thing.sh \
  --bats tests/thing.bats \
  --test "the test name, as a bats -f regex" \
  --why "what breaks in production if this survives" \
  --apply 'sed -i "s@^guard@# guard@" "$F"'
```

`$F` is the absolute path to the target; `--apply` runs from the repo root.
Keep `--apply` **single-quoted** — corpus files are sourced, so a double-quoted
value would expand `$F` to nothing at load time.

**GNU sed is a requirement of the corpus as it stands.** The example above uses
`sed -i`, and most entries do: GNU sed treats `-i` as an in-place flag, BSD sed
reads the next argument as a backup suffix, so on macOS those entries change
nothing and the runner reports `the mutation changed NOTHING` for each of them.
That is why `tests/mutation-corpus.bats` skips on BSD sed rather than reporting
hundreds of inert entries, and why a corpus can only be trusted where it ran:
Linux, which is where CI and pi1 run it. Write new entries with `perl -pi -e` or
`python3 -c` when they should replay on either host; the older `sed -i` ones stay
as they are, since rewriting them buys portability the corpus does not need and
costs a re-verification of every one.

`--apply` is a shell command in its own right, and two shells parse it before
perl or sed ever sees it: the value is single-quoted for the shell that sources
the corpus, and `run-mutations.sh` then hands the string to `bash -c`. So a `$`
has to survive both, and `\$` only survives one. Measured: an entry written
`--apply 'perl -pi -e "s@\"\$repo_root\"@\".\"@" "$F"'`, meant to rewrite
`target="$repo_root"`, left the file byte-identical. perl received
`s@"$repo_root"@"."@`, read `$repo_root` as one of its own variables, expanded
it to nothing, and matched nothing. The runner's only report is `the mutation
changed NOTHING`, which points at the pattern rather than at the quoting, so the
search starts in the wrong file. A literal `$` in the program needs `\\\$`; a
`$` perl is meant to read, a variable or the end anchor in `s@\s+$@@`, is
written `\$` and arrives as `$`.

An entry is a literal edit of a source line, so the line and the entry that
mutates it move together: when a source edit touches a line an entry applies to,
update that entry in the same commit. The failure is not a red test. The pattern
stops matching, the file comes back byte-identical, and the runner reports the
same `changed NOTHING` ERROR, failing the blocking corpus step while every test
in the suite is green. The same holds for `--test`: rename a test and every
entry naming it matches nothing, and `bats -f` exits 0 having run nothing.

Write `--why` as the consequence, not the edit. It is what gets printed when
the mutation survives, and by then the useful sentence is the one explaining
what is now unguarded.

### An assertion can be satisfied by its own fixture

The test for the vanished-backup guard asserted the output contained
`"vanished"`. It passed with the guard fully disabled — because the backup file
is named after the mutation id, and the id was `demo-vanishedbackup`, so the
word appeared in a path the runner prints either way. The assertion was matching
its own test data.

Reading it caught nothing; it looks completely reasonable. The corpus entry
caught it on the first run. When asserting on output, pick a phrase that exists
**only** on the path being proved — not a word that also appears in an id, a
filename, or an echoed argument.

### A survivor is not always a missing test

Sometimes it means the guard itself is redundant. Adding a `cp` exit-status
check alongside the existing `cmp` produced a mutation that could not be killed:
every case where a failed `cp` matters is a case where the bytes differ, so
`cmp` fires first and the `cp` branch can never be the thing that catches
anything. The right response was to delete the guard, not to write a test for
it. **Verify the outcome, not the exit status of the command that was supposed
to produce it** — when two guards overlap, keep the one that inspects reality.
