---
name: to-spec
description: Turn the current conversation into a spec and publish it to the project issue tracker — no interview, just synthesis of what you've already discussed.
disable-model-invocation: true
---

This skill takes the current conversation context and codebase understanding and produces a spec (you may know this document as a PRD). Do NOT interview the user — just synthesize what you already know.

The issue tracker and triage label vocabulary should have been provided to you — run `/setup-matt-pocock-skills` if not.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better - the ideal number is one.

Check with the user that these seams match their expectations.

3. Write the spec using the template below, then publish it to the project issue tracker. On an **opt-in** tracker apply the `ready-for-agent` triage label. On an **opt-out** tracker (see the section below) do NOT — a raw spec must not invite the drain; label it off instead.

## Machine-drainable trackers (e.g. GitHub + Sandcastle-style automation)

Some trackers run an autonomous drain (a cheap model attempts every open issue unless labeled off, then escalates on failure). That drain typically parses only two things out of the issue body: a `## Acceptance criteria` section of `- [ ]` checkboxes, and a `## Blocked by` section of bare `- #<number>` references — everything else (Problem Statement, User Stories, Implementation Decisions, …) is context it reads but can't verify mechanically.

A spec published by this skill is a **PRD-shaped umbrella issue**, not a checkbox-bearing tracer bullet — it has no `## Acceptance criteria` section, so an autonomous drain that picks it up has nothing to verify against and will thrash on it. Guard against that:

- **On an opt-out tracker, apply the canonical do-not-touch label directly** (e.g. `no-agent` on SignPortal — check the repo's label docs) so the spec sits inert until it's diced into tickets. Make this the primary guard; don't rely on a title convention alone.
- **Also title the issue `PRD: <short title>`.** On SignPortal the drain auto-adds the `parent` label to `PRD:`-titled issues and skips `parent`, so this is a second layer — but it only takes effect once a drain cycle has run its label-sync, leaving a race window at publish time that the explicit `no-agent` above closes.
- The expected next step is `/to-tickets` on this same spec, which produces the checkbox-bearing children the drain can actually execute. Those children are what carry `## Acceptance criteria`; the spec itself never should.

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
