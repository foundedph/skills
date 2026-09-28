#!/usr/bin/env bash
# cmd-execute — run a tasks/TASK-<slug>.md spec headless through the Command Code CLI.
# Same task-file + exit-code contract as pi-execute / opencode-execute.
#
# Usage:
#   cmd-execute.sh [--bg] [--fresh] [--timeout N] [--model ID] [--max-turns N] <slug>
#   cmd-execute.sh status <slug>
#
# Exit codes:
#   0 success, results section populated
#   1 setup failure
#   2 timeout
#   3 finished but results section not populated
#   4 commandcode exited non-zero
#   5 hard error event / turn cap hit
set -euo pipefail

MODEL="${CMD_MODEL:-deepseek/deepseek-v4-flash}"
TIMEOUT="${CMD_EXECUTE_TIMEOUT:-600}"
MAX_TURNS="${CMD_MAX_TURNS:-100}"
MODE=sync
FRESH=0
SLUG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bg) MODE=bg ;;
    --sync) MODE=sync ;;
    --fresh) FRESH=1 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --max-turns) MAX_TURNS="$2"; shift ;;
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
[ -f "$TASK_FILE" ] || { echo "missing $TASK_FILE — run the handoff-writer first" >&2; exit 1; }
commandcode status 2>&1 | grep -q "Authentication verified" || { echo "commandcode not authenticated — run: commandcode login" >&2; exit 1; }

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
"${cmd[@]}" <<<"$PROMPT" >> "$LOG_FILE" 2>&1 &
CC_PID=$!
( sleep "$TIMEOUT"; kill -TERM "$CC_PID" 2>/dev/null && touch "$LOG_DIR/TASK-${SLUG}.timedout" ) &
WATCHDOG=$!

exit_code=0
wait "$CC_PID" || exit_code=$?
kill "$WATCHDOG" 2>/dev/null || true
rm -f "$PID_FILE"

session_id="$(grep '"type":"result"' "$LOG_FILE" | tail -1 | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p')"
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
