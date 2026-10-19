---
name: cp-drive
description: Stand in for the SignPortal control plane and drive one PR all the way to merged when the daemon is slow, stuck, or down. Runs the daemon's own preflight (npm run check + security scan), reviews against automation/prompts/review.md, fixes blockers inline, applies the same labels and pinned status comment, and merges into dev once every gate the daemon enforces is green. Use when the user says the control plane is slow/stuck/backed up, asks you to review or merge a PR "like the control plane", or asks to unblock a PR waiting on CP review.
---

You are standing in for the control-plane daemon (`automation/`) on one pull request. Same contract, same criteria, same labels — a human reading the PR afterwards should not be able to tell whether the daemon or you did the review.

**The review criteria are NOT in this file.** They live in `automation/prompts/review.md`, which is what the daemon feeds its reviewer. Read that file at the start of every run and follow it. Duplicating the criteria here would let the two drift apart, and a stand-in that reviews by different rules is worse than no stand-in.

## Routing

<!-- LOCAL DELTA (foundedph, 2026-10-14, updated 2026-10-19): the review and blocker
     fixes go to Command Code via /cmd-handoff's wrapper to save Claude tokens. Preserve
     this section across upstream re-syncs. -->

The daemon's own reviewer is Command Code (`agentBackend: "commandcode"` since #5687, v4-flash escalating to v4.1-flash, Pi as fallback), so this stand-in hands the same job to Command Code (`deepseek/deepseek-v4-flash`). Claude keeps the mechanical and authority steps, which are cheap and must be deterministic:

| Step | Runs on |
|---|---|
| 0 safety check, 1 preflight, 3 verdict validation, 4 labels/comments, 5 merge gates + merge | This session, on Sonnet (Haiku at the `red` budget tier). None of it needs Opus. |
| 2 review against `automation/prompts/review.md`, and the edits for a `fixed` verdict | Command Code, through the `cmd-handoff` skill's `scripts/cmd-execute.sh` |
| An `escalate` verdict | Re-checked by this session on the named issue only, before parking the PR |

Merge authority, label changes, and the never-`main` rule are never handed off. If `commandcode status` is not authenticated, or the executor fails (exit 1, 2, 4 or 5) twice, run step 2 inline and say so.

## 0. Confirm the takeover is safe

The daemon must not be working the same PR concurrently — both of you pushing to the head branch corrupts the PR.

```bash
gh pr view <PR> --json number,title,author,baseRefName,headRefName,labels,mergeable,mergeStateStatus,isDraft
```

- `pi-reviewing` present → a session may be live. Check whether the daemon is actually alive before proceeding: `ssh wlq@100.86.147.86 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8791/api/health'` (expect 200 — `lsof -i :8791` as `wlq` cannot see a daemon owned by `it` and falsely reads as down) (see `automation/scripts/CONTROL-PLANE-DEPLOY.md`). If it is up and recently active, say so and stop — the wait is normal, not a failure.
- `needs-human-review` / `do-not-merge` / `wip` → the daemon already parked this PR. Review is still useful, but merging is a human decision; do not remove those labels yourself.
- Draft PRs are skipped by the daemon. Say so and stop unless the user explicitly wants it reviewed anyway.

State your read of the situation in one line, then proceed.

## 1. Preflight (what the daemon does before the reviewer sees anything)

Work in a worktree of the PR head — never in a dirty checkout:

```bash
gh pr checkout <PR>
```

Then run the preflight gates:

```bash
npm run check > /tmp/cp-check-<PR>.log 2>&1; echo "check exit $?"; tail -40 /tmp/cp-check-<PR>.log
node --import tsx automation/scripts/security-scan.ts <baseRef>
node --import tsx scripts/lint-floor-guard.ts --base origin/<baseRef>
```

Read only the tail of the check log (grep it for a failing group if needed). The full output is large and the reviewer gets the log path, not its contents.

`security-scan.ts` is a thin CLI over `automation/security-check.ts` — the *same* rule set the daemon runs, so your findings match its findings. Exit 1 means findings. Docs-only PRs skip `npm run check`, exactly as `automation/policy.ts` classifies them.

