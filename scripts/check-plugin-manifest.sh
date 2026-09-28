#!/usr/bin/env bash
# check-plugin-manifest — verify .claude-plugin/plugin.json lists exactly the promoted skills.
#
# Usage: check-plugin-manifest.sh [repo-root]   (default: parent of this script's directory)
# Exit:  0 in sync, 1 any mismatch, 2 plugin.json missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFEST="$REPO/.claude-plugin/plugin.json"

if [ ! -f "$MANIFEST" ]; then
  echo "check-plugin-manifest: no plugin.json at $MANIFEST" >&2
  exit 2
fi

# Promoted skills: a directory one level under an engineering/productivity bucket with a SKILL.md.
promoted=""
for bucket in engineering productivity; do
  for dir in "$REPO/skills/$bucket"/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    promoted="$promoted$bucket/$(basename "$dir")"$'\n'
  done
done

# Manifest entries, normalised from "./skills/<bucket>/<name>" to "<bucket>/<name>".
if command -v jq >/dev/null 2>&1; then
  entries="$(jq -r '.skills[]?' "$MANIFEST" 2>/dev/null | sed -n 's|^\./skills/||p' || true)"
else
  entries="$(grep -o '"\./skills/[^"]*"' "$MANIFEST" | sed 's|^"\./skills/||; s|"$||' || true)"
fi

contains() { [ -n "$2" ] && printf '%s\n' "$2" | grep -qxF -- "$1"; }

missing=""
extra=""
stale=""
n=0

while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  n=$((n + 1))
  contains "$skill" "$entries" || missing="$missing"$'missing from plugin.json: '"$skill"$'\n'
done <<<"$promoted"

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  bucket="${entry%%/*}"
  if [ "$bucket" = engineering ] || [ "$bucket" = productivity ]; then
    [ -f "$REPO/skills/$entry/SKILL.md" ] || stale="$stale"$'no such skill: '"$entry"$'\n'
  else
    extra="$extra"$'not promoted but in plugin.json: '"$entry"$'\n'
  fi
done <<<"$entries"

problems="${missing}${extra}${stale}"
if [ -n "$problems" ]; then
  printf '%s' "$problems" >&2
  exit 1
fi

echo "plugin.json in sync ($n skills)"
