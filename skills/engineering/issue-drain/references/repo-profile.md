# Repo profile — discovery rules

`issue-drain` is repo-agnostic. It reads this profile at step 0 and prints it before touching anything. Discover first; guess last.

## 1. Look for an explicit profile

`docs/agents/drain.md` — if it exists, it wins outright. Recommended shape:

```markdown
# Drain profile

- **Integration branch:** dev
- **Verification:** npm run check
- **Unit tests:** npm test
- **E2E:** npm run test:e2e          # or: bash tests/e2e/run.sh <file>
- **E2E required when:** a diff touches client/src/** (renders UI), or auth/middleware
- **Merge review:** automation/prompts/review.md
- **Security scan:** node --import tsx automation/scripts/security-scan.ts origin/dev
- **Skip labels:** no-agent, parent, needs-human-review
- **Worktree dir:** .claude/worktrees
```

## 2. Otherwise derive each fact

| Fact | Derivation |
| --- | --- |
| **Tracker** | `docs/agents/issue-tracker.md` (written by `/setup-matt-pocock-skills`). It names the CLI, the list/view/close commands, and — importantly — whether blockers live in the issue **body** or in native dependency links. |
| **Integration branch** | `dev` if `git ls-remote --heads origin dev` is non-empty; else `git symbolic-ref --short refs/remotes/origin/HEAD`. Never the repo's release/production branch. |
| **Verification** | the first that exists in `package.json` scripts: `check`, `typecheck`, `lint` + `test`. Non-Node: the repo's documented equivalent. |
| **E2E** | a script named `test:e2e`, `e2e`, `test:e2e:file`; else `playwright`/`cypress` config. If none, the browser gate is `skip` for every PR. |
| **Merge review** | a control-plane review contract if one exists (e.g. `automation/prompts/review.md`); else `CONTRIBUTING.md` / `CODING_STANDARDS.md` + the gate in SKILL.md 4F. |
| **Security scan** | a `security-scan` script or `automation/security-check.ts`; else omit. |
| **Skip labels** | `docs/LABELS.md` or `docs/agents/triage-labels.md` if present; else the canonical set: `no-agent`, `needs-human`, `human-in-the-loop`, `needs-human-review`, `parent`, plus any in-flight claim label. |
| **Worktree dir** | a gitignored directory inside the repo — check `.gitignore` for an existing one (`.claude/worktrees`, `.worktrees`, `.wt-*`), else create one and add it to `.gitignore`. |

## 3. Hard rules

- **Blockers are usually body-driven, not label-driven.** A `blocked` label frequently does nothing. Read the tracker doc for the actual predicate before filtering.
- **Opt-out, not opt-in.** Many drains work every unblocked issue unless a skip label excludes it; a `ready-for-agent` / `ready` label is often ignored. Don't invent a gate the repo doesn't have.
- **Acceptance criteria must be in the issue body**, not a comment, if the repo's drain builds its prompt from the body (the common case). An issue whose spec lives in a comment will thrash.
- **Ask once, then record.** Any fact that cannot be derived goes to the user in one batched question; the answer is written into `docs/agents/drain.md` so the next run is silent. Do not re-derive per issue.
- **A wrong base branch is the most expensive guess** — merging into the wrong branch is not reversible with a revert. If it is ambiguous, ask.

## 4. Model overrides

Defaults live in `SKILL.md` (§ Model policy): implement on a fast model under the TDD gate, review on a hardened one. Override per run with `--implement-model <id>` / `--review-model <id>`, or set `implement-model:` / `review-model:` in the drain profile. Model ids must be ones the harness actually lists (`cmd --list-models`) — never invent an id.
