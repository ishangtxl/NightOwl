---
name: nightowl-board-watcher
description: |
  NightOwl's autonomous polling loop over Linear and GitHub Issues. Driven
  by a systemd timer, not by Telegram messages — this skill exists so the
  agent can answer questions ABOUT the watcher (status, queue, recent runs)
  without re-implementing it.
metadata:
  openclaw:
    emoji: "🦉"
    requires:
      anyBins: ["claude", "gh"]
---

# NightOwl Board Watcher

The watcher is **autonomous**. A systemd timer fires `bin/nightowl-board-watcher` every 30 seconds, independent of any Telegram conversation. This skill is documentation for when Ishan asks questions about it.

## When to use this skill

Only when answering questions about the watcher itself:

- "Are you watching anything?" / "What's in your queue?"
- "What tickets did you ship today?"
- "Is the watcher running?"
- "Pause / resume the watcher"

If Ishan asks NightOwl to *do* something on a ticket directly via Telegram, use `nightowl-feature-flow` — don't try to invoke the watcher manually.

## Answering common questions

| Question | How to answer |
|---|---|
| Watcher status | `systemctl is-active nightowl-board-watcher.timer` (active/inactive) |
| Active runs | `ls /root/.openclaw/workspace/nightowl/.locks/*.lock` (one file per running issue) |
| Today's PRs | `grep "PR opened" /var/log/nightowl-watcher.log` and the trailing log per run in `~/.openclaw/workspace/nightowl/logs/` |
| Configured trackers | read `~/.openclaw/workspace/nightowl/board-watcher.config.yaml` |
| Pause | `systemctl stop nightowl-board-watcher.timer` — only with explicit approval |
| Resume | `systemctl start nightowl-board-watcher.timer` |
| Tail logs live | `tail -f /var/log/nightowl-watcher.log` |

## What the watcher does on each tick

1. Acquires a global tick lock (only one tick runs at a time).
2. Reads `board-watcher.config.yaml` to find configured trackers.
3. For each tracker, asks the corresponding adapter for eligible issues:
   - `bin/adapters/linear` — Linear GraphQL, filters by `nightowl` label
   - `bin/adapters/github-issues` — GitHub via `gh` CLI, filters by `nightowl` label OR assignee
4. Excludes issues already in `nightowl:claimed`, `nightowl:done`, `nightowl:failed`, or `nightowl:waiting`.
5. Up to `max_concurrent_runs` (default 2) issues are dispatched in parallel via `bin/nightowl-issue-runner`.
6. Each runner clones the target repo, branches as `<ticket-key-lowercase>-<slug>`, runs Claude Code per the repo's `WORKFLOW.md`, runs quality gates, pushes, opens a PR with `Closes <key>`, and posts the PR URL back to the ticket.

## Architecture pointers

- Per-issue workspace: `~/.openclaw/workspace/nightowl/repos/<tracker>-<safe-key>/`
- Lock files: `~/.openclaw/workspace/nightowl/.locks/<tracker>-<safe-key>.lock`
- Per-run log: `~/.openclaw/workspace/nightowl/logs/<tracker>-<key>-<unix-ts>.log`
- Aggregate log: `/var/log/nightowl-watcher.log`
- WORKFLOW.md schema: `docs/workflow-md.md` in the submission repo

## Don't

- Don't spin up your own polling loop or one-off invocations from a Telegram conversation.
- Don't disable the timer without an explicit approval.
- Don't directly edit the lock files.
