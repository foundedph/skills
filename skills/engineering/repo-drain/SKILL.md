---
name: repo-drain
description: Drain the ENTIRE repo, every open issue and every open PR, to merged until nothing eligible is left open. Claude orchestrates and writes RED tests; each issue is built with /implement or /implement-spec, GREEN on Command Code (DeepSeek v4), /code-review on v4.1, cp-drive on v4 when the control plane stalls. Every worked issue is labeled `no-agent`. Use when the user says "drain the whole repo / all issues and PRs".
---

# Repo Drain

The whole-repo sweep: the loop runs until **all PRs into `dev` are merged and no eligible issues remain.** This skill owns scope, routing and the loop. `/implement` and `/implement-spec` own how an issue gets built, `cp-drive` owns the hand path to merge, and `loop-drain/scripts/drain.sh` holds the shared commands.

## Routing

<!-- LOCAL DELTA 2026-10-31: per-item build goes through /implement and /implement-spec, model per role fixed below. Was: loop-drain per-item pipeline. Preserve across upstream re-syncs. -->

| Work | Runs on | How |
|---|---|---|
| GREEN, review fixes, PR repairs, wiki/docs | Command Code `deepseek/deepseek-v4-flash` | `/cmd-handoff`, `cmd-execute.sh` |
| `/code-review` | Command Code `deepseek/deepseek-v4.1-flash` | `cmd-execute.sh --review --base <merge-base with origin/dev> <slug>`, read-only |
| `cp-drive` step 2 (review + `fixed` edits) | Command Code `deepseek/deepseek-v4-flash` | what `cp-drive` already runs |
| RED tests, per-issue driver | Sonnet subagent | see Issues |
| Inventory, labels, verdicts, parking, merge authority | This session | Sonnet; Haiku at the `red` tier |
| Unknown-cause debugging, security (auth, RLS, SQL, payroll, payments), design calls | Sonnet, inline | `reviewer-deep` too when `review-route.sh` flags risk |

**Sonnet or Command Code, for anything the table leaves open:** hand off when you can write acceptance criteria and a test command. Do it on Sonnet when you must first decide what the work is, or when the spec would be longer than the diff (roughly 10 lines in a file already in context: a trivial conflict, a one-line lint fix).

**A step on Command Code stays on DeepSeek.** Same model for every round, resuming the saved session. Three failed rounds on one seam: finish on Sonnet and say so in the PR. When this skill is itself running inside Command Code, every row runs on DeepSeek: no Sonnet subagents, items serial, v4.1 for review and v4 for everything else.

**Fallback:** `commandcode status` fails → `drain.sh exec-pi <slug>` for GREEN (DeepSeek on DeepInfra).

**Keep Claude tokens low:**

- Session on Opus: say so once and suggest `/model sonnet`. Pin `model` on every subagent.
- From an executor, read only `## Executor results` and `git diff --stat`. From `npm run check`, read the tail.
- Run every wait (`cp-supervise`, `npm run check`) in the background, so waiting costs no turns.
- Pass `--fresh` only where `cp-drive` asks for it; session resume is the Command Code saving.
- Re-read `~/.local/bin/budget-tier-read` every ~10 merges.

## Invariants

1. **`no-agent` before touching an issue.** Set it FIRST (`drain.sh claim <N>`, which aborts on `sandcastle:running:*`); set later, it won't stop a running Sandcastle job, and you get duplicate PRs.
2. **Control plane first.** Open PRs into `dev` and let the CP merge. Merge by hand only through `cp-drive`, under its gates, on a stall trigger (see PRs). `dev → main` stays human-only.
3. **Wiki + `npm run check` before every PR.**

## Sweep order: PRs first, then issues

```
loop:
  inventory = drain.sh inventory
  if no open PRs into dev AND no eligible issues → DONE (report, stop)
  for each open PR into dev: run PRs below; re-inventory after each merge
  for each eligible issue (oldest-first, respect priority labels): run Issues below; re-inventory after each merge
  repeat  # new PRs and issues appear as dependencies unblock
```

## PRs

`drain.sh pr-status <PR>`, then:

- **Conflicts or red checks:** repair per the Routing rule, push.
- **Green:** `drain.sh cp-supervise <PR>` in the background.
- **Stall trigger, take over with `cp-drive`** (read `~/.claude/skills/cp-drive/SKILL.md`, follow it for this PR):
  - `cp-supervise` times out and the pinned status comment has not moved
  - the status comment shows `406 ... too_large`
  - `needs-human-review` with "Agent did not return a machine-readable control-plane result block". A fresh `cp-drive` review that reaches `approve` clears it; a real design or product escalation stays parked.
- **CP health not 200** (`cp-drain` step 0): read `~/.claude/skills/cp-drain/SKILL.md` and run it for the whole PR phase.

When `cp-drive` calls for a second pass on a large or risky diff, use the v4.1 review from Routing in place of its Sonnet subagent.

## Issues

Choose the builder by shape:

- **Issue with child tickets** (a spec plus tickets from `/to-tickets`; confirm candidates from `drain.sh children <N>`, since its fallback matches any `#N` in the body): **`/implement-spec`**, once on the parent. Claim the parent and every child first; the children then leave the queue.
- **Any other issue:** **`/implement`**.

Both are user-invoked, so the Skill tool refuses them. Read `~/.claude/skills/implement/SKILL.md` or `~/.claude/skills/implement-spec/SKILL.md` and follow it. Ambiguous acceptance criteria: park the issue with a note and continue.

### `/implement`

