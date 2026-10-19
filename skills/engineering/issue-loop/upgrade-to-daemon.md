# Phase B: Upgrade to Standalone Daemon

The `/issue-loop` skill is **Phase A** — invoked from inside a Claude Code session, manually or in `--watch` mode. This page documents what's required to graduate it to **Phase B**: a standalone daemon on the Mac Mini that runs 24/7, listens for GitHub webhooks, and spawns headless Claude Code sessions per issue.

## Why upgrade

Phase A constraints that go away in Phase B:
- Requires an open Claude Code session to run `--watch`
- Polling-only (no event-driven triggers)
- One issue at a time per session (no parallelism)
- Session crash = loop crash

Phase B gains:
- Always-on (LaunchDaemon)
- Webhook-driven (sub-minute reaction to new issues)
- Optional parallelism (multiple worktrees + headless sessions concurrently)
- Crash-restart automatic

## When to upgrade

Trigger conditions (any one):
- The skill has been working reliably for 2+ weeks
- You want sub-10-minute reaction time on filed issues
- Issue volume exceeds ~10/day (polling becomes wasteful)
- You want the loop running while your Mac is sleeping/closed

Do **not** upgrade prematurely. The skill version is debuggable; the daemon version is not.

## Migration plan

### What carries over unchanged

These contracts are designed to be daemon-compatible:
- **Config schema** (`~/.claude/issue-loop.config.json`) — same file, same fields
- **Run log schema** (per-issue JSON in `~/.claude/issue-loop/runs/`) — daemon reads/writes the same format
- **Orchestration contracts** (RED/GREEN/REFACTOR phase contracts in `orchestration.md`)
- **Progress detector logic** (`progress-detector.sh`) — invoked the same way

### What changes

| Layer | Phase A | Phase B |
|-------|---------|---------|
| Trigger | Manual `/issue-loop` or `/loop` polling | GitHub webhook → daemon |
| Process | Inside a Claude Code session | Daemon spawns `claude-code --headless` per issue |
| Coordination | None (one issue at a time, sequential) | Daemon manages concurrency limit |
| Notifications | Telegram via current session's MCP | Daemon writes to a notification queue, separate notifier service drains it |
| Failure handling | Session prints + exits | Daemon retries on transient errors, logs to journal |

### Recommended Phase B architecture

```
~/services/issue-loop-daemon/
├── package.json
├── src/
│   ├── daemon.ts              # main service, listens on :8792
│   ├── webhook-handler.ts     # GitHub issues.opened, issues.labeled, issues.edited
│   ├── queue.ts               # in-memory + on-disk queue (sqlite)
│   ├── worker.ts              # spawn claude-code --headless --skill issue-loop --issue <N>
│   ├── config.ts              # reuses ~/.claude/issue-loop.config.json
│   ├── runs.ts                # reads/writes ~/.claude/issue-loop/runs/
│   └── notifications.ts       # Telegram, Slack, etc.
├── launchd/
│   └── com.foundedph.issue-loop.plist
└── README.md
```

### LaunchDaemon plist (template)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.foundedph.issue-loop</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>/Users/wlq/services/issue-loop-daemon/dist/daemon.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/wlq/services/issue-loop-daemon</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NODE_ENV</key><string>production</string>
        <key>SIGNPORTAL_GITHUB_TOKEN</key><string>...</string>
        <key>SIGNPORTAL_GITHUB_WEBHOOK_SECRET</key><string>...</string>
    </dict>
    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/var/log/issue-loop.out</string>
    <key>StandardErrorPath</key><string>/var/log/issue-loop.err</string>
</dict>
</plist>
```

### Webhook setup

```yaml
# Cloudflare Tunnel ingress rule
- hostname: issue-loop.founded.ph
  service: http://localhost:8792
```

GitHub repo settings → Webhooks → Add:
- Payload URL: `https://issue-loop.founded.ph/webhook`
- Content type: `application/json`
- Secret: `$SIGNPORTAL_GITHUB_WEBHOOK_SECRET`
- Events: `Issues`, `Pull requests`, `Push`

### Coexistence with Phase A

The daemon and the skill can coexist:
- Daemon owns webhook-driven runs
- Skill (`/issue-loop --issue 142`) is still useful for manual one-offs and dry-runs
- Both write to the same run log directory
- Use a `lock` field in run logs (`status: "running"`, `pid: <daemon|session>`) to prevent double-execution

### Testing the upgrade

Before flipping the daemon to `KeepAlive: true`:

1. Run the daemon in foreground for 1 day with `--dry-run` (no PRs, just log decisions)
2. Compare its decisions to what the skill would have made (read the run logs from each)
3. If decisions match, switch to live mode but keep skill `--watch` disabled
4. After 1 week of stable daemon runs, deprecate skill `--watch` (manual `/issue-loop` stays)

## Headless Claude Code invocation

The daemon spawns Claude Code in headless mode per issue:

```bash
claude-code \
  --headless \
  --skill issue-loop \
  --skill-args "--issue 142 --repo signportal" \
  --output-json \
  --timeout 1800
```

The headless session uses the same skill body — it just doesn't have a TTY. The orchestration contracts (RED/GREEN/REFACTOR) work identically because they're text-based, not UI-based.

## Telemetry differences

| Phase A | Phase B |
|---------|---------|
| Run logs only | Run logs + queue depth + concurrency utilization + webhook latency |
| Session terminal output | LaunchDaemon stdout/stderr to `/var/log/` |
| Telegram from session MCP | Telegram from daemon HTTP client |

The Phase A run-log schema is a strict subset of what Phase B writes — opening older Phase A logs in the daemon's UI works without migration.

## Rollback

If the daemon misbehaves:
```bash
sudo launchctl unload /Library/LaunchDaemons/com.foundedph.issue-loop.plist
```
The skill (`/issue-loop`) keeps working; the daemon just stops handling webhooks. No data migration is needed to roll forward or back — the run log directory is the shared source of truth.
