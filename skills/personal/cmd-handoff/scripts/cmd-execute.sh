#!/usr/bin/env bash
# cmd-execute — run a tasks/TASK-<slug>.md spec headless through the Command Code CLI.
# Same task-file + exit-code contract as pi-execute / opencode-execute.
#
# Usage:
#   cmd-execute.sh [--bg] [--fresh] [--timeout N] [--model ID] [--max-turns N] <slug>
#   cmd-execute.sh --review [--base REF] [--model ID] <slug>
#   cmd-execute.sh status <slug>
#
# --review is read-only (`--permission-mode plan`, never --yolo): it reviews
# `git diff <base>...HEAD` against tasks/TASK-<slug>.md on the Standards and Spec
# axes and writes ranked findings to tasks/.logs/TASK-<slug>.review.md. Default
# model deepseek/deepseek-v4.1-flash; default base = merge-base with origin/HEAD.
# It does NOT replace running the tests and typecheck yourself: in benchmarks the
# reviewer missed compile errors that tsc catches in seconds.
#
# Exit codes:
#   0 success, results section populated
#   1 setup failure
#   2 timeout
#   3 finished but results section not populated
#   4 commandcode exited non-zero
#   5 hard error event / turn cap hit
#
# Herdr: when run from a Herdr-managed pane (HERDR_ENV=1, never Claude Desktop),
# sync and --review runs re-launch themselves in a pane of a "handoffs" tab so
# the user can watch, wait for it, and exit with the child's code. At most
# CMD_PANE_CAP (default 4) handoff panes are open at once; extra runs queue.
# The pane closes on exit 0 and stays open on failure. --no-pane or
# CMD_NO_PANE=1 runs inline as before.
set -euo pipefail
ORIG_ARGS=("$@")
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

MODEL="${CMD_MODEL:-deepseek/deepseek-v4-flash}"
TIMEOUT="${CMD_EXECUTE_TIMEOUT:-}"
MAX_TURNS="${CMD_MAX_TURNS:-100}"
MODE=sync
FRESH=0
REVIEW=0
BASE=""
REVIEW_MODEL="${CMD_REVIEW_MODEL:-deepseek/deepseek-v4.1-flash}"
MODEL_SET=0
SLUG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bg) MODE=bg ;;
    --sync) MODE=sync ;;
    --fresh) FRESH=1 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    --model) MODEL="$2"; MODEL_SET=1; shift ;;
    --review) REVIEW=1 ;;
    --base) BASE="$2"; shift ;;
    --max-turns) MAX_TURNS="$2"; shift ;;
    --no-pane) CMD_NO_PANE=1 ;;
    status) MODE=status ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) SLUG="$1" ;;
  esac
  shift
done

[ -n "$SLUG" ] || { echo "usage: cmd-execute.sh [flags] <slug>" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }
cd "$ROOT"
TASK_FILE="tasks/TASK-${SLUG}.md"
LOG_DIR="tasks/.logs"
LOG_FILE="$LOG_DIR/TASK-${SLUG}.jsonl"
SESSION_FILE="$LOG_DIR/TASK-${SLUG}.session"
STATUS_FILE="$LOG_DIR/TASK-${SLUG}.status"
PID_FILE="$LOG_DIR/TASK-${SLUG}.pid"
mkdir -p "$LOG_DIR"

write_status() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" > "$STATUS_FILE"; }

if [ "$MODE" = status ]; then
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "RUNNING (pid $(cat "$PID_FILE"))"
  fi
  cat "$STATUS_FILE" 2>/dev/null || echo "no status for $SLUG"
  exit 0
fi

command -v commandcode >/dev/null || { echo "commandcode CLI not installed (npm i -g command-code)" >&2; exit 1; }
[ "$REVIEW" = 1 ] || [ -f "$TASK_FILE" ] || { echo "missing $TASK_FILE — run the handoff-writer first" >&2; exit 1; }
commandcode status 2>&1 | grep -q "Authentication verified" || { echo "commandcode not authenticated — run: commandcode login" >&2; exit 1; }

# Reviews ran 6-12 min in benchmarks; implementation rounds default to 10.
[ -n "$TIMEOUT" ] || { [ "$REVIEW" = 1 ] && TIMEOUT=1200 || TIMEOUT=600; }

