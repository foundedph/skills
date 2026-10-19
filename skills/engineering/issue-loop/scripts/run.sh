#!/usr/bin/env bash
# run.sh — primitives for the /issue-loop skill.
#
# This script does NOT orchestrate the model handoffs (Claude/Codex/Sonnet).
# That logic lives in the skill body (SKILL.md) which the model follows turn-by-turn.
# This script exposes mechanical primitives: queue resolution, worktree lifecycle,
# run log management, and gh wrappers.
#
# Subcommands:
#   resolve-queue [flags]         — output JSON array of issues to process
#   start-run <repo> <issue>      — begin a run log; prints the run JSON path
#   record-iteration <run-json>   — append a GREEN iteration record (reads stdin)
#   record-behavior <run-json>    — append a completed behavior record (reads stdin)
#   finalize-run <run-json>       — close out a run with status/exit_reason
#   worktree-add <repo-path> <branch> <slug>
#   worktree-remove <repo-path> <slug>
#   notify <event> <message>      — send a Telegram notification if configured
#
# Config: read from ~/.claude/issue-loop.config.json
#         per-repo overrides at <repo-path>/.claude/issue-loop.json

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBAL_CONFIG="${ISSUE_LOOP_CONFIG:-$HOME/.claude/issue-loop.config.json}"
RUNS_DIR="${ISSUE_LOOP_RUNS_DIR:-$HOME/.claude/issue-loop/runs}"

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "issue-loop: missing required tool: $tool" >&2; exit 1; }
  done
}

require jq gh git

load_config() {
  [ -f "$GLOBAL_CONFIG" ] || { echo "issue-loop: config not found at $GLOBAL_CONFIG" >&2; exit 1; }
  jq -c . "$GLOBAL_CONFIG"
}

