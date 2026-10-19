---
name: loop-drain
description: Drain a presented set of GitHub issues and/or PRs to merged, one at a time. I (Claude Code) orchestrate — scope, task specs, no-agent labeling, PRs into dev — write RED tests, and hand GREEN to Command Code (DeepSeek) via /cmd-handoff at every tier, with Pi as fallback when CC is down. The control plane (CP) reviews and AUTO-MERGES — I do not merge manually. Mark every worked issue `no-agent` so the Sandcastle daemon never double-picks it. Use when handed a list of issues/PRs to drain.
---

# Loop Drain

Drain the issues/PRs you are *handed* (a goal: a list, a parent, or "these open PRs") to **merged**, serially, with Command Code (DeepSeek) writing the code and the CP auto-merging. For draining the ENTIRE repo until empty, use `/repo-drain` instead (it wraps this per-item pipeline).

## The four invariants (do not violate)

1. **Command Code writes the code at every tier.** I write the RED test and `tasks/TASK-<slug>.md`, then
   `scripts/drain.sh exec <slug>` hands GREEN to `/cmd-handoff` (DeepSeek V4 Flash, ~$10 per $60 of tokens).
   The budget tier (`~/.local/bin/budget-tier-read`) only changes which Claude model orchestrates.
   - `commandcode status` fails → `drain.sh exec` falls back to `pi-execute` (DeepInfra).
   - CC fails 3 rounds on one seam → I finish inline and say so in the PR.
   <!-- LOCAL DELTA 2026-10-19: CC-first (team workflow docs/context/ai-workflow.md). Was: Claude inline at green/yellow, Pi at red. Preserve across re-syncs. -->
2. **`no-agent` before touching an issue.** Add the `no-agent` label the moment I claim an issue, so the Sandcastle drain daemon doesn't grab it in parallel. (Memory: `no-agent` set *after* a job starts won't stop it — set it FIRST. Check `sandcastle:running:*` isn't already on the issue.)
3. **CP auto-merges — I do not.** I open the PR into `dev` and let the control plane review + merge. I supervise the pinned CP status comment; I never run `gh pr merge` unless the CP is confirmed dead and the user says so.
4. **Wiki + check before PR.** Every feature PR must update `docs/wiki/` for code/behavior changes (CP blocks PRs that lack it → `needs-human-review`) and pass `npm run check`.

## Core flow

```
For each item in the goal (issue or PR):
  Claude Code (me — orchestration only):
    1. Claim: add `no-agent` label, confirm not already sandcastle:running
    2. Read issue / parse acceptance criteria
    3. Write the RED test + tasks/TASK-<slug>.md, then drain.sh exec <slug> (Command Code)
    5. Verify: npm run check, run tests, review diff for scope creep
    6. Update docs/wiki for touched pages
    7. gh pr create --base dev (Closes #N)
    8. Hand to CP: poll the pinned status comment until pi-approved → merged
    9. Closeout, purge context, next item

  Code writer: Command Code (cmd-execute.sh, deepseek/deepseek-v4-flash) at every tier
    CC down/out of credit: pi-execute → deepinfra/deepseek-ai/DeepSeek-V4-Flash
    CC fails 3 rounds: Claude finishes inline
```

## Why CP auto-merge instead of manual merge

