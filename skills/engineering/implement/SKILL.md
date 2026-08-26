---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

## TDD first

Drive the work test-first via `/tdd` (red → green → refactor). Default to TDD for every unit of behavior — write the failing test before the implementation. Only skip TDD when there is genuinely nothing to assert (pure config, docs, trivial rename) or the user explicitly opts out. If a seam is hard to test, treat that as a design signal and adjust the seam, not a reason to abandon TDD.

## Route execution by budget tier

<!-- LOCAL DELTA (foundedph, 2026-08-22): upstream mattpocock/skills routes all
     implementation to Pi unconditionally. Claude Max 20x is a flat-rate seat, so
     that spends real DeepInfra money while a paid seat sits idle. Preserve this
     section across upstream re-syncs. -->

**Check the budget tier before deciding who writes the code:**

```bash
~/.local/bin/budget-tier-read
```

It prints `green` | `yellow` | `red`. **If it prints nothing and exits 1, the repo
has not opted into budget routing — stay inline.** Never read "no output" as red.

| Tier | Who writes the GREEN step | Why |
|---|---|---|
| `green` (default) | **You, inline** — Sonnet 5 | Subscription is flat-rate; delegating costs money to save nothing. Do NOT invoke `/auto-handoff`. |
| `yellow` | **You, inline**, conserving | Prefer Sonnet over Opus, delegate wide searches to subagents, don't re-read large files. Still no Pi. |
| `red` | **Pi** via `/auto-handoff <slug>` | Weekly allowance projected to run out; spill to paid DeepInfra purely to protect what's left. |

### The TDD loop

1. **RED (always inline):** Write the failing test yourself. Test authorship encodes
   intent and is never delegated, at any tier.
2. **GREEN (routed per the table above):**
   - *green / yellow* — implement it yourself. This is the normal path.
   - *red* — hand off via `/auto-handoff <slug>`. The task spec must name the failing
     test(s) and acceptance criteria so Pi can make them pass without this
     conversation. Keep specs small (one seam per handoff).
3. **REFACTOR (always inline):** Review and tidy once green.

Regardless of tier, stay inline for anything that is judgment rather than typing:
writing tests, diagnosing failures, design and seam decisions, and review.

**There is no cross-provider fallback.** `pi-execute` routes only to DeepInfra
(`DeepSeek-V4-Flash` / `-V4-Pro`); the OpenAI ladder was removed 2026-08-19. Pi also
has no anthropic provider and no OAuth, so it **cannot** run Claude models — if
DeepInfra is exhausted, the fallback is Claude Code itself, which on a Max seat is
the cheaper destination anyway.

Note: if this repo also runs an autonomous drain over the same tracker
(Sandcastle-style), that drain does not invoke `/implement` and never sees this file;
it builds its own prompt from the ticket body alone. So a ticket's
`## Acceptance criteria` and `## Blocked by` sections must stand on their own.

## Verify and close out

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, use /code-review to review the work.

Commit your work to the current branch.
