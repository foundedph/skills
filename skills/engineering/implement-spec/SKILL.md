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

<!-- LOCAL DELTA (foundedph, 2026-10-08): GREEN goes to Command Code via
     /cmd-handoff and review runs on Sonnet, to save tokens. Preserve this section
     across upstream re-syncs. -->

- **Implementer and merger subagents** run on Sonnet (Agent tool, `model: "sonnet"`). Each implementer hands its GREEN steps to Command Code (`deepseek/deepseek-v4-flash`) through `/cmd-handoff`, so the Claude side only writes tests, refactors, and checks results.
- Run implementers across the frontier **in parallel, in the background**. Command Code sessions are keyed by task slug, so concurrent handoffs don't collide.
- If `commandcode status` is not authenticated, ask the user to run `commandcode login`; until then implementers build GREEN inline. If a handoff fails after its 3 rounds, the implementer finishes that seam inline.
- **Review runs on Sonnet**, never handed off.

## Steps

1. Read the spec and tickets to understand the task graph.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Create the integration branch. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.

4. Use **implementer subagents** to implement each ticket, each in its own worktree on its own branch. Each implementer subagent:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - calls the Skill tool with `tdd` to build the ticket, writing each RED test itself and handing each GREEN step to Command Code by calling the Skill tool with `cmd-handoff` (task slug `<ticket-number>-<seam>`, so parallel subagents never share a `tasks/TASK-*.md` file);
   - merges the integration branch tip into its own branch before reporting done

5. Once an **implementer subagent** completes, merge its work to the integration branch with a **merger subagent**.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets. This allows for maximum concurrency.

7. Once all tickets are complete, spawn a **review subagent** with `model: "sonnet"` that calls the Skill tool with `code-review` on the integration branch. Fix all issues raised by the code review in a single **implementer subagent**.

8. If a draft PR exists, mark it ready for review. Otherwise, resolve each ticket the way the issue tracker closes work, and report the integration branch.

9. Clean up all **implementer subagent** worktrees.
