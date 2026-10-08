---
name: issue-drain
description: Drain the open issue queue into the integration branch end to end — implement each ready issue test-first on its own worktree, review it, run the browser pass, open a PR, and drive that PR to merged. Fans implementation and review across parallel sub-agents and funnels the merge lane down to one at a time, so a PR landing never invalidates in-flight work.
disable-model-invocation: true
argument-hint: "[maxIssues] [--concurrency N] [--dry-run]"
---

# Issue drain

One supervised loop that runs a whole issue backlog to merged:

```
/implement → /code-review → PR → merge review → merged      (repeat until dry)
```

This skill **orchestrates**; it owns none of the contracts it chains. Invoke them, never restate them:

| Phase | Contract | Notes |
| --- | --- | --- |
| Implement | `/implement` | TDD-first, budget-tier routing, verify, then close out with `/code-review` |
| Review | `/code-review` | Standards + Spec axes, run as **parallel sub-agents** |
| Merge review | the repo's merge reviewer | A control-plane review contract if the repo has one; otherwise its contributing standards plus the merge gate in 4F |

**This merges PRs repeatedly, without checking in between.** That is what "drain" means. State the plan once (step 0), then run it. The skill is `disable-model-invocation: true` — running it *is* the confirmation.

## 0. Read the repo profile

Nothing here is hardcoded to a particular repo. Discover the profile first, **print it**, and let the user correct it before anything merges. Full discovery rules and fallbacks: [references/repo-profile.md](references/repo-profile.md).

| Fact | Where it comes from |
| --- | --- |
| Issue tracker + how to list / read / close | `docs/agents/issue-tracker.md` |
| Integration branch (the PR base) | `dev` if it exists on the remote, else the default branch |
| Verification command | the repo's `check` / `typecheck` / `test` script |
| Browser (E2E) command, and when it is required | the repo's E2E script; required when a diff touches user-facing UI |
| Merge review criteria | the repo's review contract if it has a control plane; else its contributing standards + the gate in 4F |
| Skip labels and blockers | the repo's label guide if it has one; else the canonical triage set |
| Worktree directory | a gitignored directory **inside** the repo |

If a fact cannot be discovered, **ask once** and record the answer in `docs/agents/drain.md` so the next run does not ask again. A drain that guesses the integration branch is worse than one that asks.

## 0.5 Preconditions

1. **Right repo, right base.** Confirm the integration branch; PRs never target the release/production branch.
2. **Check for a competing writer.** If the repo runs an autonomous drain (a daemon, a scheduler, a control plane), find out whether it is alive and moving. If it owns the queue, run the fan-out lane only — implementation is the work it cannot do — and let it merge; stand in for the merge lane only where it has visibly stalled. Never run two writers on one issue or one PR.
3. **Clean base.** `git fetch` the integration branch; the base checkout is clean or its dirt is accounted for.

## Model policy

Implementation and review fail differently, so they get different models:

| Phase | Model | Why |
| --- | --- | --- |
| Implement (`general` sub-agent) | `deepseek/deepseek-v4-flash` | Cheap and fast — trusted **only** because the TDD gate below is enforced |
| Review (`/code-review` axes) | `deepseek/deepseek-v4.1-flash` | Review is where a weak model silently passes bad work, so harden it |

Pass the model as a **per-run override on the `agent` tool** (`model:`); do not change the session model. Override either with `--implement-model` / `--review-model`.

## The TDD gate — what makes the cheap implementer safe

The implementer runs on a fast model, which is acceptable only while TDD is **strictly** followed. Enforce it; do not assume it:

1. **RED first, with evidence.** For every unit of behaviour the implementer writes the failing test *before* the implementation, and reports the **actual failing run** — the command and the output showing the assertion red. A test never seen to fail is not a test.
2. **GREEN second.** Implement the minimum to pass it, then re-run to green.
3. **The orchestrator rejects the handoff without RED evidence.** No failing-run output for a behaviour change → send it back. This is the single check that makes the cheap model safe.
4. **Skip only when there is genuinely nothing to assert** — pure config, docs, a rename — and say so explicitly in the handoff. "Hard to test" is a seam problem (fix the seam), never a reason to skip.
5. **Test authorship is never delegated**, at any model tier, and the Spec review axis verifies the tests assert the ticket's acceptance criteria rather than restating the implementation.

## 1. Build the queue

Follow the tracker workflow the profile names, then **exclude**:

- issues carrying a skip label — the repo's opt-out (e.g. `no-agent`), its legacy aliases, epics/parents, and any in-flight claim label,
- issues whose body declares an **open** blocker, or a **prose-only** blocker that reads as a permanent manual hold,
- issues that fail the repo's spec-readiness check, if it has one — an issue with no binary acceptance criteria will thrash.

