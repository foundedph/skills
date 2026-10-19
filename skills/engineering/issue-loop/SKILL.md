---
name: issue-loop
description: Autonomously execute open GitHub issues one-by-one using TDD with model orchestration. Reads issues from configured repos, picks the next unblocked one by label priority, runs RED (Claude writes failing test) → GREEN (Command Code via /cmd-handoff at every tier; Pi fallback when CC is down) → REFACTOR (reviewer audits), opens a PR, and advances. Supports manual single-issue, full-pass, and watch modes. Use when the user wants to drain an issue queue, says "work through the issues", or wants to autopilot a backlog.
---

# Issue Loop

<!-- LOCAL DELTA (foundedph, 2026-10-19): upstream hardwires GREEN to Codex.
     Here GREEN goes to Command Code (DeepSeek) via /cmd-handoff at every tier,
     Pi only when `commandcode status` fails (docs/context/ai-workflow.md).
     Preserve across upstream re-syncs; grep 'LOCAL DELTA' to find every such edit. -->

Drives an issue queue from `gh issue list` to merged PR, one issue at a time, using the existing TDD skill with phased model handoffs (Claude → Command Code → CC v4.1 review).

## When to use

- User has run `/to-spec` + `/to-tickets` and now wants the issues executed
- User says "work through the issues", "drain the queue", "autopilot the backlog"
- User wants `--watch` mode to pick up new issues as they're filed

## When NOT to use

- A single issue needs design discussion → use `/grill-me` first
- Issues are not yet sliced into tracer bullets → run `/to-tickets` first
- The work is exploratory, not implementation → stay in Claude Code interactively

## Invocation

### Default (queue-driven)
```bash
/issue-loop                                  # full pass over all configured repos
/issue-loop --repo signportal                # single repo, one shot
/issue-loop --watch                          # poll continuously (default 10 min)
/issue-loop --dry-run                        # plan only, no PRs
```

### Targeted (override the queue)

| Flag | Behavior |
|------|----------|
| `--issue 142` | Run exactly this one issue, ignore everything else |
| `--issues 142,143,150` | Allow-list of specific issues, processed in order given |
| `--queue ./issues.txt` | File of issue numbers (one per line); processed in file order, label rules ignored |
| `--exclude 99,150` | Run normally but skip these |
| `--label priority:high` | One-shot override of `label_filter` (replaces, not appends) |
| `--milestone "Sprint 5"` | Restrict to a GitHub milestone |
| `--assignee @me` | Only issues assigned to you |
| `--max 3` | Stop after 3 successful issues (drain partially) |

### Combinations

```bash
/issue-loop --repo signportal --milestone "v2.1" --max 5
# Up to 5 issues from the v2.1 milestone in signportal

/issue-loop --queue ./hotfixes.txt --repo signportal
# Run exactly these issues in this order from signportal

/issue-loop --label bug --label priority:high
# Both labels required (AND across multiple --label flags)

/issue-loop --watch --milestone "Sprint 5"
# Watch mode but only ever pick up issues in the active sprint
```

### Resolution order (most specific wins)

1. `--issue` (single issue mode)
2. `--queue <path>` or `--issues <list>` (explicit allow-list)
3. `--milestone` + `--assignee` + `--label` + `--exclude` (filtered query)
4. Config-based queue (`label_filter`, `label_skip`, `priority_labels`)

When a queue file is supplied, **`label_filter` is ignored** but `label_skip` still applies (so you can't accidentally process a `wip` issue even if it's listed).

## Pipeline (one cycle per issue)

```
1. SELECT     gh issue list → filter by labels → sort by priority
2. WORKTREE   git worktree add .claude/worktrees/issue-<N>-<slug>
3. PLAN       [Claude] parse Acceptance Criteria from issue body
              if ambiguous → notify, skip to next
4. for each behavior in criteria:
     RED      [Claude] write ONE failing test (only this behavior)
              run tests; abort if not exactly +1 failing
     GREEN    write tasks/TASK-issue-<N>-<slug>.md (orchestration.md), then
                  bash ~/.claude/skills/cmd-handoff/scripts/cmd-execute.sh issue-<N>-<slug>
              CC down → /auto-handoff (Pi); CC fails 3 rounds → finish inline
              retry up to 3, extend to 5 then 10 if progressing
              hard-fail signals trigger immediate bail
     REFACTOR [CC v4.1] cmd-execute.sh --review <slug>; Claude runs tsc + tests itself
              if must_fix → another CC round, re-run tests
5. PR         [Claude] write body with "Closes #N", `gh pr create`
6. LOG        write run JSON to ~/.claude/issue-loop/runs/<repo>/<N>.json
              + one work-log.sh row per phase exit (see Run logs)
7. ADVANCE    next issue (or sleep watch_interval if --watch)
```

