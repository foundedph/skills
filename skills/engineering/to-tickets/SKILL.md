---
name: to-tickets
description: Break a plan, spec, or the current conversation into a set of tracer-bullet tickets, each declaring its blocking edges, published to the configured tracker — edges as text in one file per ticket locally, or native blocking links on a real tracker.
disable-model-invocation: true
---

# To Tickets

Break a plan, spec, or conversation into a set of **tickets** — tracer-bullet vertical slices, each declaring the tickets that **block** it.

The issue tracker and triage label vocabulary should have been provided to you — run `/setup-matt-pocock-skills` if not.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a reference (a spec path, an issue number or URL) as an argument, fetch it and read its full body and comments.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Ticket titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

Look for opportunities to prefactor the code to make the implementation easier. "Make the change easy, then make the easy change."

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets.

<vertical-slice-rules>

- Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) — vertical, NOT a horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window
- Any prefactoring should be done first

</vertical-slice-rules>

Give each ticket its **blocking edges** — the other tickets that must complete before it can start. A ticket with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A **wide refactor** is one mechanical change — rename a column, retype a shared symbol — whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green. Don't force it into a tracer bullet; sequence it as **expand–contract**. First expand: add the new form beside the old so nothing breaks. Then migrate the call sites over in batches sized by blast radius (per package, per directory), each batch its own ticket blocked by the expand, keeping CI green batch to batch because the old form still exists. Finally contract: delete the old form once no caller remains, in a ticket blocked by every migrate batch. When even the batches can't stay green alone, keep the sequence but let them share an integration branch that all block a final integrate-and-verify ticket — green is promised only there.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: short descriptive name
- **Blocked by**: which other tickets (if any) must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each ticket only depend on tickets that genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown.

### 5. Publish the tickets to the configured tracker

Publish the approved tickets. **How** depends on the tracker `/setup-matt-pocock-skills` configured — the tickets are the same either way, only the shape of the blocking edges changes:

- **Local files** → write one file per ticket under `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` in dependency order (blockers first). Each file's "Blocked by" lists the numbers/titles it depends on. Use the per-ticket file template below — one ticket per file, never a single combined file.
- **A real issue tracker (GitHub, Linear, …)** → publish one issue per ticket in dependency order (blockers first) so each ticket's blocking edges can reference real identifiers. Use the platform's native blocking / sub-issue relationship where it has one; otherwise set each ticket's "Blocked by" to the blocking issues. **Labelling depends on whether the tracker is opt-in or opt-out — see "Environment specifics" below; do not blanket-apply `ready-for-agent`.** The tickets are agent-grabbable by construction either way.

Work the **frontier**: any ticket whose blockers are all done. For a purely linear chain that means top to bottom.

Do NOT close or modify any parent issue.

<local-ticket-template>

# <NN> — <Ticket title>

**What to build:** the end-to-end behaviour this ticket makes work, from the user's perspective — not a layer-by-layer implementation list.

**Blocked by:** `<NN>` (bare ticket number only, one per line) or the literal line "None — can start immediately". Never a prose description of the blocker — automation that parses this field looks for the number, not the sentence.

**Status:** ready-for-agent

- [ ] Acceptance criterion 1
- [ ] Acceptance criterion 2

</local-ticket-template>

<issue-template>

## Parent

`#<number>` (bare issue number, optionally `owner/repo#<number>`) — omit this whole section if the source wasn't an existing issue. Never prose.

## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective — not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- `#<number>` — one bare reference per line, per blocking ticket.

Or, if there are no blockers, replace the whole section body with the single line `None — can start immediately`. Never write a prose blocker ("the migration ticket", "waiting on design") in this section — automation that gates on it only recognizes `#<number>` or the literal "None" line; a prose line reads as an unresolvable manual hold and parks the ticket forever.

</issue-template>

In either form, avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

Work the frontier one ticket at a time with `/implement`, clearing context between tickets.

## Machine-drainable trackers (e.g. GitHub + Sandcastle-style automation)

Some trackers run an autonomous drain — a cheap model attempts every open, unblocked, un-opted-out ticket with no human confirming scope first, then escalates through model tiers on failure. That drain (and its adversarial reviewer) parses **only** two things out of the body: the `## Acceptance criteria` checkbox list, and the `## Blocked by` section — matched by exact heading and the `- [ ]` / `#<number>` syntax in the templates above. Everything else is context it reads but can't verify. Consequences for authoring:

