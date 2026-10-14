---
name: implement-spec
description: "Implement the result of /to-spec and /to-tickets in code."
disable-model-invocation: true
---

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.

The goal is the entire spec implemented on a single **integration branch**, with every ticket resolved the way the issue tracker closes work.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

Communication to and from subagents should be sparse. Communicate primarily through **context pointers**: to the spec, tickets, research notes, and previous commits. Don't duplicate information already available via pointers.

**Implementer subagents** should be run in the background where possible for maximum concurrency.

## Routing

<!-- LOCAL DELTA (foundedph, 2026-10-08, tightened 2026-10-14): code-writing goes
     to Command Code via /cmd-handoff, Claude only orchestrates, writes tests and
     reviews once. Preserve this section across upstream re-syncs. -->

Claude tokens go to judgment only: test authorship, orchestration, and **one** review. Everything that writes production code goes to Command Code (`deepseek/deepseek-v4-flash`) through `/cmd-handoff`.

| Role | Runs on |
|---|---|
| Orchestrator (this session) | Sonnet. If the session is on Opus, say so once and suggest switching; orchestration needs no Opus. |
| Exploration subagent | Agent tool with `model: "haiku"` (`"sonnet"` if the exploration needs judgment). Never let it inherit the session model. |
| Implementer subagents | Agent tool with `model: "sonnet"`. They write RED tests; GREEN goes to `/cmd-handoff --no-review`. |
| Merging into the integration branch | The orchestrator, with Bash. No merger subagent. |
| Review | One Sonnet subagent running `/code-review` on the whole integration branch, at the end. Never per seam, never handed off. |
| Review fixes | Command Code, via a `/cmd-handoff` fix task. Sonnet only re-checks. |

- Run implementers across the frontier **in parallel, in the background**. Command Code sessions are keyed by task slug, so concurrent handoffs don't collide.
- If `commandcode status` is not authenticated, ask the user to run `commandcode login`; until then implementers build GREEN inline. If a handoff fails after its 3 rounds, the implementer finishes that seam inline.

## Steps

1. Read the spec and tickets to understand the task graph.

2. (optional) Use an **exploration subagent** (`model: "haiku"`) to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Create the integration branch. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.

4. Use **implementer subagents** (`model: "sonnet"`) to implement each ticket, each in its own worktree on its own branch. Each implementer subagent:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - calls the Skill tool with `tdd` to build the ticket, writing each RED test itself and handing each GREEN step to Command Code by calling the Skill tool with `cmd-handoff` and the args `<ticket-number>-<seam> --no-review` (the unique slug means parallel subagents never share a `tasks/TASK-*.md` file; `--no-review` skips the per-seam `/code-review` and inline refactor, since step 7 reviews the whole branch once);
   - accepts a seam only when the spec's tests and typecheck pass, which it runs itself;
   - merges the integration branch tip into its own branch before reporting done, and reports in at most five lines: branch, tickets closed, test status.

5. Once an **implementer subagent** completes, merge its branch into the integration branch yourself with Bash (`git merge --no-ff`), then run the typecheck. Only on a conflict you can't resolve mechanically, spawn a Sonnet subagent to resolve it.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets. This allows for maximum concurrency.

7. Once all tickets are complete, review and fix:
   1. Spawn one **review subagent** with `model: "sonnet"` that calls the Skill tool with `code-review` on the integration branch (fixed point: the merge-base with main). This is the only `/code-review` run in the whole skill.
   2. If it has real findings, write them as acceptance criteria into `tasks/TASK-<spec>-review.md` (goal, findings by axis with `file:line`, allowed files, test and typecheck commands, an empty `## Executor results`), commit it, and run `bash <cmd-handoff-dir>/scripts/cmd-execute.sh <spec>-review`.
   3. Commit the executor's changes and run the tests and typecheck yourself. If findings remain, append them under `## Review round <n>` and re-run without `--fresh` so the session resumes. Cap at 3 rounds; after that, fix what's left with one Sonnet implementer subagent and say so.
   4. Re-review only the files the fixes touched, not the whole branch.

8. If a draft PR exists, mark it ready for review. Otherwise, resolve each ticket the way the issue tracker closes work, and report the integration branch.

9. Clean up all **implementer subagent** worktrees.
