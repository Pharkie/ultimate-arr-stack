# Threat model: NAS Auto-Deploy

Audited 2026-09-11, against `.github/workflows/nas-auto-deploy.yml` at `9b55ac9`
(branch `chore/quality-plan`). Phase 4 of `ARR-STACK-QUALITY-PLAN.md`.

`nas-auto-deploy.yml` is the most powerful thing in this repository. It holds
`contents: write` and `pull-requests: write` (lines 35-37), joins the tailnet,
SSHs to the NAS as `leoleg`, recreates services, runs a Playwright suite on the
host, squash-merges the branch to `main`, and syncs `main` back. Nothing else
here can do any of that, so it gets a written model rather than a comment.

Each of the seven audit items below ends with **verified** or **accepted risk**,
and every claim carries a command to re-check it. Where a value would go stale,
the command is there instead of the value: `docs/EXIT-NODE-PROJECT-LOG.md`
embedded a commit SHA that its own commit invalidated, and
`docs/TEST-HARDENING-LOG.md` §1 exists to keep that from happening twice.

## 1. What this workflow is actually exposed to

The threat boundary is the dispatch permission, and that is the whole story.

| question | answer | re-check |
| --- | --- | --- |
| Who can dispatch it? | The only account with any access to this repository | `gh api repos/leonardoazeredo/ultimate-arr-stack/collaborators -q '.[] \| .login + " " + .role_name'` |
| Can a fork or a PR trigger it? | No. The sole trigger is `workflow_dispatch` | `grep -A2 '^on:' .github/workflows/nas-auto-deploy.yml` |
| What code does it run? | The branch the dispatcher selects, and nothing from a pull request | same |
| Runner | `ubuntu-latest`, GitHub-hosted, no self-hosted runner and no persistent state | `gh api repos/leonardoazeredo/ultimate-arr-stack/actions/runners` |

`gh api .../collaborators` returns exactly one row, `leonardoazeredo admin`.
The fork is public, so anyone can *read* it and open a pull request against it.
**Nobody else can write a branch, and nobody else can run this workflow.**
There is no path here from an outside contributor to a dispatch.

That matters for every item below, because most of what follows is reachable
only by someone who already has admin on the repository, and an admin is not
escalated by anything this workflow does. The items marked *accepted risk* are
accepted on that basis, and each one says what would have to change for it to
stop being acceptable: a second collaborator, a fork PR that the workflow
dispatches against, or a self-hosted runner.

## 2. Item 1: ref validation before any NAS action

**Verified for what matters, with one nuisance.** Every use of the dispatched
branch name is inside single quotes: `'${BRANCH}'` in the git fetch, checkout
and pull (lines 194-198), and again in the `main` sync (lines 358-362), with
`BRANCH: ${{ github.ref_name }}` passed through `env:` rather than interpolated
into the script text, which is GitHub's own recommended mitigation.

I measured rather than reasoned about the quoting, because the assumption worth
testing is that a ref name cannot carry shell syntax. It can. GitHub accepted a
branch literally named `diag/delete-me;echo-x`, and another named
`diag/delete-me3-$(touch-pwn)`, both pushed from this working copy and deleted
again immediately. Re-run the measurement with:

```bash
git push origin 'HEAD:refs/heads/diag/delete-me;echo-x'
git ls-remote origin 'refs/heads/diag/*'
git push origin --delete 'diag/delete-me;echo-x'
```

The `;` and the `$( )` survived the push, and both came back inert out of the
step's quoting: the payload printed as a literal argument and no sub-shell ran.
So a ref name cannot inject a command through this workflow. It can do one
unpleasant thing, though: a branch name containing a single quote, such as
`fix/o'brien`, terminates the quoting early and garbles the remote command.
GitHub accepts `'` in a ref name. That is a confusing failure on a real branch,
not a way in.

**Verdict: verified.** No ref validation exists and none is needed for the
injection case. A `case "$BRANCH" in *"'"*) refuse ;; esac` guard would turn the
single-quote nuisance into a clear error, and is not worth a change on its own.