1. `drain.sh claim <N>`.
2. Create a worktree on a new branch from fresh `origin/dev` and run `bash scripts/hooks/worktree-link-node-modules.sh` in it.
3. Spawn one `general-purpose` subagent (`model: "sonnet"`, `"haiku"` at `red`) pointed at the issue number, the worktree and the `implement` SKILL.md. Seams run one after another. It also hands the owning `docs/wiki/` updates to Command Code as a final seam, and reports in at most five lines: branch, rounds, test and tsc status. A fresh subagent per issue stops context bleed between items and keeps this session's context small.
4. Close out below.

### `/implement-spec`

Follow its steps from this session, with these overrides:

- The integration branch starts from fresh `origin/dev`, and every "main" in the skill means `dev`.
- Open no draft PR at step 3; the PR comes at close-out.
- Step 7.1: run the v4.1 review from Routing yourself, from the integration branch, in place of the review subagent.
- Add a final Command Code seam for the `docs/wiki/` updates.

### Close out

From the worktree or integration branch:

1. `npm run check` in the background. Failures from this diff go back as a Command Code round.
2. PR into `dev`: `drain.sh pr-create <N>` for one issue; for a spec, `gh pr create --base dev` with one `Closes #N` per ticket.
3. `drain.sh cp-supervise <PR>` in the background, then the PRs rules above.
4. Closeout per `loop-drain` Phase 8: work-log row with checkable evidence, refresh `origin/dev`, remove the worktree.

## Eligibility filter (what to skip)

Skip an issue/PR when ANY is true:
- **`no-agent`** already present AND I didn't set it this run (someone parked it on purpose), or any legacy alias: `needs-human`, `human-in-the-loop`, `needs-human-review`.
- **Body has an open `## Blocked by: #N`** whose dependency is still open: park it and revisit after that dep merges. (Strip the Blocked-by section once deps close; stale closed refs silently park the chain.)
- Labels: `do-not-merge`, `wontfix`, `duplicate`, `blocked`-by-body, `needs-design`, `needs-triage`.
- `sandcastle:running:*` is live on it: a daemon job is in flight.
- PR is a **draft** or the `dev → main` promotion PR (human-merged, out of scope here).

If the only remaining items are all skipped, the repo is "drained as far as agents can take it": report the parked list and stop.

## Invocation

| Command | Effect |
|---------|--------|
| `/repo-drain` | Drain everything open in the current repo until empty |
| `/repo-drain --label bug` | Restrict the issue phase to one label |
| `/repo-drain --prs-only` | Only clear the open-PR backlog, skip issues |
| `/repo-drain --issues-only` | Skip PR phase, drain issues |
| `/repo-drain --max 10` | Stop after 10 merges |
| `/repo-drain status` | Inventory + ledger snapshot |

## Done condition

The sweep is **done** when a fresh `drain.sh inventory` shows:
- **zero open PRs into `dev`**, AND
- **zero eligible open issues** (everything left is in the skip set above).

Report: merged count, parked items with reasons, anything that hit a hard blocker. Build it from `~/.claude/scripts/work-log.sh --summary loop-drain`.

## Autonomy & looping until done

**Primary: in-session loop.** Fully autonomous once started. Do NOT ask between items or between loop passes. Push through test/CI/review/conflict/deploy failures with another Command Code round (3 max, then Sonnet inline). Re-inventory after every merge and start another pass. Stop only for: missing creds, destructive ambiguity, or a hard blocker no stall trigger covers; unclear product intent parks that one issue and the others continue. Keep looping passes until the **Done condition** is met.

**Fallback: `/loop` to survive context limits.** There is no `/goal` mechanism; the loop lives in the session's context. A whole-repo drain can outrun one window, so for anything beyond a handful of items, run this skill under the self-pacing `/loop` skill so it re-invokes and resumes after each context reset:

```
/loop /repo-drain
```

On each wake-up: rebuild inventory, skip merged/parked items, run the next pass. End the `/loop` (omit the next ScheduleWakeup) the moment a fresh inventory hits the Done condition, then report and stop.

## Anti-thrash guards (from drain memory)

- **Rebuild inventory after every merge.** Don't operate on a stale list.
- **Confirm branch is fresh vs `dev` before letting a PR merge.** A behind-base squash can clobber newer files (stale-base clobber).
- **One PR in flight at a time.** Concurrent merges + the CP create conflict churn. Parallel implementers inside one `/implement-spec` are fine: they land on one integration branch and one PR.
- **Cap retries** (3 per item). If an item exhausts retries, park it with a blocker note and move on; never loop forever on one issue.
- **Watch CP token burn.** If the CP starts re-reviewing on every push (synchronize churn), draft the PR to pause CP, fix, then un-draft.

## Per-pass ledger

```
PASS 1
| Item  | Kind  | Action                 | PR   | Result          |
|-------|-------|------------------------|------|-----------------|
| #775  | PR    | green → cp-merge       | #775 | merged(abc123)  |
| #142  | issue | implement → pr         | #780 | merged(def456)  |
| #150  | spec  | implement-spec → pr    | #781 | merged(fed321)  |
| #143  | issue | blocked-by #142        | n/a  | parked          |
```
Closeout per pass: `PASS 1: merged 4, parked 2, blockers 0`. Then re-inventory and start PASS 2.

## References
- `~/.claude/skills/cmd-handoff/SKILL.md`: executor wrapper, exit codes, round rules
- `~/.claude/skills/loop-drain/scripts/drain.sh`: claim, inventory, children, pr-create, pr-status, cp-supervise, exec-pi
- `docs/context/ai-workflow.md`, CLAUDE.md → wiki governance, `docs/LABELS.md`
