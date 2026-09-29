#!/usr/bin/env bash
# check-plugin-manifest — verify .claude-plugin/plugin.json lists exactly the promoted skills.
#
# Usage: check-plugin-manifest.sh [repo-root]   (default: parent of this script's directory)
# Exit:  0 in sync, 1 any mismatch, 2 plugin.json missing or malformed.
set -euo pipefail

PROMOTED_BUCKETS="engineering productivity"
NL=$'\n'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFEST="$REPO/.claude-plugin/plugin.json"

is_promoted_bucket() {
  case " $PROMOTED_BUCKETS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

contains() {
  # contains <item> <newline-delimited list>
  case "$NL$2$NL" in
    *"$NL$1$NL"*) return 0 ;;
  esac
  return 1
}

normalise_entry() {
  # Echo <bucket>/<name> for a strict "./skills/<bucket>/<name>" entry; return 1 otherwise.
  local rest bucket name
  case "$1" in
    './skills/'*) rest="${1#./skills/}" ;;
    *) return 1 ;;
  esac
  case "$rest" in
    */*/*|*/|/*) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  bucket="${rest%%/*}"
  name="${rest#*/}"
  [ -n "$bucket" ] && [ -n "$name" ] || return 1
  printf '%s/%s\n' "$bucket" "$name"
}

report=""
append_lines() {
  # append_lines <prefix> <newline-delimited list>
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    report="$report$1$l$NL"
  done <<<"$2"
}

if [ ! -f "$MANIFEST" ]; then
  echo "check-plugin-manifest: no plugin.json at $MANIFEST" >&2
  exit 2
fi

# Promoted skills: a directory one level under a promoted bucket that has a SKILL.md.
promoted=""
promoted_count=0
for bucket in $PROMOTED_BUCKETS; do
  for dir in "$REPO/skills/$bucket"/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    promoted="$promoted$bucket/$(basename "$dir")$NL"
    promoted_count=$((promoted_count + 1))
  done
done

# Raw entries of the top-level "skills" array. jq first, then python3, then grep/sed.
raw_entries=""
if command -v jq >/dev/null 2>&1; then
  if ! raw_entries="$(jq -r '.skills[]?' "$MANIFEST" 2>/dev/null)"; then
    echo "malformed plugin.json: $MANIFEST" >&2
    exit 2
  fi
elif command -v python3 >/dev/null 2>&1; then
  if ! raw_entries="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
skills = data.get("skills") if isinstance(data, dict) else None
if skills is None:
    skills = []
if not isinstance(skills, list):
    sys.exit(1)
for item in skills:
    print(item)
' "$MANIFEST")"; then
    echo "malformed plugin.json: $MANIFEST" >&2
    exit 2
  fi
else
  echo "warning: neither jq nor python3 found; using grep/sed fallback (cannot validate plugin.json)" >&2
  if ! block="$(awk '
    !inb && /"skills"[[:space:]]*:/ {
      inb = 1
      if (match($0, /\[[^]]*\]/)) { print substr($0, RSTART, RLENGTH); inb = 0 }
      next
    }
    inb { print; if ($0 ~ /^[[:space:]]*\]/) inb = 0 }
  ' "$MANIFEST")"; then
    echo "check-plugin-manifest: failed to read $MANIFEST" >&2
    exit 1
  fi
  if raw_entries="$(printf '%s\n' "$block" | grep -o '"[^"]*"' | sed 's/^"//; s/"$//')"; then
    :
  else
    rc=$?
    if [ "$rc" != 1 ]; then
      echo "check-plugin-manifest: failed to parse $MANIFEST (grep/sed exit $rc)" >&2
      exit 1
    fi
    raw_entries=""
  fi
fi

# Validate entry shape (report the raw entry; never silently drop), and flag duplicates.
entries=""
seen=""
bad=""
duplicates=""
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  if norm="$(normalise_entry "$raw")"; then
    if contains "$norm" "$seen"; then
      duplicates="$duplicates$norm$NL"
    else
      seen="$seen$norm$NL"
      entries="$entries$norm$NL"
    fi
  else
    bad="$bad$raw$NL"
  fi
done <<<"$raw_entries"

missing=""
unpromoted=""
dangling=""

while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  contains "$skill" "$entries" || missing="$missing$skill$NL"
done <<<"$promoted"

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if is_promoted_bucket "${entry%%/*}"; then
    [ -f "$REPO/skills/$entry/SKILL.md" ] || dangling="$dangling$entry$NL"
  else
    unpromoted="$unpromoted$entry$NL"
  fi
done <<<"$entries"

append_lines 'missing from plugin.json: ' "$missing"
append_lines 'bad entry: ' "$bad"
append_lines 'not promoted but in plugin.json: ' "$unpromoted"
append_lines 'duplicate in plugin.json: ' "$duplicates"
append_lines 'no such skill: ' "$dangling"

if [ -n "$report" ]; then
  printf '%s' "$report" >&2
  exit 1
fi

echo "plugin.json in sync ($promoted_count skills)"