## 3. Item 2: injection through GitHub context variables

**Verified, and stronger than the item assumes.** Every `${{ }}` in the file
passes through `env:` or an action input; none is interpolated into script text.
The full list is 22 lines and each one is checkable with:

```bash
grep -nE '\$\{\{' .github/workflows/nas-auto-deploy.yml
```

Two of them are attacker-shaped data rather than secrets, and both are handled:

`github.ref_name` reaches only single-quoted uses (item 1).

`steps.changes.outputs.files` is a list of compose filenames from the diff, and
it is the one value that is split on whitespace on purpose, because the recreate
step loops over it (line 245). Each filename is then wrapped in single quotes
before it goes over SSH (line 250). I checked that wrapping holds: with a
filename of `docker-compose.x.yml; echo escaped;`, the whole string arrives as
one argument and nothing executes a second time.

The file *can* contain shell syntax, since a git path has no ref-name rules, and
the quoting is what stops it. Worth knowing when reading the step: the guard is
the quotes, not the filename's shape.

The same step runs `docker compose -f "$f" up -d --build` on the NAS, so a
branched Dockerfile does run as a `docker`-group user. This workflow's purpose
is to deploy the branch it was pointed at, so a dispatcher running their own
branch's build is the point. It is a hazard only if the set of dispatchers ever
grows past the repository's owner, which is item 5.

**Verdict: verified.**

## 4. Item 3: who can dispatch, and whether that set is intended

**Verified.** One account, admin, and therefore the intended set. The dispatch
route is the Actions tab or `gh workflow run nas-auto-deploy.yml --ref <branch>`,
and both require write access to the repository. See §1 for the command.

The question is worth asking because the workflow's design assumes a trusted
dispatcher in a specific way: it deploys first and merges afterwards, so the
branch is live on the NAS before any review of the merge happens, and the
preflight (lines 56-77) only checks that *a* PR exists, not that anyone has read
it. `required_approving_review_count` is 0, so nothing else supplies that check.

**Verdict: verified.** If a second collaborator is ever added, this becomes the
first thing to revisit: either the workflow gains an approval requirement, or
the collaborator gets read access only.

## 5. Item 4: SSH host verification, and the deploy key's real scope

**Accepted risk, and larger than the header comment claims.**

Host verification is trust-on-first-use. `ssh-keyscan -H "$NAS_SSH_HOST" >>
~/.ssh/known_hosts` (line 142) records the first key that answers on a fresh
runner, and nothing after that checks a fingerprint. The first connection of
every run is therefore unverified. On a tailnet the window is narrow, and the
alternative is worse to maintain: putting the host key in a repository secret
pins it, and pins that rotate badly fail at 3am. Publishing `ssh-ed25519` as
the host key in the tailnet's DNS would be better, and is not worth the setup
here.

The key's scope is the part the comment understates. Lines 24-26 say
`NAS_SSH_KEY` is "private key for a dedicated CI deploy keypair (not the
operator's personal key)". That is true, and it is the *only* limit on it. The
NAS has four keys in `leoleg`'s `authorized_keys` and not one of them carries a
restriction option: no `command=`, no `restrict`, no `from=`, no
`no-port-forwarding`:

```bash
ssh arr-stack-nas 'cut -c1-60 ~/.ssh/authorized_keys; wc -l < ~/.ssh/authorized_keys'
```

The account itself is group `docker` (`groups=10(admin),100(users),121(docker)`)
and can drive `/var/run/docker.sock`, which is the ownership of the host: a
`docker run -v /:/host` is root. `leoleg` has no passwordless `sudo`, and that
is the only privilege it lacks.

So the deploy key is best described as **a dedicated keypair, separate from the
operator's, that grants full shell as a host-root-equivalent account.** It is
not narrowly scoped, and any process that holds it can do anything this stack
can do, including reading every `.env`, every config volume, and the VPN
credentials.