repo_config() {
  # $1 = repo (owner/name)
  local repo="$1"
  load_config | jq -c --arg r "$repo" '
    (.defaults // {}) as $d
    | (.repos[] | select(.repo == $r)) as $r
    | $d * ($r // {})
  '
}

repo_path() {
  local repo="$1"
  load_config | jq -r --arg r "$repo" '.repos[] | select(.repo == $r) | .path'
}

# ------------- resolve-queue -------------

resolve_queue() {
  local repo="" issue="" issues_csv="" queue_file="" exclude_csv=""
  local milestone="" assignee="" labels=() max=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)       repo="$2"; shift 2 ;;
      --issue)      issue="$2"; shift 2 ;;
      --issues)     issues_csv="$2"; shift 2 ;;
      --queue)      queue_file="$2"; shift 2 ;;
      --exclude)    exclude_csv="$2"; shift 2 ;;
      --label)      labels+=("$2"); shift 2 ;;
      --milestone)  milestone="$2"; shift 2 ;;
      --assignee)   assignee="$2"; shift 2 ;;
      --max)        max="$2"; shift 2 ;;
      *)            echo "resolve-queue: unknown flag $1" >&2; exit 2 ;;
    esac
  done

  [ -n "$repo" ] || { echo "resolve-queue: --repo required" >&2; exit 2; }
  local rpath; rpath=$(repo_path "$repo")
  [ -n "$rpath" ] && [ -d "$rpath" ] || { echo "resolve-queue: repo path not found for $repo" >&2; exit 2; }

  local rcfg; rcfg=$(repo_config "$repo")
  local label_skip; label_skip=$(echo "$rcfg" | jq -r '.label_skip // [] | join(",")')
  local label_filter; label_filter=$(echo "$rcfg" | jq -r '.label_filter // [] | join(",")')
  local priority_labels; priority_labels=$(echo "$rcfg" | jq -r '.priority_labels // []')

  # Source 1: --issue (single)
  if [ -n "$issue" ]; then
    fetch_one "$rpath" "$issue" | jq -s '.'
    return
  fi

  # Source 2: --queue (file) or --issues (csv) — explicit allow-list
  local explicit_list=""
  if [ -n "$queue_file" ]; then
    explicit_list=$(grep -v '^[[:space:]]*$\|^[[:space:]]*#' "$queue_file" | tr '\n' ',' | sed 's/,$//')
  elif [ -n "$issues_csv" ]; then
    explicit_list="$issues_csv"
  fi

  if [ -n "$explicit_list" ]; then
    # Process in given order; only label_skip (not label_filter) applies
    local result="["
    local first=1
    IFS=',' read -ra nums <<< "$explicit_list"
    for n in "${nums[@]}"; do
      n=$(echo "$n" | tr -d '[:space:]')
      [ -z "$n" ] && continue
      if [ -n "$exclude_csv" ] && echo ",$exclude_csv," | grep -q ",$n,"; then continue; fi
      local item; item=$(fetch_one "$rpath" "$n")
      # Apply label_skip
      local skipped=$(echo "$item" | jq --arg s "$label_skip" '
        ($s | split(",") | map(select(. != ""))) as $skip
        | (.labels | map(.name)) as $have
        | any($skip[]; . as $x | $have | index($x))
      ')
      if [ "$skipped" = "true" ]; then continue; fi
      [ $first -eq 0 ] && result="$result,"
      result="$result$item"
      first=0
    done
    result="$result]"
    echo "$result" | apply_max "$max"
    return
  fi

  # Source 3: filtered query (default)
  local args=("--repo" "$repo" "--state" "open" "--json" "number,title,labels,milestone,assignees,body,url")
  if [ -n "$label_filter" ]; then args+=("--label" "$label_filter"); fi
  for l in "${labels[@]}"; do args+=("--label" "$l"); done
  if [ -n "$milestone" ]; then args+=("--milestone" "$milestone"); fi
  if [ -n "$assignee" ]; then args+=("--assignee" "$assignee"); fi

  local raw; raw=$(gh issue list "${args[@]}" --limit 200)
  echo "$raw" | jq -c --arg skip "$label_skip" --arg excl "${exclude_csv:-}" --argjson prio "$priority_labels" '
    ($skip | split(",") | map(select(. != ""))) as $skiparr
    | ($excl | split(",") | map(select(. != "") | tonumber)) as $exarr
    | map(select(
        ((.labels | map(.name)) as $have | (any($skiparr[]; . as $x | $have | index($x))) | not)
        and (.number | IN($exarr[]) | not)
      ))
    | sort_by(
        # priority labels: first match wins (lower index = higher priority)
        ((.labels | map(.name)) as $have
         | first(($prio | to_entries[] | select($have | index(.value)) | .key)) // 999)
        , .number
      )
  ' | apply_max "$max"
}

apply_max() {
  local max="$1"
  if [ -n "$max" ]; then
    jq --arg m "$max" '.[0:($m|tonumber)]'
  else
    cat
  fi
}

fetch_one() {
  local rpath="$1" num="$2"
  (cd "$rpath" && gh issue view "$num" --json number,title,labels,milestone,assignees,body,url)
}

# ------------- run log lifecycle -------------

start_run() {
  local repo="$1" issue="$2"
  local repo_slug; repo_slug=$(echo "$repo" | tr '/' '_')
  local dir="$RUNS_DIR/$repo_slug"
  mkdir -p "$dir"
  local file="$dir/$issue.json"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local run_id="$(date -u +%Y%m%d-%H%M)-issue-$issue"
  local rcfg; rcfg=$(repo_config "$repo")
  local item; item=$(fetch_one "$(repo_path "$repo")" "$issue")

  jq -n \
    --arg run_id "$run_id" \
    --arg repo "$repo" \
    --arg issue "$issue" \
    --arg started_at "$now" \
    --argjson item "$item" \
    --argjson rcfg "$rcfg" \
    '{
      run_id: $run_id,
      repo: $repo,
      issue: ($issue | tonumber),
      issue_title: $item.title,
      issue_url: $item.url,
      status: "running",
      exit_reason: null,
      started_at: $started_at,
      ended_at: null,
      duration_seconds: null,
      worktree_path: null,
      branch: null,
      behaviors: [],
      pr: null,
      config_snapshot: { retry: $rcfg.retry, implementer: $rcfg.execution.implementer }
    }' > "$file"
  echo "$file"
}

