Quickstart:

```bash
npx skills add mattpocock/skills --skill=issue-drain
```

```bash
npx skills update issue-drain
```

[Source](https://github.com/mattpocock/skills/tree/main/skills/engineering/issue-drain)

## What it does

`issue-drain` runs a whole issue backlog to merged in one supervised loop: for each ready issue it implements the work test-first on its own worktree, reviews it, runs the browser pass, opens a PR, and drives that PR to merged — repeating until the queue is dry or everything left is parked for a human.

It does **not** re-plan the work. The issues are already specced; the drain executes them. Its defining constraint is that it treats the merge lane as **serial**: merges into the integration branch invalidate every other in-flight PR the moment one lands, so implementation and review fan out across parallel sub-agents while the PR-and-merge lane funnels down to one at a time.

## When to reach for it

You invoke this by typing `/issue-drain` — the agent won't reach for it on its own.

Reach for it when the issue tracker has a backlog of ready issues and you want them worked to merged without hand-driving each one. For a single issue, use [implement](https://aihero.dev/skills-implement) directly. For a queue of *pull requests* rather than issues, use [cp-drain](https://aihero.dev/skills-cp-drain) — this skill is the issue-side sibling.

## The two-lane shape

The whole design falls out of one fact: **merges are serialised.** So the drain splits into a fan-out lane and a fan-in lane.

Implementation, unit tests, the verification command, and the two review axes are all worktree-local — they touch neither the integration branch nor each other, so they run **in parallel**, one worktree per issue. Creating a PR, reviewing it, running the browser pass, and merging are all ordered against that branch, so they run **one at a time**. Concurrency therefore defaults to two, not because the harness can't do more, but because at depth *d* a landing PR discards the rebase work of the other *d−1*, and the browser pass is a single-lane resource anyway.

## Model policy and the TDD gate

The implementer and the reviewer run different models on purpose. Implementation is cheap-model work *provided* TDD is strictly followed — so the drain enforces it: the implementer must write the failing test before the code and report the actual failing run, and the orchestrator rejects a handoff with no evidence of red. Review is where a weak model silently passes bad work, so it runs hardened.

## Where it fits

`issue-drain` is the **queue-level** wrapper around the build chain:

```txt
grill-with-docs → to-spec → to-tickets → issue-drain → (merged)
```

Where [implement](https://aihero.dev/skills-implement) builds **one** issue and stops at a commit, `issue-drain` loops that whole pipeline — [implement](https://aihero.dev/skills-implement) → [code-review](https://aihero.dev/skills-code-review) → PR → merge — across a backlog, supervising its own retries, repairs, and parked issues. It needs the tracker configured first by [setup-matt-pocock-skills](https://aihero.dev/skills-setup-matt-pocock-skills), and it discovers everything repo-specific (integration branch, verification command, browser pass, merge criteria) rather than hardcoding it. When you're unsure which skill or flow fits, [ask-matt](https://aihero.dev/skills-ask-matt) routes you.
