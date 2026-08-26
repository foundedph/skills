---
name: cp-drive
description: Stand in for the SignPortal control plane and drive one PR all the way to merged when the daemon is slow, stuck, or down. Runs the daemon's own preflight (npm run check + security scan), reviews against automation/prompts/review.md, fixes blockers inline, applies the same labels and pinned status comment, and merges into dev once every gate the daemon enforces is green. Use when the user says the control plane is slow/stuck/backed up, asks you to review or merge a PR "like the control plane", or asks to unblock a PR waiting on CP review.
---

You are standing in for the control-plane daemon (`automation/`) on one pull request. Same contract, same criteria, same labels — a human reading the PR afterwards should not be able to tell whether the daemon or you did the review.

**The review criteria are NOT in this file.** They live in `automation/prompts/review.md`, which is what the daemon feeds its reviewer. Read that file at the start of every run and follow it. Duplicating the criteria here would let the two drift apart, and a stand-in that reviews by different rules is worse than no stand-in.

## 0. Confirm the takeover is safe

The daemon must not be working the same PR concurrently — both of you pushing to the head branch corrupts the PR.

```bash
gh pr view <PR> --json number,title,author,baseRefName,headRefName,labels,mergeable,mergeStateStatus,isDraft
```

- `pi-reviewing` present → a session may be live. Check whether the daemon is actually alive before proceeding: `ssh wlq@192.168.2.6 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8791/api/health'` (expect 200 — `lsof -i :8791` as `wlq` cannot see a daemon owned by `it` and falsely reads as down) (see `automation/scripts/CONTROL-PLANE-DEPLOY.md`). If it is up and recently active, say so and stop — the wait is normal, not a failure.
- `needs-human-review` / `do-not-merge` / `wip` → the daemon already parked this PR. Review is still useful, but merging is a human decision; do not remove those labels yourself.
- Draft PRs are skipped by the daemon. Say so and stop unless the user explicitly wants it reviewed anyway.

State your read of the situation in one line, then proceed.

## 1. Preflight (what the daemon does before the reviewer sees anything)

Work in a worktree of the PR head — never in a dirty checkout:

```bash
gh pr checkout <PR>
```

Then run the two preflight gates:

```bash
npm run check
node --import tsx automation/scripts/security-scan.ts <baseRef>
```

`security-scan.ts` is a thin CLI over `automation/security-check.ts` — the *same* rule set the daemon runs, so your findings match its findings. Exit 1 means findings. Docs-only PRs skip `npm run check`, exactly as `automation/policy.ts` classifies them.

Record both outcomes; the review prompt takes them as inputs (`baselineCheckStatus`, `securityCheckStatus`) and unresolved security findings are a blocking criterion.

## 2. Review

Read `automation/prompts/review.md` and execute it against this PR, substituting the placeholders with the real values you gathered (PR metadata, `docsOnly` from `classifyPaths` in `automation/policy.ts`, the two preflight outputs, changed files, diff).

Two things that prompt makes explicit and reviewers routinely get wrong:

- **Fix blockers inline rather than escalating.** Multi-file fixes are in scope. Escalate only for design judgment, product decisions, or missing context.
- **Missing `docs/wiki/` coverage is yours to write, not to escalate.** CLAUDE.md's wiki governance is hard-enforced; the prompt's step 8 is the procedure.

For a diff large or risky enough that you want a second, independent pass, run the `code-review` skill's Standards axis over the same range and fold its findings in. That skill is deeper on code smells and spec fidelity; this one owns the merge decision. They are complements — see "Relationship to `code-review`" below.

## 3. Verdict

Produce the daemon's result block verbatim — same four actions, same JSON shape as the end of `automation/prompts/review.md`:

```
CONTROL_PLANE_RESULT_START
{"action":"approve|fixed|escalate|skip","summary":"…","commitMessage":"…","blockingIssues":[]}
CONTROL_PLANE_RESULT_END
```

Emit it even though no daemon is parsing it: it keeps your verdict auditable against the daemon's own history, and forces the same discipline about what counts as `fixed` versus `escalate`.

## 4. Act on the verdict

**`fixed`** — re-run `npm run check` and the security scan on your edits, then commit with the `commitMessage` and push to the head branch. Do not touch `.env*`, lockfiles, or files outside PR scope.

**`approve` / `skip` / `fixed`-and-green** — apply the daemon's labels:

```bash
gh pr edit <PR> --add-label pi-approved --remove-label pi-reviewing
```

Label names come from `automation/label-utils.ts` and depend on the configured backend (`pi` today, hence `pi-approved`). Read that file rather than assuming.

