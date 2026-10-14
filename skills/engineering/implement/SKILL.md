---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

## TDD first

If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.

Drive the work test-first by calling the Skill tool with "tdd" (red → green) at pre-agreed seams. Default to TDD for every unit of behavior — write the failing test before the implementation. Only skip TDD when there is genuinely nothing to assert (pure config, docs, trivial rename) or the user explicitly opts out. If a seam is hard to test, treat that as a design signal and adjust the seam, not a reason to abandon TDD.

## Route execution: GREEN goes to Command Code

<!-- LOCAL DELTA (foundedph, 2026-10-08, tightened 2026-10-14): upstream implements
     inline. We hand the GREEN step and review fixes to Command Code (DeepSeek V4
     Flash) via /cmd-handoff to save Claude tokens, keep judgment inline, and run
     ONE review on Sonnet at the end. Preserve this section across upstream re-syncs. -->

Split the work by who is best at it:

| Step | Who | How |
|---|---|---|
| **RED**: write the failing test | **You, inline** | Test authorship encodes intent and is never handed off. |
| **GREEN**: make it pass | **Command Code** (`deepseek/deepseek-v4-flash`) | Call the Skill tool with "cmd-handoff" and args `<slug> --no-review`, one seam per task slug. A seam is accepted on its tests + typecheck; there is no per-seam `/code-review`. |
| **Review** (incl. refactoring) | **Sonnet subagent, once** | Refactoring is not part of the red → green loop; it belongs to review. See "Verify and close out". |
| **Review fixes** | **Command Code** | A `<slug>-review` task, resumed round by round. See "Verify and close out". |

Stay inline, without handing off, for judgment rather than typing: diagnosing failures,
unknown-cause bugs, design and seam decisions, or a spec that is still moving.

**Independent seams run in parallel.** When the work splits into seams with no shared
files and no ordering between them, spawn one subagent per seam (Agent tool,
`model: "sonnet"`; always pin a model, since an unpinned subagent inherits the
session's, which may be Opus). Each one writes its RED test, runs
`/cmd-handoff <slug> --no-review` for GREEN, and reports back in at most five lines:
the slug, the diff summary and the test result. Your context
stays small. Seams that touch the same files run one after another.

**Fallbacks:**
- `commandcode status` isn't authenticated → ask the user to run `commandcode login`;
  meanwhile implement inline.
- Command Code fails after `/cmd-handoff`'s 3 rounds → finish that seam inline.
- Budget tier `red` (`~/.local/bin/budget-tier-read`) and Command Code is unavailable →
  `/auto-handoff <slug>` to Pi is the overflow path.

Note: if this repo also runs an autonomous drain over the same tracker
(Sandcastle-style), that drain does not invoke `/implement` and never sees this file;
it builds its own prompt from the ticket body alone. So a ticket's
`## Acceptance criteria` and `## Blocked by` sections must stand on their own.

## Verify and close out

Record the fixed point before the first change: `BASE=$(git rev-parse HEAD)`.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Commit the seams before reviewing: `/code-review` diffs `$BASE...HEAD`, so uncommitted
work is invisible to it.

Then review **once**, on Sonnet: spawn a subagent with the Agent tool and
`model: "sonnet"` whose prompt is to call the Skill tool with "code-review" against
`$BASE`. This is the only `/code-review` in the run.

If it has real findings:

1. Write them into `tasks/TASK-<slug>-review.md` as acceptance criteria (findings by
   axis with `file:line`, allowed files, test and typecheck commands, an empty
   `## Executor results`), commit it, and run the `cmd-handoff` skill's
   `scripts/cmd-execute.sh <slug>-review`.
2. Commit the executor's changes and run the tests and typecheck yourself.
3. Re-review only the files the fixes touched. If findings remain, append them under
   `## Review round <n>` and re-run without `--fresh` so the session resumes. Cap at 3
   rounds; after that, fix what's left inline and say so.

A finding that needs judgment rather than typing (a design call, an unclear spec) is
fixed inline, not handed off.

Commit your work to the current branch.