`ready`-style labels are usually **ignored** by opt-out drains. Don't require one, and don't add one to force an issue through. Blockers are normally **body-driven, not label-driven** — check the profile.

## 2. Order it

1. **Blockers first.** An issue blocked by another in this same queue runs after its blocker. Track this with the durable task ledger (`task_create` with `blockedBy`) — that is the tool's exact purpose, and it survives a context compaction mid-drain.
2. **Then the repo's priority rule.** Hotfixes and fix-type changes touching shared infrastructure jump the queue; within a tier, oldest first.

## 3. Two lanes — parallel where it pays, serial where it must

Merges into the integration branch are **serialised**: the moment one PR lands, every other open PR is behind it and needs a rebase. Work done on a second PR concurrently is therefore *thrown away* when the first lands. That one fact dictates the shape:

- **Fan-out lane — parallel.** Implementation, the unit tests, the verification command, and the two review axes are all worktree-local: they touch neither the integration branch nor another PR. Run them concurrently, one git worktree per issue.
- **Fan-in lane — serial, parent-owned.** PR creation → merge review → browser pass → merge. **One at a time**, in merge-gate order, re-fetching the integration branch before each merge.

**Concurrency defaults to 2** in-flight issues (`--concurrency N` overrides). Not a harness limit — a pipeline limit: at depth *d*, a PR that lands invalidates the rebase work of the other *d−1*, and the browser pass is serial anyway (4E). Depth 3+ mostly buys discardable work. Depth 1 is right when the issues are large or the machine is loaded.

The parent session owns the merge lane: sub-agents are never granted the spawn-shaped tools, worktree tools, or `ask_user_question`, and merging is judgment, not typing.

## 4. The per-issue pipeline

A phase that fails beyond its retry budget **parks** the issue (step 5) — it never blocks the lane.

### A. Implement — fan-out sub-agent, background

Create the worktree **inside the repo** — a gitignored directory keeps every file and shell call inside the workspace boundary, whereas an external worktree root trips the outside-workspace gate:

```bash
git worktree add <worktree-dir>/issue-<n> -b <type>/<n>-<slug> <integration-branch>
```

Dispatch one **`general`** sub-agent with `run_in_background: true` and a self-contained prompt containing:

- The issue **title + body verbatim** — the body is the spec. Include any richer executor spec the repo keeps for it.
- The absolute worktree path. All work happens there, never in the base checkout.
- `/implement`'s contract: TDD-first at every seam, per the gate above; budget-tier routing; run the verification command and the touched tests; **do not commit, do not push, do not open a PR** — the parent owns publishing.
- The scope fence: touch only what the issue names; no scope creep; carry whatever documentation the repo's contribution rules require for the change in the same branch.

Collect with `agent_output({ agent_id, action: "wait" })` — or keep going and collect later, which is the point of the background lane.

### B. Review — two parallel sub-agents

Run `/code-review` over `git diff <integration-branch>...HEAD` **in the worktree**, exactly as that skill specifies: a **Standards** sub-agent and a **Spec** sub-agent, dispatched **in one message so they run in parallel**, both with `model: deepseek/deepseek-v4.1-flash`. Paste the full smell baseline into the Standards prompt — the sub-agent has no other access to it. The spec source is the issue body from phase A.

### C. Fix findings — bounded, inline

Fix in-scope findings in the worktree, then re-run the verification command and the touched tests. Cap at **2** review→fix rounds; anything still failing is a design escalation (step 5), not a third round.

### D. Publish — parent-owned

Commit in the worktree (conventional message with the issue reference), push the branch, then open a PR **against the integration branch**. Confirm the repo's documentation criterion is met before opening — a control plane will block the merge without it.

### E. Browser pass — serialised, parent-owned

Decide from the PR's changed files whether a browser pass is required: **skip** for docs/CI-only, **smoke** for anything that renders or restyles user-facing UI, **full** for auth, middleware/permissions, and other high-blast-radius paths. The profile names the command (`npm run test:e2e`, `bash tests/e2e/run.sh <file>`, `playwright test`, …).

**E2E is a single-lane resource** — it usually needs one running server and one shared database, so two concurrent runs clobber each other. Take a lock before running and release it in a `finally`:

```bash
LOCK="${COMMANDCODE_SCRATCHPAD}/e2e.lock"; mkdir "$LOCK" 2>/dev/null || echo "e2e busy — wait"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
```