That is not a defect for a one-admin repository whose owner already has that
access. It becomes one the moment the secret is copied anywhere else, which is
the reason it should not be treated as a low-value credential.

The narrow fix, if it is ever wanted, is a forced command on the NAS side that
allows only the two git invocations the workflow needs:

```
command="docker run --rm -v /volume1/docker/arr-stack:/repo -w /repo alpine/git -c safe.directory=/repo $SSH_ORIGINAL_COMMAND",restrict ssh-ed25519 AAAA... ci-deploy
```

That is a NAS-side change, outside this repository, and it constrains the two
sync steps while the recreate, health and e2e steps need a general session
anyway. Recorded as available, not recommended: forcing the command changes what
the credential allows, not what a dispatcher can do, and the dispatcher already
has that access by other means.

**Verdict: accepted risk**, on the single-admin basis in §1, for how widely the
credential reaches.

## 6. Item 5: Tailscale auth-key lifetime and tag scope

**Accepted risk, unverifiable from this repository.** The key is passed as
`secrets.TS_AUTHKEY_CI` (line 105) and the workflow comment says it is "tagged
e.g. tag:ci". Nothing in the tree records whether it is reusable, how long it
lives, or what `tag:ci` is allowed to reach, and the tailnet's ACL is not in
this repository: the Tailscale admin console is the only place those answers
exist. The workflow also gives each run a unique hostname
(`gh-actions-arr-stack-${{ github.run_id }}`, line 111) because a fixed one
collided with a previous run's still-registered device, which is evidence that
these nodes persist past the run that created them rather than being ephemeral.

Two things follow. First, this item cannot be closed by reading code, and
pretending otherwise would be the failure mode this document exists to avoid.
Second, how far this credential reaches is bounded by the tailnet ACL and by
nothing in this repository: the auth key that admits `tag:ci` to the NAS's SSH
port is the whole of what the deploy needs, and a credential with broader reach
hands that reach to whatever holds it.

Re-check before relying on it, in the Tailscale admin console: when this
credential expires, whether it is reusable, and which ACL rules mention
`tag:ci`. Two settings would make this a verified item: an ACL that admits
`tag:ci` to the NAS SSH port and nothing else, and an expiry short enough that a
leaked secret stops working without anyone noticing it was leaked.

**Verdict: accepted risk**, unverifiable from the repository, with the
re-check steps above.

## 7. Item 6: whether a compromised dependency reaches the NAS

**Accepted risk, yes it can, and by design.** The e2e step (lines 277-331)
builds `tests/e2e/Dockerfile` on the NAS and runs Playwright there, so that
`docker exec`-gated tests (VPN egress, leak, killswitch) actually run instead of
skipping. That container gets:

| given | consequence |
| --- | --- |
| `-v /var/run/docker.sock:/var/run/docker.sock` | the NAS's Docker daemon, which is host root |
| `--network host` | the NAS's own network position, so the LAN and the `.lan` DNS reach it |
| `npm install` at container startup | whatever npm resolves today for `@playwright/test` and its transitive tree |
| `npx playwright install chromium` at startup | a browser downloaded at run time |
| `FROM mcr.microsoft.com/playwright:v1.50.0-noble` | base pinned by tag, not by digest |

The socket mount is not a new privilege: the SSH user is already in the `docker`
group, and the step runs as that user, so anything the container can do through
the socket the session could do without it. What the container adds is code from
the network, run once per deploy, with those privileges already attached.

