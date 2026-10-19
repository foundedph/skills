#!/usr/bin/env bash
# progress-detector.sh — decide whether a Codex GREEN attempt is progressing or stuck.
#
# Usage:
#   progress-detector.sh <prev.json> <curr.json>
#
# Inputs (per-iteration JSON files written by run.sh):
#   {
#     "attempt": 2,
#     "exit_code": 1,
#     "test_output_path": "/path/to/output.txt",
#     "diff_path": "/path/to/diff.patch",
#     "failing_count": 3,
#     "first_error_type": "AssertionError",
#     "first_error_line": 87,
#     "diff_files": ["src/foo.ts"],
#     "diff_hash": "<sha256>"
#   }
#
# Exit codes:
#   0 — progressing (continue, possibly extend budget)
#   1 — not progressing but not stuck (continue if budget allows)
#   2 — stuck (bail immediately, ignore remaining budget)
#
# stdout: one line with the decision reason (for the run log).

set -euo pipefail

PREV="${1:?prev.json required}"
CURR="${2:?curr.json required}"

if ! command -v jq >/dev/null 2>&1; then
  echo "stuck:jq not installed"
  exit 2
fi

# --- Stuck checks (any one trips immediate bail) ---

# 1. Empty diff
curr_diff_empty=$(jq -r '.diff_hash == "" or .diff_hash == null' "$CURR")
if [ "$curr_diff_empty" = "true" ]; then
  echo "stuck:empty_diff"
  exit 2
fi

# 2. Test file modified
test_modified=$(jq -r '[.diff_files[] | select(test("(^|/)(tests?|__tests__|spec)/|\\.(test|spec)\\.|(^|/)test_[^/]*\\.py$|_test\\.(go|py)$"; "i"))] | length' "$CURR")
if [ "$test_modified" -gt 0 ]; then
  echo "stuck:test_file_modified"
  exit 2
fi

# 3. Identical diff hash + identical-ish output (last attempt)
prev_hash=$(jq -r '.diff_hash // ""' "$PREV")
curr_hash=$(jq -r '.diff_hash // ""' "$CURR")
if [ -n "$prev_hash" ] && [ "$prev_hash" = "$curr_hash" ]; then
  prev_out=$(jq -r '.test_output_path // ""' "$PREV")
  curr_out=$(jq -r '.test_output_path // ""' "$CURR")
  if [ -f "$prev_out" ] && [ -f "$curr_out" ]; then
    # Normalize line numbers, paths, durations before comparing
    prev_norm=$(sed -E -e 's/:[0-9]+:[0-9]+/:N:N/g' \
                       -e 's|/[^ ]+/|/X/|g' \
                       -e 's/[0-9]+ms/Xms/g' \
                       -e 's/[0-9]+\.[0-9]+s/X.Xs/g' "$prev_out" | sort -u)
    curr_norm=$(sed -E -e 's/:[0-9]+:[0-9]+/:N:N/g' \
                       -e 's|/[^ ]+/|/X/|g' \
                       -e 's/[0-9]+ms/Xms/g' \
                       -e 's/[0-9]+\.[0-9]+s/X.Xs/g' "$curr_out" | sort -u)
    if [ "$prev_norm" = "$curr_norm" ]; then
      echo "stuck:identical_diff_and_output"
      exit 2
    fi
  fi
fi

# --- Progress signals (any one = progressing) ---

# Rank error types: lower is earlier in execution (worse), higher is closer to passing
rank_error_type() {
  case "$1" in
    SyntaxError|ParseError|ReferenceError|ModuleNotFoundError) echo 1 ;;
    TypeError|ImportError|NameError|AttributeError) echo 2 ;;
    RuntimeError|TimeoutError|NetworkError) echo 3 ;;
    AssertionError|ExpectationFailed) echo 4 ;;
    *) echo 0 ;;  # unknown — neutral
  esac
}

prev_failing=$(jq -r '.failing_count // 0' "$PREV")
curr_failing=$(jq -r '.failing_count // 0' "$CURR")
prev_err=$(jq -r '.first_error_type // ""' "$PREV")
curr_err=$(jq -r '.first_error_type // ""' "$CURR")
prev_line=$(jq -r '.first_error_line // 0' "$PREV")
curr_line=$(jq -r '.first_error_line // 0' "$CURR")
prev_rank=$(rank_error_type "$prev_err")
curr_rank=$(rank_error_type "$curr_err")

# Signal 1: Failing count drops
if [ "$curr_failing" -lt "$prev_failing" ]; then
  echo "progress:failing_count_${prev_failing}_to_${curr_failing}"
  exit 0
fi

# Signal 2: Error type advances (closer to passing)
if [ "$curr_rank" -gt "$prev_rank" ] && [ "$curr_rank" -gt 0 ]; then
  echo "progress:error_advanced_${prev_err}_to_${curr_err}"
  exit 0
fi

# Signal 3: Error line moved forward (same error type)
if [ "$curr_err" = "$prev_err" ] && [ "$curr_line" -gt "$prev_line" ] && [ "$prev_line" -gt 0 ]; then
  echo "progress:line_advanced_${prev_line}_to_${curr_line}"
  exit 0
fi

# Signal 4: Non-redundant diff (Codex actually changed something new)
if [ -n "$prev_hash" ] && [ -n "$curr_hash" ] && [ "$prev_hash" != "$curr_hash" ]; then
  echo "progress:diff_changed"
  exit 0
fi

# No progress signal triggered — neither stuck nor progressing
echo "no_progress:no_signal_triggered"
exit 1