record_iteration() {
  local run_json="$1"
  # stdin: JSON object for this iteration (attempt, exit_code, ...)
  local iter; iter=$(cat)
  local tmp; tmp=$(mktemp)
  jq --argjson it "$iter" '
    if (.behaviors | length) == 0 then
      .behaviors += [{ name: "current", green: { progress_log: [$it] } }]
    else
      .behaviors[-1].green.progress_log += [$it]
    end
  ' "$run_json" > "$tmp"
  mv "$tmp" "$run_json"
}

record_behavior() {
  local run_json="$1"
  local behavior; behavior=$(cat)
  local tmp; tmp=$(mktemp)
  jq --argjson b "$behavior" '.behaviors += [$b]' "$run_json" > "$tmp"
  mv "$tmp" "$run_json"
}

finalize_run() {
  local run_json="$1" status="$2" exit_reason="${3:-}" pr_json="${4:-null}"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp; tmp=$(mktemp)
  jq --arg status "$status" \
     --arg reason "$exit_reason" \
     --arg ended "$now" \
     --argjson pr "$pr_json" \
     '
       .status = $status
       | .exit_reason = (if $reason == "" then null else $reason end)
       | .ended_at = $ended
       | .duration_seconds = (
           ($ended | fromdateiso8601) - (.started_at | fromdateiso8601)
         )
       | .pr = $pr
     ' "$run_json" > "$tmp"
  mv "$tmp" "$run_json"
}

# ------------- worktrees -------------

worktree_add() {
  local rpath="$1" branch="$2" slug="$3"
  local rcfg; rcfg=$(repo_config "$(cd "$rpath" && gh repo view --json nameWithOwner -q .nameWithOwner)")
  local base; base=$(echo "$rcfg" | jq -r '.worktree_base // ".claude/worktrees"')
  local wt="$rpath/$base/$slug"
  mkdir -p "$rpath/$base"
  (cd "$rpath" && git worktree add "$wt" -b "$branch" 2>/dev/null) || \
    (cd "$rpath" && git worktree add "$wt" "$branch")
  echo "$wt"
}

worktree_remove() {
  local rpath="$1" slug="$2"
  local rcfg; rcfg=$(repo_config "$(cd "$rpath" && gh repo view --json nameWithOwner -q .nameWithOwner)")
  local base; base=$(echo "$rcfg" | jq -r '.worktree_base // ".claude/worktrees"')
  local wt="$rpath/$base/$slug"
  (cd "$rpath" && git worktree remove "$wt" --force 2>/dev/null) || true
  rm -rf "$wt" 2>/dev/null || true
}

# ------------- notify -------------

notify() {
  local event="$1" message="$2"
  local cfg; cfg=$(load_config)
  local enabled; enabled=$(echo "$cfg" | jq -r --arg e "$event" '(.notifications.on // []) | index($e) != null')
  [ "$enabled" = "true" ] || return 0
  local chat_id; chat_id=$(echo "$cfg" | jq -r '.notifications.telegram_chat_id // ""')
  [ -n "$chat_id" ] || return 0
  echo "[notify:$event] $message"  # The skill body is responsible for invoking Telegram MCP; this stub logs intent.
}

# ------------- dispatch -------------

cmd="${1:-}"; shift || true
case "$cmd" in
  resolve-queue)    resolve_queue "$@" ;;
  start-run)        start_run "$@" ;;
  record-iteration) record_iteration "$@" ;;
  record-behavior)  record_behavior "$@" ;;
  finalize-run)     finalize_run "$@" ;;
  worktree-add)     worktree_add "$@" ;;
  worktree-remove)  worktree_remove "$@" ;;
  notify)           notify "$@" ;;
  *)
    echo "Usage: run.sh <subcommand> [args]" >&2
    echo "  resolve-queue, start-run, record-iteration, record-behavior, finalize-run, worktree-add, worktree-remove, notify" >&2
    exit 2
    ;;
esac