# Only inside a live Herdr pane, never Claude Desktop, never recursively.
in_herdr() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 1
  [ "${CMD_IN_PANE:-}" != 1 ] && [ "${CMD_NO_PANE:-}" != 1 ] || return 1
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in *desktop*) return 1 ;; esac
  command -v herdr >/dev/null && command -v jq >/dev/null || return 1
  herdr pane current --current >/dev/null 2>&1
}

# Prints the pane ID for this handoff, or fails (caller then runs inline).
claim_handoff_pane() {
  local cap="${CMD_PANE_CAP:-4}" lock="${TMPDIR:-/tmp}/cmd-execute-herdr.lock"
  local tab count pane last dir waited=0
  while :; do
    # mkdir is atomic; break a lock left by a killed run after 60s.
    until mkdir "$lock" 2>/dev/null; do
      [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
      sleep 1
    done
    tab="$(herdr tab list --workspace "$HERDR_WORKSPACE_ID" | jq -r '[.result.tabs[] | select(.label=="handoffs")][0].tab_id // empty')" \
      || { rmdir "$lock"; return 1; }
    if [ -z "$tab" ]; then
      pane="$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$ROOT" --label handoffs | jq -r '.result.root_pane.pane_id // empty')"
      rmdir "$lock"; [ -n "$pane" ] && echo "$pane"; [ -n "$pane" ]; return
    fi
    count="$(herdr pane list --workspace "$HERDR_WORKSPACE_ID" | jq --arg t "$tab" '[.result.panes[] | select(.tab_id==$t)] | length')" \
      || { rmdir "$lock"; return 1; }
    if [ "$count" -lt "$cap" ]; then
      last="$(herdr pane list --workspace "$HERDR_WORKSPACE_ID" | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id==$t)][-1].pane_id')"
      [ "$count" = 1 ] && dir=right || dir=down
      pane="$(herdr pane split "$last" --direction "$dir" --cwd "$ROOT" --no-focus | jq -r '.result.pane.pane_id // empty')"
      rmdir "$lock"; [ -n "$pane" ] && echo "$pane"; [ -n "$pane" ]; return
    fi
    rmdir "$lock"
    [ "$waited" = 0 ] && echo "$cap handoff panes busy; '$SLUG' queued" >&2
    waited=1; sleep 5
  done
}

if [ "$MODE" = sync ] && in_herdr; then
  if PANE="$(claim_handoff_pane)"; then
    EXIT_FILE="$ROOT/$LOG_DIR/TASK-${SLUG}.exit"
    LAUNCHER="$ROOT/$LOG_DIR/TASK-${SLUG}.pane.sh"
    rm -f "$EXIT_FILE"
    # A launcher file carries the caller's env and dodges the tty line-length limit.
    {
      echo "cd $(printf %q "$ROOT")"
      for v in PATH CMD_MODEL CMD_REVIEW_MODEL CMD_EXECUTE_TIMEOUT CMD_MAX_TURNS; do
        [ -n "${!v:-}" ] && echo "export $v=$(printf %q "${!v}")"
      done
      printf 'CMD_IN_PANE=1 bash %q' "$SELF"; printf ' %q' "${ORIG_ARGS[@]}"; echo
      echo "echo \$? > $(printf %q "$EXIT_FILE")"
    } > "$LAUNCHER"
    herdr pane rename "$PANE" "cc-$SLUG" >/dev/null 2>&1 || true
    herdr pane run "$PANE" "bash $(printf %q "$LAUNCHER")" >/dev/null
    echo "Command Code for '$SLUG' running in Herdr pane $PANE"
    deadline=$(( $(date +%s) + TIMEOUT + 300 ))
    until [ -s "$EXIT_FILE" ]; do
      if ! herdr pane get "$PANE" >/dev/null 2>&1; then
        echo "Herdr pane $PANE closed before '$SLUG' finished; see $STATUS_FILE" >&2; exit 1
      fi
      [ "$(date +%s)" -lt "$deadline" ] || { echo "no exit code from pane $PANE after $((TIMEOUT + 300))s" >&2; exit 2; }
      sleep 3
    done
    code="$(cat "$EXIT_FILE")"; rm -f "$EXIT_FILE" "$LAUNCHER"
    cat "$STATUS_FILE" 2>/dev/null || true
    if [ "$code" = 0 ]; then
      herdr pane close "$PANE" >/dev/null 2>&1 || true
    else
      echo "Handoff '$SLUG' exited $code; pane $PANE left open for inspection" >&2
    fi
    exit "$code"
  fi
  echo "Herdr pane setup failed; running '$SLUG' inline" >&2
