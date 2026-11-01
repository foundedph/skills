---
name: repo-drain
description: Drain the ENTIRE repo, every open issue and PR, to merged until nothing eligible is left. Use when the user says "drain the whole repo / all issues and PRs".
---

# Repo Drain

Autonomous once started: no questions between items or passes, and blockers park one item while the rest continue. Beyond a handful of items, start under `/loop /repo-drain`. `drain.sh` is `~/.claude/skills/loop-drain/scripts/drain.sh`.

## Routing

<!-- LOCAL DELTA 2026-10-31: per-item build goes through /implement and /implement-spec, model per role fixed below. Was: loop-drain per-item pipeline. Preserve across upstream re-syncs. -->

| Work | Runs on |
|---|---|
| GREEN, review fixes, PR repairs, wiki | Command Code `deepseek/deepseek-v4-flash` (`/cmd-handoff`, `cmd-execute.sh`) |
| *the review*: `cmd-execute.sh --review --base <merge-base with origin/dev> <slug>` | Command Code `deepseek/deepseek-v4.1-flash` |
| `cp-drive` step 2 | Command Code `deepseek/deepseek-v4-flash` (its default) |
| RED tests, per-issue driver | Sonnet subagent (`haiku` at `red`) |
| Inventory, labels, verdicts, parking, merge authority | This session: Sonnet (Haiku at `red`) |
| Unknown-cause debugging, security, design calls | Sonnet inline, plus `reviewer-deep` when `review-route.sh` flags risk |

**Open cases:** hand off when you can write acceptance criteria and a test command. Stay on Sonnet when you must first decide what the work is, or when the spec would outgrow the diff (about 10 lines in a file already in context).

**Command Code stays on DeepSeek.** Every round resumes the saved session on the same model. Three failed rounds on a seam: finish on Sonnet and say so in the PR. If this skill itself runs inside Command Code, every row runs on DeepSeek, items serial, v4.1 for *the review*, v4 otherwise.

**`commandcode status` fails:** `drain.sh exec-pi <slug>` for GREEN.

**Token discipline:**

- On Opus, say so once and suggest `/model sonnet`. Pin `model` on every subagent.
- Read only `## Executor results` and `git diff --stat` from an executor, and the tail of `npm run check`.
- Background every wait (`cp-supervise`, `npm run check`).
- Re-read `~/.local/bin/budget-tier-read` every ~10 merges.

## Capacity

**Two workers at most**: a pane agent, a building subagent or this session's own build each count. A pane takes one spec or one small chain on files no other worker touches, and a brief file (this skill's Issues, Close out and Recorded E2E sections, plus its own scratch stack: `E2E_SCRATCH_DIR=$HOME/.cache/erp-e2e-scratch-<name>` and unique `SCRATCH_PG_PORT`, `STUB_PORT`, `APP_PORT`). Start it with `herdr agent start <name> --kind claude --pane <pane> -- --model sonnet --permission-mode auto`; close it (`herdr pane close`) once its work is merged or parked and its report is in, then prune its worktrees (below).

**Resource gate** before every new worker, full check and E2E run: read `uptime`, `memory_pressure` and `df -h /`, and hold while 5-minute load exceeds 30, free memory is under 15%, or free disk is under 5 GB. `npm run check` refuses below 3 GB free; that floor stays. Keep one background watcher (`until <disk under 4 GB or free memory under 12%>; do sleep 60; done`) and pause workers when it fires. Look at `ps -Ao pcpu,comm -r` before blaming the drain: macOS daemons (`mediaanalysisd`, Spotlight) can drive the load.

**One full check at a time.** Take `mkdir /tmp/repo-drain-check.lock`, or queue with `(until mkdir /tmp/repo-drain-check.lock 2>/dev/null; do sleep 20; done; npm run check > <log> 2>&1; echo "check-exit=$?" >> <log>; rmdir /tmp/repo-drain-check.lock) &`. A lock with no `run-check` process is stale: `rmdir` it. Rerun each failing file alone on a pristine `origin/dev` worktree: red there is baseline, green alone is a load flake, red only on the branch is yours.

