#!/usr/bin/env bash
# ralph.sh — control surface for the ralph issue-executor daemon.
#
# This is glue, not orchestration. It:
#   - Adds ralph:ready labels to issues (gh)
#   - Polls ralph's health endpoint (curl)
#   - Posts operator-command comments to active issues (gh)
#
# Subcommands:
#   claim <issue>[,<issue>...]      — label one or more issues ralph:ready
#   queue <file>                    — read issue numbers from file, label each
#   parent <parent-issue>           — discover children, label each
#   status                          — daemon health + active run
#   retry|pause|resume|stop         — operator commands on active issue
#   wake                            — trigger immediate reconcile (if supported)
#
# Env / config:
#   RALPH_HOST           default: localhost
#   RALPH_PORT           default: 8792
#   RALPH_REPO           default: read from ~/.claude/issue-loop.config.json
#   ISSUE_LOOP_CONFIG    default: ~/.claude/issue-loop.config.json

set -euo pipefail

RALPH_HOST="${RALPH_HOST:-localhost}"
RALPH_PORT="${RALPH_PORT:-8792}"
HEALTH_URL="http://${RALPH_HOST}:${RALPH_PORT}/api/health"
RECONCILE_URL="http://${RALPH_HOST}:${RALPH_PORT}/api/reconcile-now"
STATE_URL="http://${RALPH_HOST}:${RALPH_PORT}/api/state"

CONFIG="${ISSUE_LOOP_CONFIG:-$HOME/.claude/issue-loop.config.json}"
DRY_RUN="${DRY_RUN:-0}"

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ralph: missing tool: $tool" >&2; exit 1; }
  done
}
require gh jq curl

# Verify gh is authenticated. Call before any mutating operation.
gh_auth_check() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "ralph: gh is not authenticated. Run 'gh auth login' first." >&2
    exit 2
  fi
}

# Confirm a batch operation when N > threshold. Bypassed by --yes or DRY_RUN.
# Usage: confirm_batch <count> "<description>"
confirm_batch() {
  local count="$1" desc="$2"
  local threshold="${RALPH_CONFIRM_THRESHOLD:-5}"
  if [ "$count" -le "$threshold" ] || [ "$DRY_RUN" = "1" ] || [ "${YES:-0}" = "1" ]; then
    return 0
  fi
  if ! [ -t 0 ]; then
    echo "ralph: refusing to $desc on $count items in non-interactive mode" >&2
    echo "ralph: re-run with --yes, --dry-run first, or fewer items (threshold: $threshold)" >&2
    exit 2
  fi
  echo
  echo "ralph: about to $desc on $count items."
  printf "ralph: continue? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "ralph: cancelled."; exit 0 ;;
  esac
}

resolve_repo() {
  if [ -n "${RALPH_REPO:-}" ]; then
    echo "$RALPH_REPO"; return
  fi
  if [ -f "$CONFIG" ]; then
    local r; r=$(jq -r '.repos[] | select(.enabled == true) | .repo' "$CONFIG" | head -1)
    if [ -n "$r" ]; then echo "$r"; return; fi
  fi
  echo "ralph: cannot determine repo (set RALPH_REPO or enable a repo in $CONFIG)" >&2
  exit 2
}

# ------------- claim -------------

claim() {
  [ "$DRY_RUN" = "1" ] || gh_auth_check
  local repo; repo=$(resolve_repo)
  local nums="${1:?usage: claim <N>[,<N>...]}"
  IFS=',' read -ra arr <<< "$nums"
  # Filter empties for accurate count
  local valid=()
  for n in "${arr[@]}"; do
    n=$(echo "$n" | tr -d '[:space:]')
    [ -n "$n" ] && valid+=("$n")
  done
  confirm_batch "${#valid[@]}" "label as ralph:ready"
  for n in "${valid[@]}"; do
    label_one "$repo" "$n"
  done
  wake_quiet
  [ "${#valid[@]}" -gt 0 ] && watch_for_claim "$repo" "${valid[0]}"
}