fi

if [ "$REVIEW" = 1 ]; then
  [ "$MODEL_SET" = 1 ] || MODEL="$REVIEW_MODEL"
  SPEC_NOTE="The spec is $TASK_FILE."
  [ -f "$TASK_FILE" ] || SPEC_NOTE="There is no spec file; on the Spec axis, check the diff against its own commit messages and say no spec was available."
  if [ -z "$BASE" ]; then
    BASE="$(git merge-base HEAD "$(git symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/main)")" \
      || { echo "cannot resolve a review base; pass --base <ref>" >&2; exit 1; }
  fi
  git rev-parse -q --verify "$BASE^{commit}" >/dev/null || { echo "bad --base: $BASE" >&2; exit 1; }
  DIFF_FILE="$LOG_DIR/TASK-${SLUG}.review.diff"
  OUT_FILE="$LOG_DIR/TASK-${SLUG}.review.md"
  git diff "$BASE"...HEAD > "$DIFF_FILE"
  [ -s "$DIFF_FILE" ] || { echo "empty diff $BASE...HEAD — commit the work first" >&2; exit 1; }
  PROMPT="You are a read-only code reviewer. Do not edit any file. $DIFF_FILE is the diff $BASE...HEAD; the working tree is the post-change state. $SPEC_NOTE Read CLAUDE.md, AGENTS.md, CONSTRAINTS.md and CONTRIBUTING.md if present.
Report two axes separately, under '## Standards' and '## Spec'; never merge or rerank them.
STANDARDS: documented repo rules (cite file + rule); will it compile under this repo's tsconfig (check target/lib/flags against the syntax used); tests that cannot run, are not registered, or assert nothing; wrong assumptions about CLI/tool output formats (verify by reading how the tool is used elsewhere); Fowler smells as judgement calls.
SPEC: requirements missing or partial; behaviour not asked for; implementations that look wrong. Quote the spec line.
Verify every claim against the actual files. Each finding: severity (blocker/major/minor), file:line, one-sentence defect, concrete failure scenario. Be terse. If an axis is clean, say so."
  write_status "REVIEWING (model $MODEL, base $BASE)"
  rm -f "$LOG_DIR/TASK-${SLUG}.timedout"
  commandcode -p -m "$MODEL" --max-turns "$MAX_TURNS" --permission-mode plan -t \
    --no-session --skip-onboarding --no-auto-update <<<"$PROMPT" > "$OUT_FILE" 2>&1 &
  CC_PID=$!
  ( sleep "$TIMEOUT"; kill -TERM "$CC_PID" 2>/dev/null && touch "$LOG_DIR/TASK-${SLUG}.timedout" ) >/dev/null 2>&1 &
  WATCHDOG=$!
  exit_code=0
  wait "$CC_PID" || exit_code=$?
  kill "$WATCHDOG" 2>/dev/null || true
  if [ -f "$LOG_DIR/TASK-${SLUG}.timedout" ]; then
    rm -f "$LOG_DIR/TASK-${SLUG}.timedout"; write_status "REVIEW TIMEOUT after ${TIMEOUT}s"; exit 2
  fi
  [ "$exit_code" = 8 ] && { write_status "REVIEW TURN CAP hit"; exit 5; }
  [ "$exit_code" = 0 ] || { write_status "REVIEW ERROR (exit $exit_code)"; echo "see $OUT_FILE" >&2; exit 4; }
  grep -q '^## Standards' "$OUT_FILE" || { write_status "REVIEW finished without findings headings"; exit 3; }
  write_status "REVIEW DONE (model $MODEL) — $OUT_FILE"
  echo "✓ Review of $BASE...HEAD written to $OUT_FILE"
  exit 0
fi

