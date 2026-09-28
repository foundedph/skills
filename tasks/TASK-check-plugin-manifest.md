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