**Prune as you go.** After every merge run `~/.claude/skills/repo-drain/scripts/prune-worktrees.sh --repo <repo> --apply` (without `--apply` for a dry run; `--keep <substr>` shields another session's worktrees; `--sweep` also removes the regenerable `node_modules` and `.check-logs` of idle worktrees that stay). It removes a worktree and its local branch only when the tree is clean, no live process works in it, and its work is provably merged: HEAD is on `origin/dev`, or a merged PR's head commit equals HEAD. It never forces, and lists every kept worktree with the reason. Other deletions (recordings, scratch caches, another session's files) need the user's word; when disk is short, list the biggest items and ask.

## Loop

```
loop:
  drain.sh inventory
  no open PRs into dev AND no eligible issues → report, stop
  each open PR into dev → Close sweep, then PRs
  each open spec, newest first → Close sweep, then Issues
  each remaining eligible issue, newest first, priority labels first → Issues
```

A *spec* is an open issue titled `PRD:` or labeled `parent`; its tickets are its GitHub sub-issues (`gh api repos/<repo>/issues/<N>/sub_issues`) plus issues naming it in `Part of`. Rebuild inventory after every merge. One PR in flight per spec. Three retries per item, then park it with a blocker note and continue.

**Skip when any holds:**

- `no-agent` not set by this run, or `needs-human`, `human-in-the-loop`, `needs-human-review`. Exception: on a spec, its tickets, or a `Part of #<map>` slice, `no-agent` is filing convention, so these stay eligible unless the body or a comment assigns them to a human or awaits an answer
- `wayfinder:*`: maps and their decision tickets are never built
- body's `## Blocked by` names an open issue (strip the section once deps close; stale refs park the chain)
- `do-not-merge`, `wontfix`, `duplicate`, `needs-design`, `needs-triage`
- `sandcastle:running:*`
- draft PR, unless it is the integration branch of an eligible spec (adopt it and continue there), or the `dev → main` promotion PR

**Park, never stop:** missing creds, destructive ambiguity, unclear product intent and exhausted retries each park that item with a one-line note. Stop only when nothing eligible can move.

**Report:** merged count, parked items with reasons, hard blockers, built from `~/.claude/scripts/work-log.sh --summary loop-drain`. Under `/loop`, each wake-up resumes from inventory, and the loop ends at the stop above.

## Close sweep

Before working a PR or spec, check whether it is already done or replaced. Read its issue, its linked PRs, its wayfinder map (the `Part of #<map>` header), the map's decisions doc in `docs/wayfinder/` and newer specs on the same map. Then close with a comment citing the evidence:

| Finding | Evidence required | Close |
|---|---|---|
| PR completed | its change is already on `origin/dev` (`git cherry`, or the file diff is empty) | `gh pr close` |
| PR superseded | a named merged PR or newer open PR covers it | `gh pr close`, naming the successor |
| Spec completed | every ticket closed, and each acceptance criterion traced to code on `origin/dev` | `gh issue close --reason completed` |
| Spec or ticket superseded | a named newer spec, or a decision of record, replaces it (for example "Replaces and absorbs #N") | `gh issue close --reason "not planned"`, naming the successor |

Evidence short of this leaves it open and goes on the report as "maybe closable". PRs labeled `do-not-merge` or `wip` stay untouched.

**Unlabelled issues** get a read-only triage before any build, one verdict each with evidence: FIXED (cite the commit or `file:line` on `origin/dev`; close it), SUPERSEDED (name the successor; close it), BUILD (still present, fixable in this repo by an agent; give the smallest fix and the test that proves it), HUMAN (production, credentials, FileMaker or a product call; park it with the reason). A merged PR whose `Closes #N` did not fire (base is `dev`) is a FIXED case: close the issue by hand with the PR number.

## PRs

The control plane (CP) merges. Merge by hand only through `cp-drive`, on a stall trigger. `dev → main` is human-only.

`drain.sh pr-status <PR>`, then:

- **Stale-base guard, before every push:** `git fetch origin`, merge `origin/dev` into the branch (no rebase, no force-push), then `git diff origin/dev...HEAD --stat` must show only this slice's files and no reverted newer `dev` lines; otherwise park the PR as `needs-human-review`. Union-merge `docs/wiki/*`, `scripts/check-groups.txt` and `scripts/e2e-scratch/fixtures.sql`.
- **Conflicts, red checks, or behind `dev`:** repair per Routing, push.
- **Green:** `drain.sh cp-supervise <PR>` in the background. A PR that changes the control plane's deploy path (`automation/`) gets `needs-human-review` instead, and a person merges it.
- **Stall trigger:** follow `~/.claude/skills/cp-drive/SKILL.md` for this PR, using *the review* for any second pass on a risky diff:
  - `cp-supervise` timed out and the pinned status comment has not moved
  - status comment shows `406 ... too_large`
  - `needs-human-review` with "Agent did not return a machine-readable control-plane result block" (a fresh `cp-drive` `approve` clears it; a real design or product escalation stays parked)
- **CP health not 200:** follow `~/.claude/skills/cp-drain/SKILL.md` for the whole PR phase.
- **CP re-reviewing every push:** draft the PR, fix, un-draft.

## Issues

`no-agent` comes first: `drain.sh claim <N>`, for a spec the parent and every child. Set later, it won't stop a running Sandcastle job. Ambiguous acceptance criteria: park and continue.

Builders and `to-tickets` are user-invoked, so read their `SKILL.md` and follow it; the Skill tool refuses them. A spec with no tickets: run `to-tickets` first, deciding its approval questions yourself and recording them on the spec. A wayfinder map with no spec has open decisions: skip it and list it in the report.

**Spec → `~/.claude/skills/implement-spec/SKILL.md`**, once on the spec, from this session. Overrides:

- Integration branch from fresh `origin/dev`; every "main" in the skill means `dev`.
- No draft PR at step 3.
- Step 7.1: run *the review* yourself.
- Final Command Code seam for `docs/wiki/`.

**Any other issue → `~/.claude/skills/implement/SKILL.md`:**

1. Worktree on a new branch from fresh `origin/dev`; run `bash scripts/hooks/worktree-link-node-modules.sh` in it.
2. Spawn one fresh `general-purpose` subagent per issue, pointed at the issue number, worktree and skill. Seams run serially, the last hands `docs/wiki/` to Command Code. It reports in at most five lines: branch, rounds, test and tsc status.

**Close out, either builder:**

1. `npm run check` under the lock (Capacity). Failures from this diff go back as a Command Code round. A change to security, auth, privileges, RLS, a migration or a deploy path also gets a `reviewer-deep` pass: apply every FIX-FIRST finding, then re-review the delta.
2. **Recorded E2E**, for any user-visible change. See below.
3. PR into `dev`: `drain.sh pr-create <N>`, or for a spec `gh pr create --base dev` with one `Closes #N` per ticket. Add `e2e-required` when step 2 applied, and list each test, its verdict and its recording path in the body.
4. PRs above.
5. After the merge: close each ticket by hand (`gh issue close --reason completed` with the PR number and the test evidence; `Closes` does not fire on a non-default base), `loop-drain` Phase 8 work-log row, refresh `origin/dev`. Then prune (Capacity).

### Recorded E2E

A PR leaves here only with its browser test passing. Rules live in `docs/TESTING.md` → Recorded e2e and `docs/context/testing-ops.md` → E2E without touching prod.

- Claude writes the test as part of RED: `tests/e2e/<feature>.test.sh`, sourcing `lib/record.sh`, one `record_start` after login. Cover each state change a reviewer would want to see.
- Run on the scratch stack (`scripts/e2e-scratch/up.sh`) with `E2E_REQUIRE_SCRATCH=1` and `AGENT_BROWSER_SESSION=scratch-<name>-$$`, in the background, and read back only `grep -E "OK|FAIL|recording:"`. Writes to the shared prod database are out of bounds.
- `up.sh` loads `scripts/e2e-scratch/fixtures.sql` only into a new database: after changing fixtures or applying a migration run `REBUILD=1 bash scripts/e2e-scratch/up.sh`. Run `agent-browser --session <name> close` after every run so sessions do not leak.
- Passing means exit 0 **and** a `recording:` line pointing at a non-empty `.webm`; `record.sh` only warns when recording fails, so a missing file is a failed run. Recordings are gitignored, so they stay on the machine that ran the test.
- `E2E-Not-Applicable: <reason>` is for changes with no observable behavior only.
- Failure: fetch a login token twice first; a 504, 500 or `fetch failed` means infra, so park as infra. Otherwise send it back as a Command Code round, two repairs at most, then park with `e2e-failed` and a comment.

## Invocation

`/repo-drain [--label <l>] [--prs-only | --issues-only] [--max <merges>]`, or `/repo-drain status` for an inventory snapshot.
