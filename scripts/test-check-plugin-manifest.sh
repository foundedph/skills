#!/usr/bin/env bash
# Tests for scripts/check-plugin-manifest.sh, run against throwaway fixture repos.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/check-plugin-manifest.sh"
FAILS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# make_repo <dir> <skill paths...> -- <plugin.json skills entries...>
make_repo() {
  local dir="$1"; shift
  mkdir -p "$dir/.claude-plugin"
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    mkdir -p "$dir/skills/$1"
    printf -- '---\nname: %s\n---\n' "$(basename "$1")" > "$dir/skills/$1/SKILL.md"
    shift
  done
  [ "${1:-}" = "--" ] && shift
  local entries="" sep=""
  for e in "$@"; do entries="$entries$sep\"./skills/$e\""; sep=", "; done
  printf '{\n  "name": "fixture",\n  "skills": [%s]\n}\n' "$entries" > "$dir/.claude-plugin/plugin.json"
}

# expect <name> <expected-exit> <stdout+stderr must contain (or "")> <repo>
expect() {
  local name="$1" want="$2" needle="$3" repo="$4" out code
  out="$(bash "$SCRIPT" "$repo" 2>&1)"; code=$?
  if [ "$code" != "$want" ]; then
    echo "FAIL $name: exit $code, want $want"; echo "$out" | sed 's/^/    /'; FAILS=$((FAILS+1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL $name: output missing '$needle'"; echo "$out" | sed 's/^/    /'; FAILS=$((FAILS+1)); return
  fi
  echo "ok   $name"
}

make_repo "$TMP/clean" engineering/tdd productivity/grill-me personal/notes misc/old -- \
  engineering/tdd productivity/grill-me
expect "in sync passes" 0 "" "$TMP/clean"

make_repo "$TMP/missing" engineering/tdd engineering/cp-drive -- engineering/tdd
expect "promoted skill missing from manifest fails" 1 "engineering/cp-drive" "$TMP/missing"

make_repo "$TMP/extra" engineering/tdd personal/notes -- engineering/tdd personal/notes
expect "non-promoted skill in manifest fails" 1 "personal/notes" "$TMP/extra"

make_repo "$TMP/stale" engineering/tdd -- engineering/tdd engineering/gone
expect "manifest entry with no skill dir fails" 1 "engineering/gone" "$TMP/stale"

make_repo "$TMP/nested" engineering/tdd -- engineering/tdd
mkdir -p "$TMP/nested/skills/engineering/tdd/examples/sub"
echo x > "$TMP/nested/skills/engineering/tdd/examples/sub/SKILL.md"
expect "nested SKILL.md below a skill is ignored" 0 "" "$TMP/nested"

mkdir -p "$TMP/nomanifest/skills/engineering/tdd"
expect "missing plugin.json is a setup error" 2 "plugin.json" "$TMP/nomanifest"

[ "$FAILS" = 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
