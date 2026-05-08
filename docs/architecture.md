# Architecture

NightOwl is intentionally a thin layer. OpenClaw provides the messaging, agent isolation, skills, memory, approvals, and scheduler. NightOwl adds: a focused **persona**, four **orchestration skills**, a **per-issue runner**, and **two `BoardAdapter` implementations** so a kanban board can drive the same skill library that Telegram drives.

There are two input paths into the same skill library. The Telegram path is interactive — Ishan talks to the bot. The board-watcher path is autonomous — a systemd timer polls Linear and GitHub Issues, claims eligible tickets, and runs the same kind of work without a human in the loop.

## Telegram path

```
┌─────────────┐
│   Telegram  │  (text or voice note)
└──────┬──────┘
       │  message arrives at OpenClaw Telegram channel
       ▼
┌─────────────────────────────────────────────────┐
│  OpenClaw routing                                │
│  channels.telegram (account "nightowl")          │
│  → bound to agent: nightowl                      │
└──────┬──────────────────────────────────────────┘
       ▼
┌─────────────────────────────────────────────────┐
│  NightOwl agent  (microsoft-foundry/gpt-5.5)     │
│  Reads: IDENTITY, SOUL, USER, AGENTS, TOOLS      │
│  Persona: terse, ship-or-escalate                │
│                                                  │
│  Step 1: Voice → text via bin/transcribe-audio   │
│  Step 2: Classify intent                         │
│  Step 3: Pick one skill:                         │
│    • nightowl-feature-flow                       │
│    • nightowl-pr-review                          │
│    • nightowl-security-review                    │
└──────┬──────────────────────────────────────────┘
       ▼
┌─────────────────────────────────────────────────┐
│  Skill execution                                 │
│  - Clones target repo into repos/<task-id>/      │
│  - Shells to bin/claude-code-opus45 in print     │
│    mode for actual code generation               │
│  - Runs tests                                    │
│  - Pushes branch as Ishans-assistant             │
│  - Opens PR via gh CLI                           │
└──────┬──────────────────────────────────────────┘
       ▼
┌─────────────────────────────────────────────────┐
│  Reply on Telegram                               │
│  ✅ summary  📦 PR url  🧪 tests  ⏳ awaiting    │
└─────────────────────────────────────────────────┘
```

## Board-watcher path

```
┌──────────────────┐  every 30s   ┌────────────────────────┐
│ systemd timer    ├─────────────>│ bin/nightowl-board-    │
│ (oneshot service)│              │ watcher (orchestrator) │
└──────────────────┘              └─────────┬──────────────┘
                                            │
                  ┌─────────────────────────┼─────────────────────────┐
                  ▼                         ▼                         ▼
        ┌──────────────────┐    ┌──────────────────┐    (future adapters)
        │ GitHubIssues     │    │ Linear           │
        │ Adapter          │    │ Adapter          │
        │ (gh CLI)         │    │ (GraphQL)        │
        └────────┬─────────┘    └────────┬─────────┘
                 │ list_eligible()       │
                 └────────────┬──────────┘
                              ▼
                    ┌────────────────────┐
                    │ scheduler          │
                    │ - dedupe by id     │
                    │ - cap=2 (cfg)      │
                    │ - skip claimed     │
                    │ - lock files       │
                    └─────────┬──────────┘
                              ▼
                    ┌────────────────────┐
                    │ bin/nightowl-      │
                    │ issue-runner       │
                    │ - claim (label)    │
                    │ - workspace        │
                    │ - branch <ID>-...  │
                    │ - WORKFLOW.md      │
                    │ - claude-code      │
                    │ - quality gates    │
                    │ - push, PR         │
                    │ - comment back     │
                    └─────────┬──────────┘
                              ▼
                    ┌────────────────────┐
                    │  Linear / GitHub   │
                    │  ticket            │
                    │  • status comments │
                    │  • PR linked       │
                    │  • lifecycle label │
                    └────────────────────┘
```

