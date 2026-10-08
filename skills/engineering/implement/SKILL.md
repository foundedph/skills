---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

## TDD first

If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.

Drive the work test-first by calling the Skill tool with "tdd" (red → green → refactor). Default to TDD for every unit of behavior — write the failing test before the implementation. Only skip TDD when there is genuinely nothing to assert (pure config, docs, trivial rename) or the user explicitly opts out. If a seam is hard to test, treat that as a design signal and adjust the seam, not a reason to abandon TDD.

## Route execution: GREEN goes to Command Code

<!-- LOCAL DELTA (foundedph, 2026-10-08): upstream implements inline. We hand the
     GREEN step to Command Code (DeepSeek V4 Flash) via /cmd-handoff to save
     Claude tokens, keep judgment inline, and run review on Sonnet. Preserve this
     section across upstream re-syncs. -->

Split the work by who is best at it:

| Step | Who | How |
|---|---|---|
| **RED**: write the failing test | **You, inline** | Test authorship encodes intent and is never handed off. |
| **GREEN**: make it pass | **Command Code** (`deepseek/deepseek-v4-flash`) | Call the Skill tool with "cmd-handoff", one seam per task slug. |
| **REFACTOR** | **You, inline** | Tidy once green. |
| **Review** | **Sonnet subagent** | See "Verify and close out". |

Stay inline, without handing off, for judgment rather than typing: diagnosing failures,
unknown-cause bugs, design and seam decisions, or a spec that is still moving.

**Independent seams run in parallel.** When the work splits into seams with no shared
files and no ordering between them, spawn one subagent per seam (Agent tool,
`model: "sonnet"`). Each one writes its RED test, runs `/cmd-handoff <slug>` for GREEN,
and reports back only the slug, the diff summary and the test result. Your context
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

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, run the review on Sonnet: spawn a subagent with the Agent tool and
`model: "sonnet"` whose prompt is to call the Skill tool with "code-review" against the
fixed point you started from. Fix real findings (inline or through another
`/cmd-handoff` round), then re-review.

Commit your work to the current branch.
