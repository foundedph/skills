---
name: repo-drain
description: Drain the ENTIRE repo, every open issue and PR, to merged until nothing eligible is left. Use when the user says "drain the whole repo / all issues and PRs".
---

# Repo Drain

Autonomous once started: no questions between items or passes. `drain.sh` is `~/.claude/skills/loop-drain/scripts/drain.sh`.

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

## Loop

```
loop:
  drain.sh inventory
  no open PRs into dev AND no eligible issues → report, stop
  each open PR into dev → PRs
  each eligible issue, oldest first, priority labels first → Issues
```

Rebuild inventory after every merge. One PR in flight at a time. Three retries per item, then park it with a blocker note and continue.

**Skip when any holds:**

- `no-agent` not set by this run, or `needs-human`, `human-in-the-loop`, `needs-human-review`
- body's `## Blocked by` names an open issue (strip the section once deps close; stale refs park the chain)
- `do-not-merge`, `wontfix`, `duplicate`, `needs-design`, `needs-triage`
- `sandcastle:running:*`
- draft PR, or the `dev → main` promotion PR

**Stop:** missing creds, destructive ambiguity, or a hard blocker no stall trigger covers. Unclear product intent parks only that issue.

**Report:** merged count, parked items with reasons, hard blockers, built from `~/.claude/scripts/work-log.sh --summary loop-drain`. Beyond a handful of items, run under `/loop /repo-drain`; each wake-up resumes from inventory, and the loop ends at the stop above.

## PRs

The control plane (CP) merges. Merge by hand only through `cp-drive`, on a stall trigger. `dev → main` is human-only.

`drain.sh pr-status <PR>`, then:

- **Conflicts, red checks, or behind `dev`:** repair per Routing, push. Stale bases clobber newer files on squash.
- **Green:** `drain.sh cp-supervise <PR>`.
- **Stall trigger:** follow `~/.claude/skills/cp-drive/SKILL.md` for this PR, using *the review* for any second pass on a risky diff:
  - `cp-supervise` timed out and the pinned status comment has not moved
  - status comment shows `406 ... too_large`
  - `needs-human-review` with "Agent did not return a machine-readable control-plane result block" (a fresh `cp-drive` `approve` clears it; a real design or product escalation stays parked)
- **CP health not 200:** follow `~/.claude/skills/cp-drain/SKILL.md` for the whole PR phase.
- **CP re-reviewing every push:** draft the PR, fix, un-draft.

## Issues

`no-agent` comes first: `drain.sh claim <N>`, for a spec the parent and every child. Set later, it won't stop a running Sandcastle job. Ambiguous acceptance criteria: park and continue.

Both builders are user-invoked, so read their `SKILL.md` and follow it; the Skill tool refuses them.

**Issue with child tickets → `~/.claude/skills/implement-spec/SKILL.md`**, once on the parent, from this session. Confirm children by reading them: `drain.sh children <N>` falls back to any `#N` in the body. Overrides:

- Integration branch from fresh `origin/dev`; every "main" in the skill means `dev`.
- No draft PR at step 3.
- Step 7.1: run *the review* yourself.
- Final Command Code seam for `docs/wiki/`.

**Any other issue → `~/.claude/skills/implement/SKILL.md`:**

1. Worktree on a new branch from fresh `origin/dev`; run `bash scripts/hooks/worktree-link-node-modules.sh` in it.
2. Spawn one fresh `general-purpose` subagent per issue, pointed at the issue number, worktree and skill. Seams run serially, the last hands `docs/wiki/` to Command Code. It reports in at most five lines: branch, rounds, test and tsc status.

**Close out, either builder:**

1. `npm run check`. Failures from this diff go back as a Command Code round.
2. PR into `dev`: `drain.sh pr-create <N>`, or for a spec `gh pr create --base dev` with one `Closes #N` per ticket.
3. PRs above.
4. `loop-drain` Phase 8: work-log row with checkable evidence, refresh `origin/dev`, remove the worktree.

## Invocation

`/repo-drain [--label <l>] [--prs-only | --issues-only] [--max <merges>]`, or `/repo-drain status` for an inventory snapshot.