label_one() {
  local repo="$1" n="$2"
  local labels; labels=$(gh issue view "$n" --repo "$repo" --json labels -q '[.labels[].name]' 2>/dev/null) || {
    echo "ralph: issue #$n not found in $repo" >&2
    return 1
  }
  # Block if already in a blocking state
  for blocking in "ralph:running" "ralph:done" "ralph:failed" "ralph:external" "needs-human-review"; do
    if echo "$labels" | jq -e --arg b "$blocking" 'index($b) != null' >/dev/null; then
      echo "ralph: issue #$n already has blocking label '$blocking' — skipping"
      return 0
    fi
  done
  # Idempotence: already ready, no-op
  if echo "$labels" | jq -e 'index("ralph:ready") != null' >/dev/null; then
    echo "ralph: #$n already has ralph:ready (no-op)"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "ralph: [DRY-RUN] would label #$n with ralph:ready"
    return 0
  fi
  echo "ralph: labeling #$n with ralph:ready"
  gh issue edit "$n" --repo "$repo" --add-label "ralph:ready" >/dev/null
}

# ------------- queue file -------------

queue() {
  local file="${1:?usage: queue <file>}"
  [ -f "$file" ] || { echo "ralph: file not found: $file" >&2; exit 2; }
  [ "$DRY_RUN" = "1" ] || gh_auth_check
  local repo; repo=$(resolve_repo)
  # Pre-parse for count + first-issue
  local valid=()
  while IFS= read -r line; do
    line=$(echo "$line" | tr -d '[:space:]' | sed 's/^#.*$//')
    [ -z "$line" ] && continue
    valid+=("$line")
  done < "$file"
  [ "${#valid[@]}" -eq 0 ] && { echo "ralph: queue file has no valid issue numbers"; exit 2; }
  confirm_batch "${#valid[@]}" "label as ralph:ready (from $file)"
  for n in "${valid[@]}"; do
    label_one "$repo" "$n" || true
  done
  wake_quiet
  watch_for_claim "$repo" "${valid[0]}"
}

# ------------- parent issue -------------

# Repo role of a GitHub login (admin|maintain|write|triage|read); "none" if unknown.
author_permission() {
  local repo="$1" login="$2"
  [ -n "$login" ] || { echo none; return; }
  gh api "repos/$repo/collaborators/$login/permission" -q '.role_name // .permission' 2>/dev/null || echo none
}

# Anyone can write "## Parent #N" in an issue body, so keep only children that a
# maintainer filed (author has write/maintain/admin) or that are native GitHub
# sub-issues of the parent. Reads issue numbers on stdin, prints the kept ones.
trusted_children() {
  local repo="$1" parent="$2"
  local subs; subs=$(gh api "repos/$repo/issues/$parent/sub_issues" --paginate -q '.[].number' 2>/dev/null || echo "")
  local n login perm
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if printf '%s\n' "$subs" | grep -qx "$n"; then echo "$n"; continue; fi
    login=$(gh issue view "$n" --repo "$repo" --json author -q .author.login 2>/dev/null || echo "")
    [ -n "$login" ] || { echo "ralph: skipping #$n — author lookup failed (fail-closed)" >&2; continue; }
    perm=$(author_permission "$repo" "$login")
    case "$perm" in
      admin|maintain|write) echo "$n" ;;
      *) echo "ralph: skipping #$n — author @${login:-unknown} has '$perm' access and it is not a sub-issue of #$parent" >&2 ;;
    esac
  done
}