`lint-floor-guard.ts` reports any check the PR weakened (see `CONSTRAINTS.md` → Floor); the review prompt's task step 10 says how to resolve each finding. Exit 1 means findings, 2 means the base ref is missing.

Record the first two outcomes; the review prompt takes them as inputs (`baselineCheckStatus`, `securityCheckStatus`) and unresolved security findings are a blocking criterion.

## 2. Review — handed to Command Code

Write `tasks/TASK-cp-review-<PR>.md` in the PR checkout. It must stand alone:

- goal: review PR #<PR> by executing `automation/prompts/review.md`, with the placeholder values listed (PR metadata, `docsOnly` from `classifyPaths` in `automation/policy.ts`, the two preflight statuses, the check log path, `git diff <baseRef>...HEAD` as the diff command)
- for a `fixed` verdict: make the fixes in the working tree, but do not commit, and do not touch `.env*`, lockfiles, `tasks/`, or files outside the PR's scope
- output: the `CONTROL_PLANE_RESULT_START … END` block, verbatim, under `## Executor results`

**Never commit this task file** — `tasks/TASK-*` is tracked in ERP and it would land on the PR head. Delete it and `tasks/.logs/TASK-cp-review-<PR>.*` when done.

```bash
bash <cmd-handoff-dir>/scripts/cmd-execute.sh --fresh cp-review-<PR>
```

`<cmd-handoff-dir>` is the `cmd-handoff` skill's directory. The exit codes are listed in that skill. Then read only the `## Executor results` section and `git diff --stat`; don't re-read the whole diff yourself unless step 3 needs it.

The prompt makes two things explicit that reviewers routinely get wrong. Put both in the task file:

- **Fix blockers inline rather than escalating.** Multi-file fixes are in scope. Escalate only for design judgment, product decisions, or missing context.
- **Missing `docs/wiki/` coverage is yours to write, not to escalate.** CLAUDE.md's wiki governance is hard-enforced; the prompt's step 9 is the procedure.

For a diff large or risky enough that you want a second, independent pass, spawn a subagent with `model: "sonnet"` that runs the `code-review` skill's Standards axis over the same range, and fold its findings in. That skill is deeper on code smells and spec fidelity; this one owns the merge decision. They are complements — see "Relationship to `code-review`" below.

## 3. Verdict

Validate the executor's block before acting on it:

- It parses as JSON with one of the four actions. If not, re-run the wrapper once without `--fresh` so the session resumes; if it fails again, run step 2 inline.
- `fixed` → the working tree actually changed, only in-scope files, and `npm run check` + the security scan pass again. Otherwise feed the failures back as a `## Review round <n>` (max 3 rounds), then take over inline.
- `approve` with failing preflight or unresolved security findings is invalid. Treat it as `escalate`.
- `escalate` → check the named blocking issues yourself. If one is really a mechanical fix, send it back as a round instead of parking the PR.

The final verdict is the daemon's result block, verbatim — same four actions, same JSON shape as the end of `automation/prompts/review.md`:

```
CONTROL_PLANE_RESULT_START
{"action":"approve|fixed|escalate|skip","summary":"…","commitMessage":"…","blockingIssues":[]}
CONTROL_PLANE_RESULT_END
```

Emit it even though no daemon is parsing it: it keeps your verdict auditable against the daemon's own history, and forces the same discipline about what counts as `fixed` versus `escalate`.

## 4. Act on the verdict

**`fixed`** — after step 3's re-check, stage the in-scope files by path (never `git add -A`, never `tasks/`), commit with the `commitMessage`, and push to the head branch. Do not touch `.env*`, lockfiles, or files outside PR scope.

**`approve` / `skip` / `fixed`-and-green** — apply the daemon's labels:

```bash
gh pr edit <PR> --add-label pi-approved --remove-label pi-reviewing
```

Label names come from `automation/label-utils.ts` and depend on the configured backend. The `commandcode` backend reuses the `pi-*` names (`pi-reviewing`, `pi-approved`). Read that file rather than assuming.

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