The Mac-mini control plane already runs Command Code (DeepSeek, #5687) review on every feature PR into `dev`, runs local security + selective E2E, and auto-merges eligible PRs. Labels drive the gate (the `commandcode` backend reuses the `pi-*` names): `pi-reviewing` → `pi-approved` → (E2E if matched) → merged. My job is to feed it clean PRs and watch the pinned `<!-- control-plane:status -->` comment, not to re-review or merge. Manual merge is the escape hatch only — see Stop conditions.

> Known CP glitch (memory): the review stage sometimes escalates *every* PR to `needs-human-review` with "Agent did not return a machine-readable control-plane result block" even when preflight is green. That's a reviewer backend glitch, not a code finding. When it happens: self-review (`tsc` + read the diff), then `gh pr merge <n> --merge` (use `--merge`, not `--squash`, for stacked branches). Only then do I merge by hand.

## When to use

- "Drain these issues: #142, #143, #150"
- "Drain the children of #416"
- "Fix and merge the open PRs into dev"
- After `/to-tickets` — drain the batch you just filed

## When NOT to use

- Whole repo, everything open → `/repo-drain`
- Issue needs design discussion → `/grill-with-docs` first
- Issue not sliced → `/to-tickets` first

## Invocation

| Command | Effect |
|---------|--------|
| `/loop-drain 142` | Drain single issue #142 |
| `/loop-drain 142,143,150` | Drain in order |
| `/loop-drain --prs` | Drain all open PRs into dev (fix → green → CP merge) |
| `/loop-drain --prs 775,778` | Drain specific PRs |
| `/loop-drain --parent 416` | Discover children of #416, drain them |
| `/loop-drain --queue ./list.txt` | Items from file (one per line) |
| `/loop-drain --max 5` | Stop after 5 merged |
| `/loop-drain --tier heavy` | CC with `--model deepseek/deepseek-v4.1-flash` |
| `/loop-drain status` | Current run ledger |

## Per-item pipeline (issues)

### Phase 0: Claim (no-agent)
```bash
scripts/drain.sh claim <N>        # adds no-agent, aborts if sandcastle:running:* present
```

### Phase 1: Scope & fetch
```bash
scripts/drain.sh issue <N>
```
Parse acceptance criteria from the body. Ambiguous → report blocker, remove nothing, skip.

### Phase 2: Plan the change (task spec for Command Code)
Write the failing test first (RED stays in Claude). Then `scripts/drain.sh task-prep <slug> <N>` stubs `tasks/TASK-<slug>.md`. Fill in: files to touch, exact test command, full-check command, and **enumerate every schema column** the executor needs. Size it so one handoff can finish it.
<!-- LOCAL DELTA 2026-10-19: task spec at every tier (CC-first). Preserve across upstream re-syncs. -->

### Phase 3: Execute (Command Code)
```bash
scripts/drain.sh exec <slug>          # cmd-execute.sh <slug>; Pi fallback if `commandcode status` fails
```
Rounds 2–3 resume the saved CC session (no `--fresh`) with the failing output appended to the task file. After 3 failed rounds, finish inline. On the Pi fallback, beware the false "TOKEN EXHAUSTION" positive: check `~/.pi/agent/sessions` first.

### Phase 4: Verify
1. `npm run check` (typecheck + lint)
2. Run the RED test — must now pass; run `npx tsc --noEmit` yourself (CC review misses compile errors)
3. Review diff: scope creep, files outside scope, removed code
4. `/code-review` runs on CC (`cmd-execute.sh --review <slug>`). Findings → another CC round. Mechanical 1-liner only → inline.

### Phase 5: Wiki
Update the `docs/wiki/` page(s) owning every touched file + bump `last_ingested`. Skip → CP flags `needs-human-review`.

### Phase 6: PR into dev (no merge)
```bash
scripts/drain.sh pr-create <N>        # base dev, "Closes #N"
```

### Phase 7: Hand to CP, supervise
```bash
scripts/drain.sh cp-supervise <PR>    # poll pinned status comment + labels until merged
```
Watch `pi-reviewing → pi-approved → (e2e-pending → e2e-passed) → MERGED`. If CP posts a real review finding → address it (another CC round), push, CP re-reviews. If the "no result block" glitch fires → self-review + manual `--merge`.

### Phase 8: Closeout & context reset
2-line closeout plus a `work-log.sh … closeout` row, refresh `origin/dev`, purge all local file/diff state, re-read next item fresh. Between-item context bleed is the #1 quality regression — be aggressive.

## Per-item pipeline (PRs)

For `--prs`: skip Phases 0-2. For each open PR into dev:
1. `scripts/drain.sh pr-status <PR>` — mergeable? checks? review?
2. Conflicts / red checks → another CC round against the branch (or `/safe-pull` rebase), push.
3. Already green → just `cp-supervise <PR>` and let CP merge.
4. Stale-base risk (memory): a branch behind base can clobber newer files on squash-merge — confirm the branch is up to date with dev before letting it merge.

## Autonomy & looping until done

**Primary — in-session loop.** After scope is set, do NOT ask between items. Push through test/CI/review/conflict/deploy failures. Keep going item-by-item until the goal is drained. Stop only for: missing creds, destructive ambiguity, unclear product intent, CP confirmed dead. Aggressive context purge between items (Phase 8) is what keeps a long run inside one window.

**Fallback — `/loop` to survive context limits.** There is no `/goal` mechanism; this skill loops *within a session*. If the goal is large enough that one context window can't finish it, run the skill under the self-pacing `/loop` skill so it re-invokes and resumes after each context reset:

```
/loop /loop-drain <same args>
```

On each wake-up: re-read the ledger + today's work log + open inventory, skip already-merged items, continue the remaining goal. End the `/loop` (omit the next ScheduleWakeup) once the goal is fully drained — report and stop.

## Status ledger

```
| Item | Phase  | Branch | PR  | CP label    | Status |
|------|--------|--------|-----|-------------|--------|
| #142 | exec   | d-142  | —   | —           | cmd-execute running |
| #143 | queue  | —      | —   | —           | waiting |
```
Closeout line: `#142 DONE pr=#775 cp=merged(abc123)`

## Work log (show-me-your-work)
<!-- LOCAL DELTA 2026-10-14: TSV work log, pattern from pstack show-me-your-work (cursor/plugins@1dcc2ba, MIT © Lauren Tan). Preserve across upstream re-syncs. -->
The ledger above is the live view; the work log is the durable record. At every phase exit append one row:

```bash
~/.claude/scripts/work-log.sh loop-drain "#142" verify "npm run check" "exit 0; foo.test.ts 6/6" ok
```

Args: `<item> <phase> <action> <evidence> <outcome>`, where outcome is `ok|fail|skip|blocked|info`. **The evidence must be checkable**: a command plus its exit code, a test count, a PR or commit URL, a CP label with its timestamp. "Looks good" is not evidence. If a phase has nothing checkable to write, it did not finish. Rows land in `~/.claude/logs/loop-drain/<date>.tsv` and survive context resets and `/loop` wake-ups, so read them back on resume.

The stop report is built **from** `~/.claude/scripts/work-log.sh --summary loop-drain`, not from memory. A claim with no row behind it does not go in the report.

## Stop conditions

Run stops when: goal drained · CC fails 3 rounds AND inline fix not possible · acceptance ambiguous · true external blocker · user interrupts. Report summary on stop: paste `work-log.sh --summary loop-drain` and call out every ⚠ row.

## Script (`scripts/drain.sh`)

```
claim <N>            — add no-agent label, abort if sandcastle:running
issue <N>            — fetch issue JSON
inventory [--label]  — issue + PR inventory
children <parent>    — discover child issues
task-prep <slug> <N> — stub tasks/TASK-<slug>.md
exec <slug>          — cmd-execute.sh <slug> (Pi fallback when CC is down)
pr-create <N>        — open PR into dev, Closes #N
pr-status <PR>       — merge readiness
cp-supervise <PR>    — poll CP status comment + labels until merged
status               — run ledger
```

## References
- `~/.claude/skills/repo-drain/SKILL.md` — whole-repo sweep wrapping this pipeline
- `~/.claude/skills/tdd/SKILL.md` — TDD methodology (RED stays in Claude)
- `docs/context/ai-workflow.md` (team workflow), CLAUDE.md → "Knowledge Wiki" governance, labels
- `scripts/drain.sh` — orchestrator