parent_children() {
  local parent="${1:?usage: parent <issue>}"
  local repo; repo=$(resolve_repo)
  echo "ralph: discovering children of #$parent..."

  # Strategy 1 (primary): reverse-link search — issues whose body has "## Parent\n#<parent>"
  # This is the most common convention since GitHub doesn't have a queryable parent field
  local matches
  matches=$(gh issue list --repo "$repo" --state open --json number,title,body --limit 200 \
    | jq -r --arg p "$parent" '
        [.[] | select(.body // "" | test("##\\s*Parent\\s*\\n+\\s*#" + $p + "\\b"))]
        | sort_by(
            if (.title | test("\\[[0-9]+/[0-9]+\\]"))
            then (.title | match("\\[([0-9]+)/[0-9]+\\]") | .captures[0].string | tonumber)
            else 999
            end
          )
        | .[].number
      ' || echo "")
  [ -n "$matches" ] && matches=$(echo "$matches" | trusted_children "$repo" "$parent")

  if [ -n "$matches" ]; then
    local count; count=$(echo "$matches" | wc -l | tr -d '[:space:]')
    echo "ralph: found $count trusted children via reverse-link (## Parent → #$parent):"
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      local title; title=$(gh issue view "$n" --repo "$repo" --json title -q .title 2>/dev/null)
      echo "  #$n  $title"
    done <<< "$matches"
    if [ "$DRY_RUN" = "1" ]; then
      echo "ralph: [DRY-RUN] no labels applied. Re-run without --dry-run to claim."
      return 0
    fi
    gh_auth_check
    confirm_batch "$count" "label as ralph:ready"
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      label_one "$repo" "$n" || true
    done <<< "$matches"
    wake_quiet
    local first; first=$(echo "$matches" | head -1)
    watch_for_claim "$repo" "$first"
    return
  fi

  # Strategy 2 (fallback): parent body task list "- [ ] #N"
  local body_refs; body_refs=$(gh issue view "$parent" --repo "$repo" --json body -q .body \
    | grep -oE '^[[:space:]]*-[[:space:]]*\[[ x]\][[:space:]]*#[0-9]+' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -un || echo "")
  [ -n "$body_refs" ] && body_refs=$(echo "$body_refs" | trusted_children "$repo" "$parent")

  if [ -n "$body_refs" ]; then
    echo "ralph: found trusted children via parent body task list:"
    for n in $body_refs; do
      local title; title=$(gh issue view "$n" --repo "$repo" --json title -q .title 2>/dev/null)
      echo "  #$n  $title"
    done
    if [ "$DRY_RUN" = "1" ]; then
      echo "ralph: [DRY-RUN] no labels applied."
      return 0
    fi
    gh_auth_check
    confirm_batch "$(echo "$body_refs" | wc -l | tr -d '[:space:]')" "label as ralph:ready"
    for n in $body_refs; do label_one "$repo" "$n" || true; done
    wake_quiet
    return
  fi

  echo "ralph: no children discovered for #$parent" >&2
  echo "ralph: tried (1) reverse-link '## Parent → #$parent' in child bodies, (2) parent body task list" >&2
  exit 1
}

# ------------- status -------------

status() {
  echo "ralph status"
  echo "============"
  local health; health=$(curl -s --max-time 3 "$HEALTH_URL" 2>/dev/null || echo "")
  if [ -z "$health" ]; then
    echo "  daemon: UNREACHABLE at $HEALTH_URL"
    echo "  hint: check it's running on the Mac Mini (sudo launchctl list | grep ralph)"
    return 1
  fi
  echo "$health" | jq .
  local paused; paused=$(echo "$health" | jq -r '.paused // false')
  [ "$paused" = "true" ] && echo "  ⚠ daemon is PAUSED — run '/loop-tdd resume' to continue"

  echo
  echo "active runs:"
  local state; state=$(curl -s --max-time 3 "$STATE_URL" 2>/dev/null || echo "")
  if [ -n "$state" ] && echo "$state" | jq . >/dev/null 2>&1; then
    echo "$state" | jq .
  else
    echo "  (state endpoint not exposed; falling back to label query)"
  fi

  local repo; repo=$(resolve_repo 2>/dev/null) || { echo "  (no repo configured)"; return 0; }
  echo
  echo "queue for $repo:"
  for label in "ralph:running" "ralph:ready" "ralph:blocked"; do
    local issues; issues=$(gh issue list --repo "$repo" --state open --label "$label" --json number,title --limit 50 2>/dev/null || echo "[]")
    local n; n=$(echo "$issues" | jq 'length')
    echo "  $label: $n"
    if [ "$label" = "ralph:running" ] && [ "$n" -gt 0 ]; then
      echo "$issues" | jq -r '.[] | "    → #\(.number) \(.title)"'
    fi
  done

  echo
  echo "last activity (most recent labeled issues):"
  for label in "ralph:done" "ralph:failed"; do
    local last; last=$(gh issue list --repo "$repo" --state all --label "$label" --json number,title,updatedAt --limit 1 2>/dev/null \
      | jq -r '.[0] | if . then "  \($label // ""): #\(.number) \(.title) (\(.updatedAt))" else "  \($label // ""): (none)" end' 2>/dev/null \
      | sed "s|\$label|$label|g")
    [ -n "$last" ] && echo "$last"
  done

  echo
  echo "next reconcile: ~$(get_reconcile_hint) (daemon polls on its own interval)"
}

get_reconcile_hint() {
  # Try to read from skill config first; fall back to default
  local hint
  hint=$(jq -r '.defaults.watch_interval_minutes // 10' "$CONFIG" 2>/dev/null || echo "10")
  echo "${hint}min (skill watcher; ralph daemon may poll faster)"
}

# ------------- operator commands -------------

operator_cmd() {
  local verb="$1"
  case "$verb" in
    retry|pause|resume|stop) ;;
    *) echo "ralph: invalid operator command '$verb' (valid: retry|pause|resume|stop)" >&2; exit 2 ;;
  esac

  gh_auth_check
  local repo; repo=$(resolve_repo)
  # Find the active run's issue (the one with ralph:running)
  local active; active=$(gh issue list --repo "$repo" --state open --label "ralph:running" --json number -q '.[0].number' 2>/dev/null || echo "")
  if [ -z "$active" ]; then
    echo "ralph: no active run (no issue has ralph:running label)" >&2
    if [ "$verb" = "pause" ] || [ "$verb" = "resume" ] || [ "$verb" = "stop" ]; then
      echo "ralph: posting daemon-level command on most-recent ralph issue (best effort)"
      active=$(gh issue list --repo "$repo" --state all --label "ralph:done" --json number -q '.[0].number' --limit 1 2>/dev/null || echo "")
    fi
    [ -z "$active" ] && exit 1
  fi

  echo "ralph: posting /ralph $verb on issue #$active"
  gh issue comment "$active" --repo "$repo" --body "/ralph $verb" >/dev/null
  echo "ralph: command posted; daemon will pick it up on next reconcile"
}

# ------------- wake -------------

wake() {
  if curl -s -X POST --max-time 3 -o /dev/null -w "%{http_code}" "$RECONCILE_URL" 2>/dev/null | grep -qE "^(200|202|204)$"; then
    echo "ralph: wake signal sent (immediate reconcile)"
  else
    echo "ralph: /api/reconcile-now not available; daemon will pick up on its next poll"
  fi
}

wake_quiet() {
  curl -s -X POST --max-time 2 -o /dev/null "$RECONCILE_URL" 2>/dev/null || true
}

# ------------- watch for claim -------------

watch_for_claim() {
  local repo="$1" issue="$2"
  echo "ralph: watching for claim on #$issue (up to 60s)..."
  local deadline=$((SECONDS + 60))
  while [ $SECONDS -lt $deadline ]; do
    local labels; labels=$(gh issue view "$issue" --repo "$repo" --json labels -q '[.labels[].name]' 2>/dev/null) || true
    if echo "$labels" | jq -e 'index("ralph:running") != null' >/dev/null 2>&1; then
      echo "ralph: claimed #$issue (label ralph:running observed)"
      return 0
    fi
    if echo "$labels" | jq -e 'index("ralph:failed") != null' >/dev/null 2>&1; then
      echo "ralph: issue #$issue ended in ralph:failed" >&2
      return 1
    fi
    sleep 5
  done
  echo "ralph: timed out waiting for claim on #$issue (label still ralph:ready); daemon may be slow or paused"
  return 0
}

# ------------- dispatch -------------

cmd="${1:-}"; shift || true

# Honor --dry-run / --yes anywhere in the args; strip them before dispatch
new_args=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  YES=1 ;;
    *)         new_args+=("$a") ;;
  esac
done
set -- "${new_args[@]:-}"

case "$cmd" in
  claim)   claim "$@" ;;
  queue)   queue "$@" ;;
  parent)  parent_children "$@" ;;
  status)  status ;;
  retry|pause|resume|stop) operator_cmd "$cmd" ;;
  wake)    wake ;;
  *)
    cat >&2 <<EOF
Usage: ralph.sh <subcommand> [args] [--dry-run]
  claim <N>[,<N>...]   — label issues ralph:ready
  queue <file>         — label issues from file
  parent <N>           — discover and label children of issue N
  status               — daemon health + queue counts
  retry|pause|resume|stop — operator command on active issue
  wake                 — trigger immediate reconcile (if supported)

Flags:
  --dry-run            preview labels without applying (claim/queue/parent)

Env:
  RALPH_HOST, RALPH_PORT, RALPH_REPO, ISSUE_LOOP_CONFIG, DRY_RUN
EOF
    exit 2
    ;;
esac