if [ "$MODE" = bg ]; then
  args=(--sync --timeout "$TIMEOUT" --model "$MODEL" --max-turns "$MAX_TURNS")
  [ "$FRESH" = 1 ] && args+=(--fresh)
  nohup "$0" "${args[@]}" "$SLUG" >/dev/null 2>&1 &
  echo $! > "$PID_FILE"
  write_status "RUNNING in background (pid $!, model $MODEL)"
  echo "Started Command Code for '$SLUG' in background (pid $!). Check: $0 status $SLUG"
  exit 0
fi

results_populated() {
  awk '
    /^## (Executor|Pi) results/ { in_section=1; next }
    /^## / && in_section { exit !found }
    in_section && NF > 0 {
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^\*\(.*\)\*$/) next
      if (line == "---") next
      if (line ~ /^- \*\*[A-Za-z][^:]*:\*\*[[:space:]]*$/) next
      found=1; exit
    }
    END { exit !found }
  ' "$TASK_FILE"
}

cmd=(commandcode -p -m "$MODEL" --output-format json --max-turns "$MAX_TURNS"
     -t --yolo --skip-onboarding --no-auto-update)

if [ "$FRESH" = 0 ] && [ -s "$SESSION_FILE" ]; then
  cmd+=(--session "$(cat "$SESSION_FILE")")
  PROMPT="Continue executing the task in $TASK_FILE from where you left off. If a reviewer round returned NEEDS_WORK, address each finding. Update the 'Executor results' section at the bottom of the task file when done. Do not commit or push."
else
  PROMPT="Execute the task in $TASK_FILE following the executor workflow in AGENTS.md. Fill in the results section at the bottom of the task file (the 'Executor results' or 'Pi results' section, whichever the template uses) when done. Do not commit or push."
fi

write_status "RUNNING (model $MODEL, timeout ${TIMEOUT}s)"
echo "{\"type\":\"cmd-execute\",\"slug\":\"$SLUG\",\"model\":\"$MODEL\",\"started\":\"$(date -u +%FT%TZ)\"}" >> "$LOG_FILE"

rm -f "$LOG_DIR/TASK-${SLUG}.timedout"
# Prompt goes via stdin to dodge argv limits; macOS has no `timeout`, so use a watchdog.
# The watchdog drops stdout so its sleep cannot hold a caller's pipe open.
"${cmd[@]}" <<<"$PROMPT" >> "$LOG_FILE" 2>&1 &
CC_PID=$!
( sleep "$TIMEOUT"; kill -TERM "$CC_PID" 2>/dev/null && touch "$LOG_DIR/TASK-${SLUG}.timedout" ) >/dev/null 2>&1 &
WATCHDOG=$!

exit_code=0
wait "$CC_PID" || exit_code=$?
kill "$WATCHDOG" 2>/dev/null || true
rm -f "$PID_FILE"

session_id="$(grep '"type":"result"' "$LOG_FILE" | tail -1 | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' || true)"
[ -n "$session_id" ] && echo "$session_id" > "$SESSION_FILE"

if [ -f "$LOG_DIR/TASK-${SLUG}.timedout" ]; then
  rm -f "$LOG_DIR/TASK-${SLUG}.timedout"
  write_status "TIMEOUT after ${TIMEOUT}s"
  echo "Command Code exceeded ${TIMEOUT}s — see $LOG_FILE" >&2
  exit 2
fi

if [ "$exit_code" = 8 ]; then
  write_status "TURN CAP hit ($MAX_TURNS turns)"
  echo "Command Code hit the --max-turns cap ($MAX_TURNS) — see $LOG_FILE" >&2
  exit 5
fi

if [ "$exit_code" != 0 ]; then
  write_status "ERROR (exit $exit_code)"
  echo "Command Code exited $exit_code — see $LOG_FILE" >&2
  exit 4
fi

if ! grep '"type":"result"' "$LOG_FILE" | tail -1 | grep -q '"subtype":"success"'; then
  write_status "ERROR — no successful result event"
  echo "Command Code emitted no successful result event — see $LOG_FILE" >&2
  exit 5
fi

if ! results_populated; then
  write_status "finished but results section not populated"
  echo "WARNING: Command Code finished but did not populate the results section in $TASK_FILE" >&2
  exit 3
fi

write_status "DONE — results section populated (model $MODEL)"
echo "✓ Command Code completed task '$SLUG' ($MODEL). Results in $TASK_FILE"
