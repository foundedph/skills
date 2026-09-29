# TASK: check-plugin-manifest

## Goal

Create `scripts/check-plugin-manifest.sh`, a bash script that verifies `.claude-plugin/plugin.json`'s `skills` array lists **exactly** the promoted skills. A skill is promoted when it's a directory directly under `skills/engineering/` or `skills/productivity/` that contains a `SKILL.md`.

Make the existing failing tests pass:

```bash
bash scripts/test-check-plugin-manifest.sh
```

## Behaviour

- Usage: `scripts/check-plugin-manifest.sh [repo-root]`. Default repo-root is the parent of the script's directory.
- Promoted set: `skills/{engineering,productivity}/<name>/SKILL.md`, **one level only**. A `SKILL.md` nested deeper (e.g. `skills/engineering/tdd/examples/sub/SKILL.md`) does not count.
- Manifest entries look like `"./skills/engineering/tdd"`. Compare them as `engineering/tdd` style paths.
- Report every problem, one per line, on stderr:
  - `missing from plugin.json: <bucket>/<name>` for a promoted skill that is not listed
  - `not promoted but in plugin.json: <bucket>/<name>` for an entry outside `engineering/` / `productivity/`
  - `no such skill: <bucket>/<name>` for an entry whose directory has no `SKILL.md`
- Exit codes: 0 when in sync (print `plugin.json in sync (<n> skills)` to stdout), 1 on any mismatch, 2 when `plugin.json` is missing (message must mention `plugin.json`).
- Parse the JSON with `jq` if it's available, otherwise fall back to `grep`/`sed` over the `"./skills/..."` strings. Both must work.
- `set -euo pipefail`, portable to macOS bash 3.2 (no `mapfile`, no associative arrays).

## Acceptance criteria

- [ ] `bash scripts/test-check-plugin-manifest.sh` prints `all passed` and exits 0
- [ ] `scripts/check-plugin-manifest.sh` is executable
- [ ] Works with `jq` removed from PATH (e.g. `PATH=/usr/bin:/bin bash scripts/test-check-plugin-manifest.sh` if jq lives elsewhere)
- [ ] `bash -n` passes and the script has a short header comment matching `scripts/list-skills.sh`'s style

## Files

- **Allowed:** `scripts/check-plugin-manifest.sh` (new)
- **Denied:** everything else, especially `scripts/test-check-plugin-manifest.sh`, `.claude-plugin/*`, `README.md`, and anything under `skills/`. Don't fix real-repo drift the script reveals. Just report it in the results.

## Commands

```bash
bash scripts/test-check-plugin-manifest.sh
bash -n scripts/check-plugin-manifest.sh
bash scripts/check-plugin-manifest.sh    # real repo; any exit is fine, note the output in results
```

Do not commit or push.

## Executor results

- **Status:** done — `bash scripts/test-check-plugin-manifest.sh` prints `all passed` and exits 0, both with `jq` on PATH and with `jq` hidden from PATH.
- **Created:** `scripts/check-plugin-manifest.sh` (executable, `chmod +x`). No other files touched.

### What it does

- Promoted set: globs one level under each bucket in `PROMOTED_BUCKETS="engineering productivity"`, keeping dirs with a `SKILL.md`; a `SKILL.md` nested deeper than one level is ignored.
- Parses only the top-level `skills` array, in order `jq` → `python3 -c 'import json…'` → grep/sed. The grep/sed last resort prints a `warning:` to stderr because it cannot validate JSON.
- Strict entry shape: an entry must be exactly `./skills/<bucket>/<name>` (no trailing slash, no missing `./`, no deeper nesting). Anything else → `bad entry: <raw entry>`. Duplicates → `duplicate in plugin.json: <bucket>/<name>`.
- Reports every problem on stderr, then exits 1:
  - `missing from plugin.json: <bucket>/<name>`
  - `bad entry: <raw entry>`
  - `not promoted but in plugin.json: <bucket>/<name>`
  - `duplicate in plugin.json: <bucket>/<name>`
  - `no such skill: <bucket>/<name>`
- Exit 0 with `plugin.json in sync (<promoted_count> skills)` on stdout; exit 2 when the manifest is missing or malformed (message contains `malformed` / `plugin.json`).
- `set -euo pipefail`; bash 3.2 safe (no `mapfile`/associative arrays). No `|| true`: a failed parse/command surfaces instead of becoming an empty manifest (grep exit 1 = empty array; any other code aborts).

### Verification

- `bash -n scripts/check-plugin-manifest.sh` → ok.
- `bash scripts/test-check-plugin-manifest.sh` → `all passed`, exit 0 (12/12).
- **No-jq path — how I actually verified it:** `/usr/bin/jq` exists on this machine, so `PATH=/usr/bin:/bin` does *not* hide jq. I built a temp bin dir of symlinks that omits jq but includes `python3`, asserted `PATH="$BIN" command -v jq` was empty, then ran `PATH="$BIN" bash scripts/test-check-plugin-manifest.sh` → `all passed`, exit 0. That exercises the `python3` parser against all 12 tests (including malformed → exit 2).
- Extra: with **both** jq and python3 absent, the grep/sed fallback passes 11/12 — only the malformed case fails, which a non-validating fallback cannot detect (it prints the warning). This configuration is outside the required matrix.

### Real-repo run (`bash scripts/check-plugin-manifest.sh`, exit 1)

```
missing from plugin.json: engineering/cp-drain
missing from plugin.json: engineering/cp-drive
```

Real drift exists: those two dirs are under `skills/engineering/` with a `SKILL.md` but are absent from `.claude-plugin/plugin.json`. Per the denylist I did **not** touch the manifest — reporting only. No manifest entry lacked a `SKILL.md`, so no `no such skill` lines.


## Review round 1 — NEEDS_WORK

New failing tests were added to `scripts/test-check-plugin-manifest.sh` (don't edit it). Make all of them pass, **both with `jq` and with `jq` absent from PATH** (macOS has `/usr/bin/jq`, so `PATH=/usr/bin:/bin` does NOT hide it — the reviewer runs the suite with a PATH of symlinks that omits jq but includes `python3`).

Findings to address in `scripts/check-plugin-manifest.sh`:

1. **Malformed JSON must exit 2** with a message containing `malformed`. Don't swallow parse errors with `2>/dev/null || true`. Parser order: `jq` → `python3 -c 'import json…'` → last-resort `grep`/`sed` (which can't validate; print a `warning:` to stderr when used). All parsers read **only** the top-level `skills` array — `./skills/...` strings elsewhere in the file must be ignored.
2. **Strict entry shape.** Every entry must match exactly `./skills/<bucket>/<name>` (no trailing slash, no missing `./`, no deeper nesting). Anything else → `bad entry: <raw entry>` and exit 1. Don't silently drop or normalise.
3. **Duplicates** → `duplicate in plugin.json: <bucket>/<name>`, exit 1.
4. Don't let `|| true` hide a genuinely failing command (e.g. grep missing → exit 127 should not become "empty manifest").
5. Standards (judgement calls, do them): define the promoted buckets once (e.g. `PROMOTED_BUCKETS="engineering productivity"` + a `case`) instead of listing them twice; rename `n` → `promoted_count`, `extra` → `unpromoted`, `stale` → `dangling`; avoid `printf | grep -q` in `contains` (use a `case "$nl$list$nl" in *"$nl$item$nl"*)` match) so pipefail/SIGPIPE can't cause a false result.

Update the Executor results section (replace the old one's claims) and say honestly how you verified the no-jq path.
