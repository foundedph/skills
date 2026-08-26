---
name: cp-drain
description: Drain the ENTIRE open-PR queue into dev, not just one PR — the whole-queue orchestration wrapper around cp-drive. Loops over every open PR targeting dev in merge-gate order, drives each one to merged via cp-drive, and self-repairs mechanical blockers (needs-rebase, e2e-failed, failing checks) inline rather than stopping at the first one. Keeps looping until a full sweep merges or repairs nothing more. Genuine human-judgment escalations (needs-human-review for a real design/product call) stay parked, never force-cleared. Use when the user says "drain the queue", "clear the backlog", "work through every open PR", or wants the control plane's whole job done by hand, not just one PR unblocked.
---

You are standing in for the control-plane daemon's *scheduler*, not just its reviewer. `cp-drive` drives one PR from review to merge; this skill is the loop around it that keeps calling `cp-drive` — plus a repair step for the blockers `cp-drive` deliberately leaves alone — until the queue is empty or everything left in it is parked for a reason only a human can resolve.

**Read the `cp-drive` skill's SKILL.md first** (global skill at `~/.claude/skills/cp-drive/SKILL.md`, or invoke it via the Skill tool). Every review, fix, label, and merge this skill performs is `cp-drive` Steps 0-5, verbatim, run once per PR. This file does not restate that contract — it only adds the queue loop and the mechanical-repair step `cp-drive` explicitly declines to do.

This is a bigger takeover than `cp-drive`: it will merge multiple PRs into `dev`, one after another, without checking in between. That is what "drain the queue" means, and it is exactly what the daemon itself does continuously — this skill exists because the user asked for that loop by hand. Say this once, up front, then run it; don't ask again per PR.

## 0. Preconditions — don't fight the daemon

```bash
ssh wlq@192.168.2.6 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8791/api/health'
# expect 200. Do NOT use `lsof -i :8791`: the daemon runs as user `it`, so an
# unprivileged probe as `wlq` sees nothing and falsely reports the daemon down.
```

If the daemon is up and has touched a PR recently (`pi-reviewing` labels that are actually moving, not stale), it already owns the queue — running this skill alongside it means two writers racing the same merge gate. Say so and stop, unless the user explicitly wants to take over anyway (e.g., the daemon is up but visibly stuck on one PR for a long time). If the daemon is down, slow, or genuinely backed up, proceed.

## 1. Build the queue

```bash
gh pr list --base dev --state open --json number,title,labels,mergeStateStatus,isDraft,headRefName,baseRefName,createdAt,files
```

Drop drafts. Drop any PR the daemon is actively working right now (per Step 0). Everything else is in scope.

Compute each PR's scheduling tier the same way the daemon does (`classifySchedulingTier` in `automation/daemon.ts`) so you don't review a day-old feature ahead of a same-day hotfix:

- **Priority tier**: title matches `[hotfix]`, OR base is the production branch (never true here since you filtered `--base dev`), OR the title is a fix-type commit (`fix|hotfix|chore|revert|perf|refactor|test|build|ci`) that touches `automation/**` or `server/**`.
- **Normal tier**: everything else.

Within a tier, oldest first (`createdAt` ascending, or PR number ascending — they agree in practice).

## 2. Pick the head, the same way the merge gate does

This mirrors `selectMergeGateHead` in `automation/merge-gate.ts` exactly — re-implement the same rule, don't approximate it:

> The head is the lowest-priority-key PR in the queue that carries none of the parked labels (`needs-human-review`, `do-not-merge`, `wip`, `e2e-failed`). If every PR is parked, there is no head.

- **No head, queue non-empty** → every remaining PR needs either a repair (Step 3) or is parked for a human (Step 5). Go there.
- **A head exists** → drive it (Step 4).

## 3. Repair mechanical blockers — the part `cp-drive` deliberately skips

`cp-drive` reports a `BEHIND`/`DIRTY` PR or an `e2e-failed` label and stops. That is correct for a single stand-in pass; it is not correct for a drain, where the whole point is to clear the backlog. Before re-running Step 2, attempt exactly one repair per still-broken PR per sweep — bounded, mirroring the daemon's own `conflictRepairMaxIterations` (2):

