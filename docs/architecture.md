# Architecture

NightOwl is intentionally a thin layer. OpenClaw provides ~80% of the infrastructure (channels, agents, skills, memory, approvals, scheduler). NightOwl adds: a focused **persona**, three **orchestration skills**, and a **submission story**.

## High-level flow

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

## Why two model layers

| Role | Model | Why |
|---|---|---|
| Orchestrator (the thing reading Telegram, deciding which skill to invoke) | `microsoft-foundry/gpt-5.5` (Azure-hosted) | Cheap, fast, already authenticated, matches the main agent. Doesn't need to write code — just routes intent. |
| Code generator (the thing writing the actual diff) | `claude-opus-4-5` via Claude Code CLI | Best-in-class for multi-file edits; already authenticated via `~/.claude/.credentials.json`. |

Splitting these means orchestration cost stays trivial even when the actual code work uses a heavyweight model.

## Why NOT use OpenClaw's `anthropic` provider for code

The `anthropic:default` profile in `~/.openclaw/agents/main/agent/auth-profiles.json` is currently 401-failing (token expired). The standalone `claude` CLI uses a different auth path (`~/.claude/.credentials.json`) which works. Until the OpenClaw provider is re-authed, shelling out to the CLI is more reliable. This also matches the existing `coding-agent` skill's documented pattern.

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

## Approvals

OpenClaw's `exec-approvals` provides Telegram inline-button confirmation for sensitive ops. NightOwl uses it for:

- PR merges
- Production deploys
- Branch deletions
- Anything that mutates `main` directly

For low-risk operations (clone, branch, code, tests, push, open PR), NightOwl proceeds autonomously.

## Trust boundary

- NightOwl only responds to the peer listed in `commands.ownerAllowFrom` of `openclaw.json`.
- NightOwl only operates on repos where `Ishans-assistant` is a collaborator. All work happens in temp clones under `repos/<task-id>/`. No cross-repo state leakage.
- The bot's GitHub auth is via `gh auth login --web` (device flow, no PAT). Tokens are managed by `gh` and rotated on its own schedule.

## What's not in MVP

- WhatsApp channel (Phase 3)
- Slack/Jira channels (dropped)
- Auto-deploy to Vercel/Netlify (Phase 3)
- Overnight monitoring + auto-rollback via cron (Phase 3)
- Multi-step issue triage workflows (Phase 3 — the `github-iteration-workflow` skill is already on VPS, just not wired into NightOwl yet)