The orchestrator is a single Python script that runs on every cron tick, holds a global tick lock so two ticks can't trample each other, queries each adapter, applies eligibility filters, and dispatches `bin/nightowl-issue-runner` in the background per issue. The runner does the per-issue work and writes its own log file under `~/.openclaw/workspace/nightowl/logs/`.

## Why two model layers

| Role | Model | Why |
|---|---|---|
| Orchestrator (the thing reading Telegram, deciding which skill to invoke) | `microsoft-foundry/gpt-5.5` (Azure-hosted) | Cheap, fast, already authenticated, matches the main agent. Doesn't need to write code — just routes intent. |
| Code generator (the thing writing the actual diff) | `claude-opus-4-5` via Claude Code CLI | Best-in-class for multi-file edits; already authenticated via `~/.claude/.credentials.json`. |

Splitting these means orchestration cost stays trivial even when the actual code work uses a heavyweight model. The board-watcher path also goes directly to Claude Code per ticket — no orchestrator LLM call per cron tick, so the autonomous loop costs nothing in tokens until a ticket is actually claimed.

## Why NOT use OpenClaw's `anthropic` provider for code

The `anthropic:default` profile in `~/.openclaw/agents/main/agent/auth-profiles.json` was 401-failing during development (token expired). The standalone `claude` CLI uses a different auth path (`~/.claude/.credentials.json`) which works. Until the OpenClaw provider is re-authed, shelling out to the CLI is more reliable. This also matches the existing `coding-agent` skill's documented pattern.

## Voice path

```
Telegram voice note
  → downloaded to /tmp/<id>.ogg by OpenClaw telegram channel
  → bin/transcribe-audio /tmp/<id>.ogg
       → Azure transcribe endpoint (env in .secrets/azure-transcribe.env)
       → falls back to local Whisper base model on failure
  → transcript text becomes the message body for intent classification
```

This wrapper already exists; NightOwl just calls it.

## Per-repo configuration via `WORKFLOW.md`

Each repo NightOwl operates on places a `WORKFLOW.md` at its root. The watcher reads it on every tick and uses it to:

- Filter eligible tickets (active states, labels)
- Resolve `install` / `test` / `lint` / `build` commands for quality gates
- Decide whether failed tests open a PR as draft or fail outright
- Pick the prompt template the per-issue runner sends to Claude Code

This keeps repo-specific knowledge (test runner, lint config, framework conventions) version-controlled alongside the code, not buried in agent state. See [`docs/workflow-md.md`](workflow-md.md) for the full schema and [`examples/WORKFLOW.md`](../examples/WORKFLOW.md) for an annotated reference.

## Approvals

OpenClaw's `exec-approvals` provides Telegram inline-button confirmation for sensitive ops. NightOwl uses it for:

- PR merges
- Production deploys
- Branch deletions
- Anything that mutates `main` directly

For low-risk operations (clone, branch, code, tests, push, open PR), NightOwl proceeds autonomously.

## Trust boundary

- **Telegram path:** NightOwl only responds to the peer listed in `commands.ownerAllowFrom` of `openclaw.json`.
- **Board-watcher path:** NightOwl only picks up tickets that opt in explicitly via the `nightowl` label (Linear) or label/assignee (GitHub). The default eligibility filter refuses to run if no opt-in is configured, so a misconfigured tracker can't cause the bot to start working on the entire backlog.
- **Repo access:** NightOwl only operates on repos where `Ishans-assistant` is a collaborator. All work happens in temp clones under `repos/<task-id>/`. No cross-repo state leakage.
- **GitHub auth:** the bot's GitHub auth is via `gh auth login --web` (device flow, no PAT). Tokens are managed by `gh` and rotated on its own schedule.
- **Linear auth:** stored in `~/.openclaw/workspace/.secrets/linear.env`, mode `0600`. The watcher loads it into the subprocess environment before invoking adapters.

## What's not in the submission MVP

- Multi-agent orchestration (parallel role-specialists per ticket) — listed in roadmap.
- Auto-deploy to Vercel/Netlify — placeholder skill scaffold designed but not shipped.
- Overnight monitoring + auto-rollback via cron + Sentry — listed in roadmap.
- WhatsApp / Slack channels — explicitly cut to keep the demo focused.