- **Every acceptance criterion is a test the builder must write.** The drain runs a red-green TDD loop and feeds it exactly these criteria — it does not read this skill, `/implement`, or any external plan; the ticket body IS the whole prompt. So each criterion must be a single, binary, **diff-verifiable** behavior a test can assert: "returns 404 for an unknown order id" not "handles errors gracefully." One behavior per checkbox; if a criterion needs the word "and," split it. Name the seam the test sits at in "What to build" (an existing HTTP route, an exported function) so a flash-tier model tests at the right boundary instead of reaching into internals.
- **Size slices smaller than you would for a human or a frontier model.** A fast-tier model (e.g. DeepSeek Flash) has weaker multi-step planning and a shorter effective attention span for sprawling context. A slice a senior engineer calls "one sitting" is often too coarse for it. Err toward splitting further and spelling out the key interface(s) explicitly rather than leaving them to be discovered. If a slice keeps failing on retry (the drain climbs model tiers and still can't land it), re-slice it thinner — don't just let the ladder keep escalating.
- **Screenshots/recordings do NOT gate an autonomous drain — a written test does.** The drain's reviewer is instructed to mark any criterion verifiable only by screenshot, recording, video, manual QA, or file attachment as **N/A** (not counted as unmet), and the headless builder can't produce a screenshot anyway. So a UI ticket whose *only* evidence is "screenshot attached" passes with **zero verified behavior**. For any UI ticket bound for the drain, the enforceable proof is an automated test — on this repo a `tests/e2e/<feature>.test.sh` (the repo already mandates one per browser-facing feature; see CLAUDE.md → Testing). Make that test its own acceptance criterion. Keep the screenshot/recording criterion too — it's for the human PR reviewer — but never let it be the load-bearing one. If the flow must be browser-verified in CI, also add the `e2e-required` label so PR-side E2E runs.

## Environment specifics — opt-out vs opt-in trackers

**Blocking is always body-driven; never rely on a label for it.** The `## Blocked by:` section (heading with or without the colon) plus one bare `- #<number>` per line is the *only* portable, enforced mechanism — it works on every tracker. Some repos also have a `blocked` label, but it may be **inert**: on SignPortal's Sandcastle the `blocked` label does nothing (the drain detects blocking from the body and only ever *removes* the label on success). Encode blockers in the body and don't add a `blocked` label expecting it to gate. A `## Blocked by:` section that is non-empty, doesn't start with "None", and contains no `#N` is read as a *manual human hold* and parks the ticket indefinitely — so it's `#<number>` refs or the literal `None — can start immediately`, nothing in between.

**Whether AFK tickets need a "go" label depends on the tracker's model — check the repo's CLAUDE.md / label docs first:**

- **Opt-in trackers** (the mattpocock default): agents only touch tickets labeled `ready-for-agent` / `ready`. Apply that label to AFK tickets; leave HITL tickets unlabeled until a human clears them.
- **Opt-out trackers** (e.g. SignPortal's Sandcastle): the drain attempts *every* open ticket and **ignores** `ready`/`ready-for-agent` entirely. Do the opposite — add **no** go-label to AFK tickets (they're picked up by default), and to keep the drain off a HITL ticket add the canonical opt-out label (`no-agent`). Never publish a HITL ticket un-labeled on an opt-out tracker or the drain will attempt it.

**HITL vs AFK**: mark each ticket HITL (needs human judgment — an architecture or design decision) or AFK (implementable and mergeable unattended), and prefer AFK. The mark drives which tickets get the opt-out/opt-in label above.

**UX evidence in acceptance criteria**: any ticket that renders or changes user-facing UI carries a "Screenshot of the resulting screen attached" criterion; any multi-step interactive flow (form fill → submit → confirm, drag-and-drop, a modal sequence) also carries "Screen recording of the full flow attached." These are for the human reviewer and are marked N/A by an autonomous drain (see above), so pair every UI ticket with a real automated-test criterion as its enforceable proof. Pure backend/schema/non-visual tickets need none. Flag each ticket's evidence expectation during the quiz step (step 4) so the user sees which tickets carry screenshots vs. recordings vs. tests before publishing.
