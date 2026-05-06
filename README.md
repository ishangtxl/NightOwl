# NightOwl

> An autonomous off-hours developer agent built on [OpenClaw](https://openclaw.ai). Talk to it on Telegram — text or voice — and arrive home to a finished PR.

**OpenClaw Hackathon submission — Theme 3: Productivity Platforms.**

## The idea

Even with AI coding assistants, real engineering work still stops when you step away from the keyboard. Compile times, code reviews, deploys, and night-time incidents all sit in the queue until a human is back at a desk.

NightOwl is an OpenClaw-native agent that turns your phone into that desk. Send it a Telegram message — "add a dark-mode toggle to the settings page", or a voice note — and it plans the work, writes the code, runs tests, and opens a pull request from its own GitHub account. By the time you next look at GitHub, the PR is already there waiting for review.

```
You (Telegram):
  add a "Built by NightOwl 🦉" footer to index.html in
  Ishans-assistant/nightowl-demo

NightOwl:
  On it. Cloning Ishans-assistant/nightowl-demo, will report back with PR.

NightOwl (~30s later):
  ✅ Added Built by NightOwl 🦉 footer.
  📦 https://github.com/Ishans-assistant/nightowl-demo/pull/1
  🧪 tests: static HTML check passed; no automated suite present
  ⏳ awaiting your review, no auto-merge
```

That exchange is verbatim from the first end-to-end run.

## Why it's OpenClaw-native

The interesting design choice is what NightOwl doesn't build. OpenClaw already provides messaging channels, agent isolation, skills, memory, approvals, and a scheduler. NightOwl is a deliberately thin layer on top:

| Layer | Provided by |
|---|---|
| Telegram input (text + voice) | OpenClaw `telegram` channel plugin |
| Voice → text | Existing `transcribe-audio` wrapper (Azure Whisper, local fallback) |
| Agent isolation, routing, identity | OpenClaw `agents` + per-agent workspace |
| Memory across sessions | OpenClaw `MEMORY.md` + `memory/YYYY-MM-DD.md` |
| Approvals for risky ops | OpenClaw `exec-approvals` |
| Code generation | Standalone `claude` CLI (`claude-opus-4-5`) via the existing `claude-code-opus45` wrapper |
| Repo operations | `gh` CLI authenticated as a dedicated bot account |
| **NightOwl's contribution** | One persona (IDENTITY/SOUL/USER/AGENTS/TOOLS) + three orchestration skills |

The whole submission is roughly 800 lines of markdown — three skill files and the agent's identity. Everything else is composition. That's the point: OpenClaw makes "an autonomous developer colleague" a configuration, not a project.

See [`docs/architecture.md`](docs/architecture.md) for the full diagram and rationale.

## What it does today

The MVP supports three intent types:

| Intent | Skill | What happens |
|---|---|---|
| Implement / fix / change | [`nightowl-feature-flow`](skills/nightowl-feature-flow/SKILL.md) | Clones the target repo, branches, edits (delegating non-trivial code to Claude Code), runs tests, pushes, opens a PR, replies with the URL |
| Review a PR | [`nightowl-pr-review`](skills/nightowl-pr-review/SKILL.md) | Checks out the PR in a sandbox, asks Claude Code for a structured review, posts line comments and a verdict |
| Security audit | [`nightowl-security-review`](skills/nightowl-security-review/SKILL.md) | Scans the repo or PR for the OWASP-style top categories, posts findings as a GitHub issue or PR comment |

All three are read-mostly. NightOwl never merges, force-pushes, or deploys without explicit human approval routed through OpenClaw's exec-approvals.

## Repo layout

```
agents/nightowl/        Agent persona — IDENTITY, SOUL, USER, AGENTS, TOOLS, HEARTBEAT, MEMORY
skills/                 The three orchestration skills, synced to the agent's per-workspace skills/
scripts/sync-to-vps.sh  Idempotent rsync from this repo to the VPS workspace
docs/                   Architecture, setup guide, and demo script
```

## Trying it yourself

Full provisioning steps in [`docs/setup.md`](docs/setup.md). The short version:

1. **VPS prerequisites:** OpenClaw 2026.5+, `claude` Code CLI logged in, `gh` CLI installed.
2. **Create a dedicated GitHub account** for the bot (NightOwl uses `@Ishans-assistant`). Authenticate `gh` as that account on the VPS.
3. **Create a dedicated Telegram bot** via [@BotFather](https://t.me/BotFather). NightOwl needs its own bot — sharing one with another OpenClaw agent will collide on routing.
4. **Add the agent and bind the bot:**
   ```bash
   openclaw agents add nightowl \
     --workspace /root/.openclaw/workspace/nightowl \
     --model microsoft-foundry/gpt-5.5 \
     --non-interactive

   openclaw channels add --channel telegram --account nightowl \
     --token "<your-bot-token>" --name "NightOwl"

   openclaw agents bind --agent nightowl --bind telegram:nightowl
   openclaw daemon restart
   ```
5. **Sync the persona and skills from this repo:**
   ```bash
   ./scripts/sync-to-vps.sh
   ```
6. **DM the bot on Telegram.** See [`docs/demo-script.md`](docs/demo-script.md) for the smoke test sequence.

## Status

Phase 2 MVP (2026-05-08):

- [x] `nightowl` agent isolated with its own workspace, identity, and routing
- [x] Dedicated Telegram bot, owner-allowlisted
- [x] Feature-flow skill verified end-to-end on a live demo repo (PR #1)
- [x] Reviews and security passes wired and ready
- [ ] Voice input verified end-to-end (Phase 3 — the wrapper exists, just needs a voice-note flow test)

Phase 3 (2026-05-09 to 2026-05-19):

- Overnight monitoring + auto-rollback skill (uses `openclaw cron` + Sentry/Grafana)
- Vercel deploy skill behind exec-approval
- WhatsApp channel via Baileys
- Demo video

## License

MIT — see [`LICENSE`](LICENSE).