The control plane (Command Code backend) handles the PR → merge → deploy chain after step 5. The loop does not wait for merge.

## Stop conditions

The loop stops the **entire run** (not just skips the issue) when:

- Executor GREEN exhausts the retry budget without passing
- Test file modification detected (the executor violated the contract)
- Empty diff repeated (the executor looping)
- Acceptance criteria parsed as ambiguous

A Telegram notification is posted via the `plugin:telegram:telegram` MCP if `notifications.telegram_chat_id` is configured. The issue is labeled `needs-human-review`.

This conservative stop policy is intentional: it preserves attention on real problems instead of letting failures accumulate silently.

## Progress detection (the retry extender)

See [progress-detector.md](progress-detector.md) for full rules. Summary:

- **Progressing** (extends retry budget): failing test count drops, error type advances (compile → assertion), error line moves forward, non-redundant diff
- **Stuck** (immediate bail, ignores remaining budget): identical error + identical diff, empty diff, executor modified the test file

## Model handoffs

See [orchestration.md](orchestration.md) for the full RED/GREEN/REFACTOR contract and how each model is invoked. Summary:

| Phase | Model | Why |
|-------|-------|-----|
| PLAN | Claude (Opus or Sonnet, current session) | Behavior intent; must understand domain |
| RED | Claude | Test = behavior spec; only Claude understands what to assert |
| GREEN | Command Code (`deepseek/deepseek-v4-flash`) | Bounded mechanical task: pass one test |
| REFACTOR | Command Code `--review` (`deepseek/deepseek-v4.1-flash`) + Claude-run tsc/tests | Cheap review; CC misses compile errors, so tsc is mandatory |
| If must-fix | Command Code round (resumed session) | Targeted cleanup |
| PR review | `reviewer` / `reviewer-deep` | `review-route.sh` (project `scripts/`, else `~/.claude/scripts/`); risk signals add `reviewer-deep` (Opus) |

## Config

Global config lives at `~/.claude/issue-loop.config.json`. Per-repo overrides at `<repo>/.claude/issue-loop.json`.

See [config-schema.md](config-schema.md) for the full schema and example.

## Run logs

Every issue execution writes a structured JSON log to `~/.claude/issue-loop/runs/<repo>/<issue>.json` (see [config-schema.md](config-schema.md) for the schema). These logs are the upgrade path to the Phase B daemon — see [upgrade-to-daemon.md](upgrade-to-daemon.md).

**Work log (show-me-your-work).** <!-- LOCAL DELTA 2026-10-14: pstack show-me-your-work (cursor/plugins@1dcc2ba, MIT © Lauren Tan). Preserve across re-syncs. --> The run JSON records the outcome. The TSV records how each phase got there, one row per phase exit:

```bash
~/.claude/scripts/work-log.sh issue-loop "#88" red "wrote failing test" "tests/foo.test.ts: +1 failing (1/7)" ok
```

Phases are `select|worktree|plan|red|green|refactor|pr|advance`. Evidence must be checkable: a command with its exit code, a before→after failing-test count, a PR URL. A phase with no checkable evidence did not finish. The end-of-run report (and any Telegram stop notice) quotes `~/.claude/scripts/work-log.sh --summary issue-loop` rather than restating from memory.

## Implementation pointer

The orchestrator script is at `scripts/run.sh` in this skill directory. It wraps `gh`, manages worktrees, and writes run logs (GREEN is invoked by the skill body via `cmd-execute.sh`). The skill body itself drives the Claude-side work (PLAN, RED, refactor decisions) — the script handles the mechanical glue.

## Examples

**Run all enrolled repos once:**
```
/issue-loop
```
Reads `~/.claude/issue-loop.config.json`, iterates each repo where `enabled: true`, exits when all queues are drained or a stop condition fires.

**Watch a single repo:**
```
/issue-loop --repo signportal --watch
```
Polls `gh issue list` for `signportal` every 10 min (configurable). New issues with `ready` label and no `wip`/`blocked` labels are picked up.

**One issue only (manual override):**
```
/issue-loop --repo signportal --issue 142
```
Skips queue, runs the full pipeline on issue 142, opens PR, exits.
