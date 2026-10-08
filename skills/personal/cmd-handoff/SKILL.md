---
name: cmd-handoff
description: Implement a spec or tickets with the GREEN step handed off to the Command Code CLI on DeepSeek V4 Flash, reviewed by /code-review.
argument-hint: "<task-slug> [--bg] [--fresh]"
disable-model-invocation: false
---

Implement the work described by the user in the spec or tickets, the same way `/implement` does, except the GREEN step runs headless in the **Command Code** CLI (`commandcode`) on `deepseek/deepseek-v4-flash` instead of in this session or Pi. Each round is checked with `/code-review`.

The first word of the arguments is the task slug (kebab-case). `--bg` runs the executor in the background; `--fresh` drops the saved Command Code session.

## When to use

This is the default GREEN path for `/implement` and `/implement-spec`, at every budget tier. Those skills call it once per seam, often from parallel subagents, each with its own task slug.

Keep it inline anyway for judgement work: unknown-cause debugging, design trade-offs, or a spec that is still moving. If the work is like that, stop and say so.

## Preflight

```bash
commandcode status        # must say "Authentication verified"; else ask the user to run `commandcode login`
```

The repo needs `tasks/` (with `tasks/TEMPLATE.md` if the project has one) and ideally an `AGENTS.md`, which Command Code reads as its executor workflow.

Record the fixed point for review before anything changes: `BASE=$(git rev-parse HEAD)`.

## 1. RED — always inline

Write the failing tests yourself via `/tdd`. Test authorship encodes intent and is never handed off. Only skip tests when there is truly nothing to assert (config, docs, trivial rename).

## 2. Write the task spec

Write `tasks/TASK-<slug>.md` (use the `handoff-writer` subagent if it exists, otherwise write it yourself from `tasks/TEMPLATE.md`). It must stand alone, without this conversation:

- goal and the failing test(s) to make pass, by path
- acceptance criteria as a checklist
- files allowed to change, and a denylist
- the test and typecheck commands
- an empty `## Executor results` section at the bottom

Keep one seam per handoff. Commit the tests and spec so the executor's diff is isolated.

## 3. GREEN — hand off to Command Code

Run the wrapper from this skill's directory:

```bash
bash <this-skill-dir>/scripts/cmd-execute.sh [--bg] [--fresh] <slug>
```

It runs `commandcode -p -m deepseek/deepseek-v4-flash --output-format json --yolo` with the prompt on stdin, logs NDJSON to `tasks/.logs/TASK-<slug>.jsonl`, and saves the session ID to `tasks/.logs/TASK-<slug>.session` so later rounds resume it instead of re-reading the spec. Override with `--model <id>`, `--timeout <s>` (default 600), `--max-turns <n>` (default 100), or `CMD_MODEL=`.

| Exit | Meaning | Action |
|---|---|---|
| 0 | done, results filled | continue |
| 1 | setup failure | print the error, stop |
| 2 | timeout | point at the log, stop |
| 3 | results section empty | say so, continue to review anyway |
| 4 | commandcode errored | show `tail -30` of the log; continue only if the diff shows progress |
| 5 | no success event or turn cap hit | point at the log, stop |

With `--bg`, it returns immediately. Tell the user to check `cmd-execute.sh status <slug>` and re-run `/cmd-handoff <slug>` when it's done, then stop.

## 4. Review with /code-review

Commit the executor's changes to the current branch (it's told not to commit). Then run `/code-review` on Sonnet (a subagent with `model: "sonnet"` that calls the Skill tool with "code-review") with fixed point `$BASE` and `tasks/TASK-<slug>.md` as the spec. It reports **Standards** and **Spec** separately. Do not merge or rerank the two.

Also run the spec's test and typecheck commands yourself. Don't trust the executor's results section.

## 5. Loop, capped at 3 rounds

If either axis has real findings or tests fail, append them under a `## Review round <n>` heading in the task file and re-run step 3 **without** `--fresh`. The saved session resumes, and the prompt tells it to address each finding.

Stop after round 3. Report the diff, the last review, and hand back to the user. Never loop silently. If Command Code keeps failing, finish the work inline.

## 6. REFACTOR and close out — inline

Once green and clean, tidy it yourself. Run the full test suite once, then commit.

Print:

```
/cmd-handoff <slug> — <✅|⚠️|❌> <one sentence>
  Task:     tasks/TASK-<slug>.md
  Executor: commandcode (<model>), <n> round(s)
  Log:      tasks/.logs/TASK-<slug>.jsonl
  Review:   Standards <n> findings · Spec <n> findings
```

## Don't

- Hand off tests, debugging, or design calls.
- Override the wrapper's exit codes or report success it didn't reach.
- Pass `--fresh` on rounds 2–3 unless asked. Session reuse is the cost saving.
- Edit the executor's code to hide a failing review. Feed it back as a round, or take over openly.