Record the outcome on the PR (the merge-gate label the repo uses). **A UI-touching PR never merges without browser evidence** — that gate exists because reviews kept merging visual changes unseen.

### F. Drive to merged — parent-owned

Run the merge reviewer the profile named, against this PR: preflight (verification command + the repo's security scan if it has one), review against the repo's review criteria, fix blockers **inline** (multi-file fixes are in scope; missing documentation coverage is yours to write, not to escalate), apply the labels, and check **every** gate before merging:

1. Base is the **integration branch** — never the release/production branch.
2. Not a draft.
3. Approved by the reviewer.
4. Carries no blocking or parked label.
5. Merge state is clean — a behind/dirty branch needs a rebase first.
6. Required CI checks pass.
7. The browser gate is satisfied.

**Re-fetch the gate set immediately before merging** — the integration branch moves if an earlier PR in this same drain landed, so anything read at the top of the loop is stale. Retarget stacked children before deleting a head branch.

## 5. Supervision loop

Repeat until a full pass merges **nothing** and unblocks **nothing** — that is the fixed point:

1. **Refill** the fan-out lane from the ready queue while in-flight < concurrency.
2. **Collect** finished implementers, advance each through B → C → D.
3. **Advance the merge lane** — the PR that holds the gate, one at a time; rebase anything that went behind as the lane moved.
4. **Repair, bounded** — one repair attempt per issue per pass (mirroring the reviewer's own repair cap): trivial conflicts (generated/append-only files, lockfiles, non-overlapping hunks) resolve inline; a conflict where both sides changed the *same logic* is a judgment call → park it. A failing browser pass is read, fixed if in scope, retried; cap 2.
5. **Park, don't stall** — an issue past its budget gets the repo's opt-out label plus a comment naming the concrete blocker, and leaves the lane. Never leave it in flight forever, and never retry it again in this run.

**Safety cap:** ~50 passes without reaching the fixed point is a bug, not a backlog. Stop, say so, and report state as of the cap.

## 6. State

- **Task ledger** (`task_create` / `task_update`) — one task per in-scope issue, with `blockedBy` edges. The durable record; it survives restarts and makes step 2's ordering computable.
- **Scratchpad** — `${COMMANDCODE_SCRATCHPAD}/drain-state.json` for machine state (phase per issue, attempt counts, PR numbers). Durable deliverables live in the tracker and the PRs, not here.
- **`todo_write`** — the live checklist for the current pass, so the TODOS panel tracks the drain.

## 7. Final report

One summary at the end, not a comment per issue beyond what the merge reviewer already posts:

- **Merged** — issue and PR numbers with titles, in landing order.
- **Unblocked by this drain** — issues that became eligible once a merged PR closed their blocker.
- **Parked for a human** — issue numbers plus the concrete blocker, one line each. *This is the list the user actually needs.*
- **Skipped by design** — opt-out labels, epics, and daemon-owned issues, so it is clear they were not forgotten.
- **Not ready** — issues that failed the readiness check, with the reason.

## Boundaries — not crossed even when told "keep going until it's fixed"

- **Never merges into the release/production branch.** The queue targets the integration branch; promoting it further is human-only, always.
- **Never clears a human gate to make the loop complete.** A `needs-human*` label clears only when a fresh review independently approves after the named blocker is actually resolved — never by removing the label.
- **Never touches explicit holds** (`do-not-merge`, `wip`, opt-out) — draining *around* them, not through them.
- **Never force-pushes over commits it did not make.** Conflicts are resolved by editing and re-committing on the branch, as a human would.
- **Never merges a UI-touching PR with no browser evidence.**
- **Never races a live writer** — one writer per issue, one merger per PR.

## Harness mechanics (why the shape is this shape)

- **Sub-agents are one level deep** — they cannot spawn their own. Every orchestration decision stays in the parent; sub-agents are leaves.
- **Sub-agents auto-allow where the parent would prompt** (except safety checks, which fail closed), so a background implementer does not hang on a permission prompt. But they are never granted `agent`, `agent_output`, `run_command`, worktree tools, `ask_user_question`, or `sleep` — hence the parent owns publishing, the browser pass, and merges.
- **`run_in_background` + `agent_output`** is the fan-out primitive; `monitor_command` or `shell_output({wait:"exit"})` is the right way to await a long build/test/E2E verdict without polling.
- **Worktrees go in a gitignored directory inside the repo**, so sub-agents never hit the outside-workspace gate and the worktrees never pollute `git status`.
- **Do not run the drain under permission bypass.** Confidence comes from the gates, not from disabling prompts; if the repo wants guards, add `deny` rules (they outrank every mode).