- **`mergeStateStatus: BEHIND` / `DIRTY`, or `needs-rebase` label** — `gh pr checkout <PR>`, `git fetch origin dev`, `git rebase origin/dev` (or merge, matching `conflictRepairStrategy: "merge"` if you want to stay behavior-identical to the daemon). Trivial conflicts you resolve yourself: generated/append-only files (`docs/wiki/log.md` is `merge=union` — keep both sides), lockfiles (regenerate, don't hand-edit), non-overlapping hunks. A conflict where both sides changed the *same logic* is not trivial — that's a judgment call about which change is intended to win, which is exactly the kind of thing `cp-drive`'s own criteria escalate. Push on success and clear `needs-rebase` (mirrors the daemon keeping that label in sync with reality, `automation/daemon.ts` ~L657-662). On a real conflict, or after 2 failed attempts, label `needs-human-review` with a comment naming the conflicting files and why it's not mechanical, and move on — do not retry it again this sweep.
- **`e2e-failed`** — re-run the relevant E2E coverage (`npm run test:e2e:file <path>` for the routes `classifyPaths`' `suggestedPaths` names, or the full suite if unclear), read the failure, fix the code if the fix is within the PR's own scope, retry. Cap at 2 repair attempts, same bound as conflict repair. Still failing after that → leave `e2e-failed`, comment what you tried, move on.
- **Failing required CI checks** (`gh pr checks <PR>`) — if the failure is `npm run check` / lint / a test broken by this PR's own diff, fix it in scope and push. If it's flaky or infra-side (not caused by this diff), say so in the status comment and move on rather than guessing at a fix.

**`needs-human-review` is not a mechanical blocker and is not repaired by removing the label.** Read the escalation comment. If — and only if — it turns out the thing named there was already resolved by something else (a dependency merged, the code changed under it, the concern was factually wrong), fix the actual thing and re-run `cp-drive`'s review fresh; a green re-review that independently reaches `approve` is what clears the label, never a direct removal. If the comment names a real design, product, or missing-context decision, leave it parked. This is the one boundary this skill will not cross even when told to "keep going until it's fixed" — see the boundary section below for why.

**`do-not-merge` / `wip`** are explicit human holds, not defects. Never touch these PRs at all — no review, no repair, no comment. They don't count against "done."

## 4. Drive the head

Run `cp-drive` Steps 0-5 against the selected PR, in full: preflight, review against `automation/prompts/review.md`, fix blockers inline, verdict, labels, merge-gate check, squash-merge into `dev` when every gate is green, retarget stacked children before deleting the head branch.

One difference from a standalone `cp-drive` run: **re-check the merge gate set right before merging**, because a previous PR in this same sweep may have just landed and moved `dev` — `mergeStateStatus` you read at the top of the loop may be stale.

## 5. Loop until dry

After the head PR either merges, gets parked (Step 4's escalate path), or gets a repair attempt (Step 3): go back to Step 1 and rebuild the queue. Labels, `mergeStateStatus`, and the PR list itself all change after every action, so re-read from GitHub rather than reusing anything cached.

Stop the loop when a full sweep — one pass over the entire current queue — merges zero PRs and repairs zero PRs. That's the fixed point: everything left is either empty, `do-not-merge`/`wip` by design, or `needs-human-review` for a real reason. Track sweep-over-sweep progress (PRs merged + repairs attempted) to detect this; don't just count remaining PRs, since a parked PR sits in the queue forever without being "stuck" in a bad way.

**Safety cap:** if you somehow exceed ~50 sweeps without hitting the fixed point (a bug, not a real backlog — a queue this deep would hit the fixed point in a handful of sweeps once parked PRs stop being retried), stop, say so, and report state as of the cap. Do not run unbounded.

## 6. Final report

One summary at the end, not a comment per PR beyond what `cp-drive` already posts on each one:

- **Merged**: PR numbers + titles, in the order they landed.
- **Repaired and merged**: same, but note what was fixed (rebased, E2E retried and passed, check fixed).
- **Escalated / parked on `needs-human-review`**: PR numbers + the concrete blocker in one line each — this is the list the user actually needs to look at.
- **Skipped by design** (`do-not-merge`, `wip`, or daemon-owned): PR numbers, so it's clear they weren't forgotten.
- **Repair attempts exhausted**: PRs where rebase/E2E/check repair hit the 2-attempt cap and got escalated — distinct from a first-pass design escalation, since these are worth a second look by a human specifically because automation already tried and failed.

## Boundaries — what this skill will not do even when asked to "keep going until it's fixed"

- **Never merges into `main`.** The queue is built with `--base dev`; `dev → main` promotion is human-only, always, no exception path here.
- **Never clears `needs-human-review` by removing the label.** It only clears when a fresh `cp-drive` review independently reaches `approve` after the named blocker is actually resolved. Removing a human-judgment gate to make the loop "complete" would defeat the reason the label exists — a design/product call that genuinely needs the user's input doesn't stop needing it because the loop wants to keep moving. If the user wants a specific parked PR pushed through despite this, that's a decision to make on that one PR, not a standing instruction to this skill.
- **Never touches `do-not-merge` / `wip` PRs.** Those are explicit holds; draining around them, not through them, is the correct behavior.
- **Never force-pushes over commits it didn't make.** Rebase conflicts are resolved by editing and re-committing on the PR's own branch, same as a human would; nothing here rewrites another author's history.
- **Doesn't compete with a live daemon** (Step 0) — the daemon and this skill must never process the same PR at the same time.
