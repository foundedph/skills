# Progress Detector

Decides whether a failed Codex GREEN attempt is **progressing** (extend retry budget) or **stuck** (bail immediately).

## Inputs per iteration

After each Codex attempt, capture:

```json
{
  "attempt": 2,
  "exit_code": 1,
  "test_output": "<full stderr+stdout from test command>",
  "diff": "<git diff HEAD~1>",
  "failing_count": 3,
  "first_error_type": "AssertionError" | "SyntaxError" | "ReferenceError" | "TypeError" | "TimeoutError" | "...",
  "first_error_line": 87,
  "diff_files": ["src/foo.ts", "src/bar.ts"],
  "diff_hash": "<sha256 of normalized diff>"
}
```

## Progress signals (any one = progressing)

A new iteration counts as progress if **at least one** of these is true vs the previous iteration:

1. **Failing count drops**: `curr.failing_count < prev.failing_count`
2. **Error type advances**: rank the error class — compile/syntax errors are earlier (worse) than runtime errors, runtime errors earlier than assertion errors. An advance means execution got further.
   - Rank: `SyntaxError`, `ReferenceError` (1, worst) < `TypeError`, `ImportError` (2) < `RuntimeError`, `TimeoutError` (3) < `AssertionError` (4, best — closest to passing)
   - Progress: `curr.rank > prev.rank`
3. **Error line moves forward**: `curr.first_error_line > prev.first_error_line` AND same error type (means execution reached further into the test)
4. **Non-redundant diff**: `curr.diff_hash != prev.diff_hash` AND diff is non-empty (Codex actually changed something new)

## Stuck signals (any one = immediate bail, ignore remaining budget)

These short-circuit the retry budget entirely:

1. **Identical diff + identical error**: `curr.diff_hash == prev.diff_hash` AND `curr.test_output ~= prev.test_output` (Codex is in a tight loop)
2. **Empty diff**: `curr.diff` is empty (Codex made no changes — gave up)
3. **Test file modified**: any path in `curr.diff_files` matches the test path or starts with `tests/` (contract violation)
4. **Three iterations with no progress**: even if no individual iteration tripped a stuck signal, three consecutive non-progressing iterations = bail
5. **New test files outside the protected set were modified more than 5x in one iteration** (Codex went on a rampage)

## Retry budget logic

```
budget = INITIAL  # 3 from config
attempt = 0
progress_history = []  # last N booleans

while attempt < budget:
  attempt += 1
  result = run_codex()

  if result.passed:
    return SUCCESS

  signals = check_stuck_signals(result, prev=last_result)
  if signals.stuck:
    return BAIL(reason=signals.reason)

  progressing = check_progress_signals(result, prev=last_result)
  progress_history.append(progressing)

  # Extend the budget if we're consistently making progress
  if budget == INITIAL and recent(progress_history, 3, count_true=2):
    budget = EXTENDED  # 5
  if budget == EXTENDED and recent(progress_history, 5, count_true=4):
    budget = HARD_CAP  # 10

  last_result = result

return BAIL(reason="budget_exhausted")
```

The thresholds are deliberate:

- **3-of-5 to extend to extended**: avoids extending on noise
- **4-of-5 to extend to hard cap**: requires sustained progress, not flailing

## Diff normalization (for `diff_hash`)

To compare diffs, normalize first:

1. Strip trailing whitespace from every line
2. Strip blank lines at start/end of hunks
3. Sort hunks by `@@ -A,B +C,D @@` header (so reordered changes hash the same)
4. Hash with sha256

This avoids false "non-redundant" calls when Codex shuffles the same edits.

## Test output similarity (for stuck check)

Two outputs are "essentially the same" if:

- Strip line numbers (`:42:` → `:N:`) — Codex may have shifted line counts trivially
- Strip absolute paths
- Strip timestamps and durations
- Compare normalized strings; treat as equal if Levenshtein distance is < 5% of total length

This catches "same error, slightly different format" without being fooled by cosmetic diffs.

## Implementation

The implementation is at `scripts/progress-detector.sh` in this skill directory. It accepts two JSON files (previous + current iteration data) and exits:

- `0` — progressing (continue, possibly extend)
- `1` — not progressing but not stuck (continue if budget allows)
- `2` — stuck (bail immediately)

Each exit also writes to stdout the reason (one line) for the run log.
