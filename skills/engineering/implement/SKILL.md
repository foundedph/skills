---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

Use /tdd where possible, at pre-agreed seams.

Note: if this repo also runs an autonomous drain over the same tracker (Sandcastle-style — a cheap model attempts every open ticket independently of this skill), that drain does not invoke `/implement` and never sees this file; it builds its own prompt from the ticket body alone. So a ticket's `## Acceptance criteria` and `## Blocked by` sections must stand on their own — this skill's guidance is for whoever runs `/implement` by hand, not a substitute for a well-specified ticket.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, use /code-review to review the work.

Commit your work to the current branch.
