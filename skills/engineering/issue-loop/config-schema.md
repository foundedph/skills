# Config Schema

Two layers: **global** (which repos are enrolled) and **per-repo** (overrides for that repo).

## Global config

Path: `~/.claude/issue-loop.config.json`

```json
{
  "$schema": "https://example.invalid/issue-loop.schema.json",
  "version": 1,
  "defaults": {
    "label_filter": ["ready"],
    "label_skip": ["wip", "blocked", "needs-design", "do-not-merge"],
    "priority_labels": ["priority:high", "priority:medium", "priority:low"],
    "worktree_base": ".claude/worktrees",
    "branch_prefix": "issue-loop/",
    "pr_base": "dev",
    "execution": {
      "test_writer": "claude",
      "implementer": "codex",
      "refactor_reviewer": "sonnet"
    },
    "retry": {
      "initial": 3,
      "extended": 5,
      "hard_cap": 10
    },
    "watch_interval_minutes": 10
  },
  "repos": [
    {
      "repo": "foundedph/signportal",
      "path": "~/Dev/ERP",
      "enabled": true
    }
  ],
  "notifications": {
    "telegram_chat_id": null,
    "on": ["hard_fail", "needs_human_review", "loop_stop"]
  },
  "logging": {
    "runs_dir": "~/.claude/issue-loop/runs",
    "retention_days": 30
  }
}
```

### Field reference

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `version` | int | 1 | Bump when schema changes |
| `defaults.label_filter` | string[] | `["ready"]` | Issue must have ALL of these labels |
| `defaults.label_skip` | string[] | `["wip", "blocked", ...]` | Issue is skipped if it has ANY of these |
| `defaults.priority_labels` | string[] | high → low | Order = priority; first match wins for sort |
| `defaults.worktree_base` | path | `.claude/worktrees` | Relative to repo root |
| `defaults.branch_prefix` | string | `issue-loop/` | Branch name = `<prefix><issue-num>-<slug>` |
| `defaults.pr_base` | string | `dev` | Branch to PR against |
| `defaults.execution.test_writer` | enum | `claude` | Who writes RED tests (only `claude` supported now) |
| `defaults.execution.implementer` | enum | `codex` | Who runs GREEN (`codex` or `claude`) |
| `defaults.execution.refactor_reviewer` | enum | `sonnet` | Which agent does refactor review |
| `defaults.retry.initial` | int | 3 | Starting retry budget for GREEN |
| `defaults.retry.extended` | int | 5 | Budget after 2-of-3 progress |
| `defaults.retry.hard_cap` | int | 10 | Budget after 4-of-5 progress; never exceeded |
| `defaults.watch_interval_minutes` | int | 10 | `--watch` poll cadence |
| `repos[].repo` | string | required | `<owner>/<name>` for `gh` |
| `repos[].path` | path | required | Local clone path; loop runs `gh` from here |
| `repos[].enabled` | bool | true | Skip if false |
| `notifications.telegram_chat_id` | string\|null | null | If set, posts via `plugin:telegram:telegram` |
| `notifications.on` | string[] | see default | Events that trigger a Telegram message |
| `logging.runs_dir` | path | `~/.claude/issue-loop/runs` | Where JSON run logs go |
| `logging.retention_days` | int | 30 | Logs older than this are auto-deleted |

## Per-repo override

Path: `<repo>/.claude/issue-loop.json`

Same shape as a single entry under `defaults`. Any field present overrides the global default for this repo only.

```json
{
  "label_filter": ["ready", "tracer-bullet"],
  "label_skip": ["wip", "blocked", "needs-design", "e2e-fix-skip"],
  "pr_base": "dev",
  "execution": {
    "implementer": "codex"
  },
  "retry": {
    "initial": 5,
    "extended": 8,
    "hard_cap": 15
  },
  "test_command": "npm run check && npm run test:e2e"
}
```

### Per-repo-only fields

| Field | Notes |
|-------|-------|
| `test_command` | Shell command to run all relevant tests; defaults to `npm test` if unset. The loop greps for "this test passes" against this command's output. |
| `pre_red_hook` | Optional shell script run before Claude writes a test (e.g., `npm install`, `npm run db:push`) |
| `post_pr_hook` | Optional shell script run after PR is opened (e.g., notify a Slack channel) |

## Run log schema

One JSON file per issue execution at `~/.claude/issue-loop/runs/<repo-slug>/<issue>.json`:

```json
{
  "run_id": "20260429-1430-issue-142",
  "repo": "foundedph/signportal",
  "issue": 142,
  "issue_title": "Customers list: sort by last invoice date",
  "issue_url": "https://github.com/foundedph/signportal/issues/142",
  "status": "success",
  "exit_reason": null,
  "started_at": "2026-04-29T14:30:00Z",
  "ended_at": "2026-04-29T14:51:23Z",
  "duration_seconds": 1283,
  "worktree_path": ".claude/worktrees/issue-142-sort-by-last-invoice",
  "branch": "issue-loop/142-sort-by-last-invoice",
  "behaviors": [
    {
      "name": "user can sort customers by last invoice date desc",
      "test_path": "tests/e2e/customers-sort.test.sh",
      "red": {
        "model": "claude",
        "duration_seconds": 87,
        "test_failed_as_expected": true
      },
      "green": {
        "model": "codex",
        "attempts": 4,
        "extended_to": "extended",
        "final_status": "passed",
        "progress_log": [
          { "attempt": 1, "result": "fail", "progressing": true, "reason": "compile error → assertion error" },
          { "attempt": 2, "result": "fail", "progressing": true, "reason": "failing count 3 → 1" },
          { "attempt": 3, "result": "fail", "progressing": false, "reason": "same diff hash" },
          { "attempt": 4, "result": "pass", "progressing": null, "reason": "test passing" }
        ]
      },
      "refactor": {
        "model": "sonnet",
        "verdict": "should_fix",
        "fixes_applied": 0,
        "notes": ["Consider extracting sort comparator to its own function"]
      }
    }
  ],
  "pr": {
    "number": 4456,
    "url": "https://github.com/foundedph/signportal/pull/4456",
    "base": "dev",
    "opened_at": "2026-04-29T14:50:11Z"
  },
  "config_snapshot": {
    "retry": { "initial": 3, "extended": 5, "hard_cap": 10 },
    "implementer": "codex"
  }
}
```

### Status values

| status | meaning |
|--------|---------|
| `success` | PR opened, all behaviors green |
| `hard_fail` | Codex retry budget exhausted; loop stopped |
| `human_review` | Issue had ambiguous criteria or `needs-human-review` label appeared mid-run; loop stopped |
| `loop_stopped` | User Ctrl-C or stop signal |
| `skipped` | Issue matched `label_skip` mid-run (rare) |

### Exit reasons (for non-success)

- `codex_budget_exhausted`
- `codex_stuck_identical_diff`
- `codex_modified_test_file`
- `red_phase_failed_to_produce_failing_test`
- `refactor_broke_green`
- `ambiguous_acceptance_criteria`
- `worktree_dirty`
- `pr_open_failed`
- `user_cancelled`