**`escalate`** — `gh pr edit <PR> --add-label needs-human-review` and post a comment naming the blocking issues concretely. Do not leave `pi-reviewing` behind.

**E2E gate** — `classifyPaths` decides whether this PR needs a browser pass (`skip` / `smoke` / `full`). If it returns `smoke` or `full` and the PR lacks `e2e-passed`, the merge is gated on E2E regardless of your review; either run `npm run test:e2e` locally against the branch and say so, or leave the PR for the daemon's E2E stage. **Do not merge a UI-touching PR with no browser evidence** — that gate exists because reviews kept merging visual changes unseen (`automation/policy.ts`, UI_TOUCH_E2E_PATTERNS).

**Status comment** — the daemon keeps one pinned comment carrying the marker `<!-- control-plane:status -->` and edits it in place. If one exists, edit it (`gh api` on the comment id) rather than posting a new one; note in it that this pass was a manual stand-in. If none exists, post a fresh comment with the same marker.

## 5. Merge into `dev`

The daemon merges a PR the moment every gate is green, and so do you. Waiting for a human to confirm a green PR just reintroduces the delay the stand-in exists to remove. Re-fetch the PR (labels and mergeability change while you work) and merge only when **all** of these hold — this is the daemon's own gate set, from `automation/daemon.ts` and `automation/merge-gate.ts`:

1. Base branch is `dev`. **Never merge into `main`** — `dev → main` promotion is manual and human-only, always.
2. Not a draft.
3. Carries the approved label (`pi-approved` — read `automation/label-utils.ts`, it is backend-dependent).
4. Carries none of `do-not-merge`, `wip`, `needs-human-review` (`BLOCKING_LABELS`), and none of `e2e-failed` (`PARKED_LABELS`).
5. `mergeStateStatus` is `CLEAN` — not `BEHIND`, `DIRTY`, or `BLOCKED`. A behind/dirty branch needs conflict repair first, which the stand-in does not do; say so and stop.
6. Required CI checks are passing (`gh pr checks <PR>`).
7. The E2E gate is satisfied: if `classifyPaths` returned `smoke` or `full`, the PR carries `e2e-passed`, or you ran the browser pass yourself and said so in the status comment. A UI-touching PR never merges on review alone.

Any gate failing means **stop and report**, not "merge anyway" — each one exists because something merged past it before.

When all gates pass:

```bash
gh pr merge <PR> --squash
```

`--squash` matches `GitHubClient.mergePullRequest` (`merge_method: "squash"`); branch history is discarded either way. Use `--merge` instead when the PR is part of a stack, so the child PRs keep a real parent commit.

**Before deleting the head branch, retarget stacked children.** GitHub auto-closes every PR whose base branch is deleted, which silently kills the next PR in a stack:

```bash
gh pr list --base <headRefName> --state open --json number
gh pr edit <childPR> --base dev      # for each child
git push origin --delete <headRefName>
```

Skip the branch delete entirely if you are unsure — a leftover branch is harmless; a closed child PR is not.

After merging, update the pinned `<!-- control-plane:status -->` comment with the merge outcome, and note that a manual stand-in drove it. Merging into `dev` does **not** deploy; the daemon's deploy stage is separate and is not stood in for.

## Relationship to `code-review`

Two different jobs; keep them separate.

| | `cp-drive` (this skill) | `code-review` |
|---|---|---|
| Question | May this merge into `dev`? | Is this code good, and does it match the spec? |
| Criteria | `automation/prompts/review.md` — the daemon's contract | Repo standards + Fowler smell baseline + originating issue/PRD |
| Scope | One open PR | Any diff since a fixed point |
| Output | `CONTROL_PLANE_RESULT_*` block, labels, merge | Two-axis findings report |
| Authority | Fixes inline, labels, merges | Reports only |

`cp-drive` may call `code-review` for depth on a risky diff. The reverse is not true, and `code-review` never merges.

## What is deliberately NOT done here

The daemon also runs check-repair loops, conflict repair, E2E fix iterations, deploy triggering, and retrospectives. Standing in for those by hand is rarely worth it — if the daemon is down long enough for those to matter, fix the daemon (`automation/scripts/CONTROL-PLANE-DEPLOY.md`, `automation/scripts/doctor.sh`) instead of hand-driving its pipeline.

To drive the *whole* open-PR queue this way — not just one PR, including rebasing and repairing the ones parked on `needs-rebase` or `e2e-failed` — use the `cp-drain` skill (`.claude/skills/cp-drain/SKILL.md`). It calls this skill's Steps 0-5 once per PR in merge-gate order; it does not duplicate them.
