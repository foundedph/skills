---
name: repo-drain
description: Drain the ENTIRE repo — every open issue and every open PR — to merged, until nothing is left open. I (Claude Code) orchestrate and write RED tests; Command Code (DeepSeek) writes GREEN via /cmd-handoff at every tier, Pi only as fallback when CC is down; the control plane (CP) reviews and AUTO-MERGES. Every worked issue is labeled `no-agent` so the Sandcastle daemon never double-picks it. Loops PRs-first, then issues, rebuilding inventory after each merge, until all PRs into dev are merged and no eligible issues remain. Use when the user says "drain the whole repo / all issues and PRs".
---

# Repo Drain

The whole-repo sweep. Same per-item pipeline as `/loop-drain`, but the *scope is everything open* and the loop runs until the repo is empty: **all PRs into `dev` merged, no eligible issues remaining.**

This skill is the orchestration shell; the per-item mechanics (claim → RED test + spec → Command Code → verify → wiki → PR → CP-merge) are defined in `~/.claude/skills/loop-drain/SKILL.md`. Read that for the per-item detail. Both share `loop-drain/scripts/drain.sh`.

## The four invariants (inherited from loop-drain)

1. **Command Code writes the code at every tier** (`drain.sh exec <slug>` → `/cmd-handoff`; Pi fallback when `commandcode status` fails). The budget tier only picks the Claude orchestration model; a whole-repo sweep is long, so re-read `~/.local/bin/budget-tier-read` every ~10 merges and drop to Haiku orchestration at red.
   <!-- LOCAL DELTA 2026-10-19: CC-first (docs/context/ai-workflow.md). Was: Claude inline at green/yellow, Pi at red. Preserve across upstream re-syncs. -->
2. **`no-agent` before touching an issue** — set FIRST (after-the-fact doesn't stop a running Sandcastle job → duplicate PRs). Abort an item if `sandcastle:running:*` is already on it.
3. **CP auto-merges — I do not.** Open PRs into `dev`; supervise the pinned `<!-- control-plane:status -->` comment and labels. Manual `gh pr merge` only on the confirmed CP "no result block" glitch.
4. **Wiki + `npm run check` before every PR.**

## Sweep order (PRs first, then issues)

```
loop:
  inventory = drain.sh inventory
  if no open PRs into dev AND no eligible issues → DONE (report, stop)

  # Phase A — clear the PR backlog first (closest to merged)
  for each open PR into dev (skip drafts, do-not-merge):
    pr-status → if conflicts/red checks: CC round against branch (or /safe-pull), push
              → if green: cp-supervise (let CP merge)
    rebuild inventory after each merge

  # Phase B — drain eligible issues one at a time
  for each eligible issue (oldest-first, respect priority labels):
    run the loop-drain per-item pipeline (claim → RED + spec → CC → verify → wiki → PR → cp-supervise)
    rebuild inventory after each merge

  repeat loop  # new PRs/issues may have appeared (CP, dependencies unblocking)
```

## Eligibility filter (what to skip)

Skip an issue/PR when ANY is true:
- **`no-agent`** already present AND I didn't set it this run (someone parked it on purpose), or any legacy alias: `needs-human`, `human-in-the-loop`, `needs-human-review`.
- **Body has an open `## Blocked by: #N`** whose dependency is still open → park it; revisit after that dep merges. (Strip the Blocked-by section once deps close — stale closed refs silently park the chain.)
- Labels: `do-not-merge`, `wontfix`, `duplicate`, `blocked`-by-body, `needs-design`, `needs-triage`.
- `sandcastle:running:*` is live on it → a daemon job is in flight; skip to avoid duplicate PRs.
- PR is a **draft** or the `dev → main` promotion PR (human-merged, out of scope here).

If the only remaining items are all skipped, the repo is "drained as far as agents can take it" — report the parked list and stop.

## Invocation

| Command | Effect |
|---------|--------|
| `/repo-drain` | Drain everything open in the current repo until empty |
| `/repo-drain --label bug` | Restrict the issue phase to one label |
| `/repo-drain --prs-only` | Only clear the open-PR backlog, skip issues |
| `/repo-drain --issues-only` | Skip PR phase, drain issues |
| `/repo-drain --max 10` | Stop after 10 merges |
| `/repo-drain --tier heavy` | Heavy tier for all items — CC on `deepseek/deepseek-v4.1-flash` (Pi fallback: DeepSeek-V4-Pro) |
| `/repo-drain status` | Inventory + ledger snapshot |

## Done condition

The sweep is **done** when a fresh `drain.sh inventory` shows:
- **zero open PRs into `dev`** (all merged by CP), AND
- **zero eligible open issues** (everything left is in the skip set above).

Report: merged count, parked items with reasons, anything that hit a hard blocker.

## Autonomy & looping until done

**Primary — in-session loop.** Fully autonomous once started. Do NOT ask between items or between loop passes. Push through test/CI/review/conflict/deploy failures with another CC round (3 max, then inline). Re-inventory after every merge and start another pass. Stop only for: missing creds, destructive ambiguity, unclear product intent on a specific issue (park it, continue others), or CP confirmed dead. Keep looping passes until the **Done condition** is met.

**Fallback — `/loop` to survive context limits.** There is no `/goal` mechanism; the loop lives in the session's context. A whole-repo drain can outrun one window — so for anything beyond a handful of items, run this skill under the self-pacing `/loop` skill so it re-invokes and resumes after each context reset:

```
/loop /repo-drain
```

On each wake-up: rebuild inventory, skip merged/parked items, run the next pass. End the `/loop` (omit the next ScheduleWakeup) the moment a fresh inventory hits the Done condition — zero open PRs into `dev`, zero eligible issues — then report and stop.

## Anti-thrash guards (from drain memory)

- **Rebuild inventory after every merge** — don't operate on a stale list.
- **Confirm branch is fresh vs `dev` before letting a PR merge** — a behind-base squash can clobber newer files (stale-base clobber).
- **One item at a time.** Don't fan out parallel CC/Pi jobs on the same repo — concurrent merges + the CP create conflict churn.
- **Cap retries** (3 per item). If an item exhausts retries, park it with a blocker note and move on; never loop forever on one issue.
- **Watch CP token burn** — if the CP starts re-reviewing on every push (synchronize churn), draft the PR to pause CP, fix, then un-draft.

## Per-pass ledger

```
PASS 1
| Item  | Kind  | Action            | PR   | Result          |
|-------|-------|-------------------|------|-----------------|
| #775  | PR    | green → cp-merge  | #775 | merged(abc123)  |
| #142  | issue | claim→pi→pr       | #780 | merged(def456)  |
| #143  | issue | blocked-by #142   | —    | parked          |
```
Closeout per pass: `PASS 1 — merged 4, parked 2, blockers 0`. Then re-inventory and start PASS 2.

## References
- `~/.claude/skills/loop-drain/SKILL.md` — the per-item pipeline this wraps
- `~/.claude/skills/loop-drain/scripts/drain.sh` — shared orchestrator (claim, exec, pr-create, cp-supervise, inventory)
- `docs/context/ai-workflow.md`, CLAUDE.md → "Knowledge Wiki" governance, "Labels & Sandcastle pickup"
