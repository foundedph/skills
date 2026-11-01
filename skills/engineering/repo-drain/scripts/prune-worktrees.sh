#!/usr/bin/env bash
# prune-worktrees.sh [--apply] [--sweep] [--repo <path>] [--base origin/dev] [--keep <substr>]...
#
# Remove the worktrees (and their local branches) of work that is PROVABLY merged, so a long
# drain does not pile up gigabytes. Dry run by default: prints a verdict per worktree.
#
# A worktree is pruned only when ALL hold:
#   1. it is not the main checkout and not matched by --keep;
#   2. `git status --porcelain` is empty (nothing uncommitted or untracked; ignored files such as
#      node_modules and tests/e2e/.recordings do not count);
#   3. its work is merged, by one of:
#        a. HEAD is an ancestor of <base>            (merge / fast-forward), or
#        b. a MERGED PR exists for the branch and HEAD equals that PR's head commit
#           (squash-merge; commits made after the PR's last push keep the worktree);
#   4. no live process has its cwd inside it (a pane agent, a shell, an editor).
# --sweep also reclaims regenerable weight inside worktrees that are KEPT but idle (clean tree, no live
# process): a real `node_modules` directory (~900 MB per agent worktree; symlinks are left alone and
# `scripts/hooks/worktree-link-node-modules.sh` relinks it) and stale `.check-logs`. It never touches
# `tests/e2e/.recordings` (E2E evidence).
# Never uses --force. The local branch is deleted after the worktree is removed; remote branches
# are left alone. Dirty, unmerged or in-use worktrees are listed with the reason and kept.
set -uo pipefail

APPLY=0; SWEEP=0; BASE="origin/dev"; REPO=""; KEEP=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --sweep) SWEEP=1 ;;
    --base) BASE="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    --keep) KEEP+=("$2"); shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -n "$REPO" ]] || { echo "prune-worktrees: not in a git repo (use --repo)" >&2; exit 2; }
MAIN="$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')"
git -C "$MAIN" fetch -q origin "${BASE#origin/}" 2>/dev/null || echo "warn: could not fetch $BASE; using the local ref" >&2

# Every directory some live process is working in (one lsof call, not one per worktree).
CWDS="$(lsof -nP -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)"

pruned=0; kept=0; freed_kb=0; swept_kb=0
emit() { printf '%-9s %s  (%s)\n' "$1" "$2" "$3"; }


# Reclaim regenerable weight inside an idle, clean worktree that is being kept.
sweep() {
  local p="$1" name="$2" freed=0 kb
  [[ "$SWEEP" == "1" ]] || return 0
  if [[ -d "$p/node_modules" && ! -L "$p/node_modules" ]]; then
    kb="$(du -sk "$p/node_modules" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
    if [[ "$APPLY" == "1" ]]; then rm -rf "$p/node_modules" && freed=$((freed+kb)); else freed=$((freed+kb)); fi
  fi
  if [[ -d "$p/.check-logs" ]]; then
    kb="$(du -sk "$p/.check-logs" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
    if [[ "$APPLY" == "1" ]]; then rm -rf "$p/.check-logs" && freed=$((freed+kb)); else freed=$((freed+kb)); fi
  fi
  if [[ "$freed" -gt 0 ]]; then
    emit "$([[ "$APPLY" == "1" ]] && echo SWEPT || echo SWEEP)" "$name" "node_modules/.check-logs: $((freed/1024)) MB"
    swept_kb=$((swept_kb+freed))
  fi
}

path=""; head=""; branch=""
process() {
  local p="$1" h="$2" b="$3"
  [[ -z "$p" || "$p" == "$MAIN" ]] && return
  local name; name="$(basename "$p")"
  for k in "${KEEP[@]:-}"; do [[ -n "$k" && "$p" == *"$k"* ]] && { emit KEEP "$name" "matched --keep $k"; kept=$((kept+1)); return; }; done
  if [[ ! -d "$p" ]]; then emit KEEP "$name" "directory missing (run: git worktree prune)"; kept=$((kept+1)); return; fi

  # In use: a live process works here. Nothing is touched, not even the sweep.
  if printf '%s\n' "$CWDS" | grep -Fq -- "$p"; then emit KEEP "$name" "a live process is working in it"; kept=$((kept+1)); return; fi

  # Uncommitted or untracked work: the tree stays. Idle, so its regenerable weight may be swept.
  local dirty; dirty="$(git -C "$p" status --porcelain 2>/dev/null | grep -v -E ' node_modules/?$| \.check-logs/?$' | head -3)"
  if [[ -n "$dirty" ]]; then emit KEEP "$name" "uncommitted or untracked changes"; kept=$((kept+1)); sweep "$p" "$name"; return; fi

  local merged="" why=""
  if git -C "$MAIN" merge-base --is-ancestor "$h" "$BASE" 2>/dev/null; then
    merged=1; why="HEAD is on $BASE"
  elif [[ -n "$b" ]]; then
    local pr; pr="$(gh pr list --head "$b" --state merged --json number,headRefOid -q 'if length > 0 then "\(.[0].number) \(.[0].headRefOid)" else empty end' 2>/dev/null)"
    if [[ -n "$pr" && "${pr#* }" == "$h" ]]; then merged=1; why="PR #${pr%% *} merged at this exact commit"
    elif [[ -n "$pr" ]]; then emit KEEP "$name" "PR #${pr%% *} merged, but this branch has commits after its last push"; kept=$((kept+1)); sweep "$p" "$name"; return
    fi
  fi
  if [[ -z "$merged" ]]; then emit KEEP "$name" "work not merged into $BASE"; kept=$((kept+1)); sweep "$p" "$name"; return; fi

  local kb; kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
  if [[ "$APPLY" == "1" ]]; then
    local rm_err
    if rm_err="$(git -C "$MAIN" worktree remove "$p" 2>&1)"; then
      [[ -n "$b" ]] && git -C "$MAIN" branch -D "$b" >/dev/null 2>&1
      emit PRUNED "$name" "$why; freed $((kb/1024)) MB"; pruned=$((pruned+1)); freed_kb=$((freed_kb+kb))
    else
      emit KEEP "$name" "git refused to remove it: $(printf '%s' "$rm_err" | head -1)"; kept=$((kept+1))
    fi
  else
    emit WOULD "$name" "$why; would free $((kb/1024)) MB"; pruned=$((pruned+1)); freed_kb=$((freed_kb+kb))
  fi
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) process "$path" "$head" "$branch"; path="${line#worktree }"; head=""; branch="" ;;
    "HEAD "*)     head="${line#HEAD }" ;;
    "branch "*)   branch="${line#branch refs/heads/}" ;;
  esac
done < <(git -C "$MAIN" worktree list --porcelain; echo "worktree ")

[[ "$APPLY" == "1" ]] && git -C "$MAIN" worktree prune
echo "--"
[[ "$SWEEP" == "1" ]] && echo "sweep: ~$((swept_kb/1024)) MB $([[ "$APPLY" == "1" ]] && echo reclaimed || echo reclaimable) from idle kept worktrees"
if [[ "$APPLY" == "1" ]]; then echo "pruned $pruned, kept $kept, freed ~$((freed_kb/1024)) MB"
else echo "dry run: $pruned prunable (~$((freed_kb/1024)) MB), $kept kept. Re-run with --apply to remove."; fi