`package-lock.json` is gitignored for the Node subprojects, so the exact
dependency set is not in the tree and `npm install` resolves fresh every run.
That is the same float that broke run 31959525960 (npm resolved `@playwright/test`
1.62.1 while the image had 1.50.0's browser build) and the reason the browser
install moved to run time. A version float is a supply-chain risk in general and
a reproducibility problem in particular; the reproducibility half is item 5 of
the quality plan, and the Node lockfiles are a separate axis this document does
not settle.

What would narrow it, in rough order of value: commit a lockfile for
`tests/e2e/` and switch to `npm ci`; pin the e2e base image by digest, matching
`ci.yml`'s supply-chain job; drop `--network host` if the tests can reach
published ports by NAS IP instead of `localhost`. None of these is required on
the single-admin basis, and the lockfile is the one with a reason to happen
regardless: `magnetio/scraper/Dockerfile` runs `npm ci --omit=dev` today against
a lockfile that is not in the tree, so a fresh clone cannot build it.

**Verdict: accepted risk**, with the three narrowing steps named above.

## 8. Item 7: the required-checks interaction

**Verified.** The merge at the end of the job runs `gh pr merge`, which asks
GitHub to merge server-side, so branch protection applies to it exactly as it
does to a merge request from the UI. The three required contexts are present and
name-for-name identical to the job names in `ci.yml`:

```bash
gh api repos/leonardoazeredo/ultimate-arr-stack/branches/main/protection \
  -q '.required_status_checks.contexts[], .enforce_admins.enabled, .required_conversation_resolution.enabled'
```

That returns `bats suite`, `mutation guards for this change`,
`workflow and terraform lint`, `true`, `true`. The contexts match
`name:` on the `bats`, `mutation-guards` and `lint` jobs. `enforce_admins` is
on, so the owner is not exempt, and `required_conversation_resolution` is on as
well, so an unresolved review thread blocks the merge too.

The consequence is worth stating plainly, because it is the one place this
workflow can strand the host: if the PR's checks are red, the merge fails, and
the NAS is left running the branch. The preflight (lines 56-77) narrows this to
the case where the PR existed when the run started and went red during it, and
lines 59-62 say so. The `main` sync step then never runs, so the host stays on
the branch until someone re-dispatches on `main`. That is the documented
recovery path rather than a new risk, and `scripts/sync-nas.sh` is the manual
equivalent.

One more consequence, found by watching this workflow merge its own branch on
2026-09-11: **the commit it creates on `main` runs no CI at all.** GitHub does
not start workflow runs for pushes made with the default `GITHUB_TOKEN`, so that
guard against recursion means a merge performed by this job is the one push to
`main` that no workflow observes. Every other merge in this repository's history
has a run on `main` attached to it; `17f6859` does not, and `gh api
repos/<owner>/<repo>/actions/runs?head_sha=<sha>` returning zero is how to
confirm it. The evidence is not missing, just differently shaped: the PR's own
head was checked by all three required contexts before the merge, and the deploy
job itself runs the suite and the changed-guard mutations on the same tree. What
is absent is an independent verdict on the commit `main` ends up holding.

The gap is easy to close by hand and worth automating if it recurs: `gh workflow
run ci.yml --ref main` starts the same four jobs on `main` after the fact. That
is what was done for `17f6859`.

## 9. Accepted risks, in one list

| # | risk | accepted because | would stop being acceptable if |
| --- | --- | --- | --- |
| 1 | TOFU host key, first connection of each run unverified | narrow window on a tailnet; a pinned key in a secret rotates badly | the runner stops being GitHub-hosted |
| 2 | The deploy credential grants full shell as a host-root-equivalent account | dedicated keypair, one admin, who already has that access | the secret is copied anywhere else |
| 3 | Tailscale credential lifetime and `tag:ci` ACL unverifiable here | the console is the only source, and the tailnet is one admin's | a second device or user joins `tag:ci` |
| 4 | e2e container holds the Docker socket and host networking, running freshly resolved npm code | same privileges the session already has; one admin | a lockfile is wanted for reproducibility anyway, or the socket mount is no longer needed |
| 5 | A dispatcher can run a branch's Dockerfile as a `docker`-group user | that is what deploying a branch means | a second collaborator gets write access |

All five shrink to one: **the workflow trusts whoever can dispatch it, and today
that is exactly one person.** Nothing in this document is a finding against the
current setup. It is the list of assumptions that setup rests on, so that adding
a collaborator or a runner is a deliberate change rather than a discovery.
