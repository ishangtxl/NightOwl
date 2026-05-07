# NightOwl

> An autonomous off-hours developer agent built on [OpenClaw](https://openclaw.ai). Talk to it on Telegram — text or voice — or just drag a Linear / GitHub ticket into Todo and walk away. Either way, you arrive home to a finished PR.

**OpenClaw Hackathon submission — Theme 3: Productivity Platforms.**

## The idea

Even with AI coding assistants, real engineering work still stops when you step away from the keyboard. Compile times, code reviews, deploys, and night-time incidents all sit in the queue until a human is back at a desk.

NightOwl gives you two ways to delegate. **On the go**, send it a Telegram message — *"add a dark-mode toggle to the settings page"* — or a voice note. **At work**, label a Linear ticket `nightowl` (or assign a GitHub issue to it) and forget about it. Either path runs the same skill library underneath: plan, write the code, run tests, push from its own GitHub account, open a PR, and post the URL back to the ticket or chat.

By the time you next look at GitHub, the PR is already there waiting for review.

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

Two input channels, one shared skill library.

**Telegram** (text or voice — for delegating on the go):

| Intent | Skill | What happens |
|---|---|---|
| Implement / fix / change | [`nightowl-feature-flow`](skills/nightowl-feature-flow/SKILL.md) | Clones the target repo, branches, edits (delegating non-trivial code to Claude Code), runs tests, pushes, opens a PR, replies with the URL |
| Review a PR | [`nightowl-pr-review`](skills/nightowl-pr-review/SKILL.md) | Checks out the PR in a sandbox, asks Claude Code for a structured review, posts line comments and a verdict |
| Security audit | [`nightowl-security-review`](skills/nightowl-security-review/SKILL.md) | Scans the repo or PR for the OWASP-style top categories, posts findings as a GitHub issue or PR comment |

**Board watcher** (Linear + GitHub Issues — for delegating during work hours):

A systemd timer fires NightOwl's [board watcher](docs/board-watcher-design.md) every 30 seconds. It polls every configured tracker for tickets labelled `nightowl` (or assigned to the bot on GitHub) and ships them as PRs autonomously, up to a configurable concurrency cap. Each repo controls behaviour through a [`WORKFLOW.md`](docs/workflow-md.md) at its root — install/test/lint/build commands, deploy provider, PR settings, prompt template. The watcher posts `🦉 Implementing…` and `🦉 ✅ PR opened: …` updates back to the ticket as it works.

```
You (Linear):  drag ticket "Add password reset endpoint" into Todo, label `nightowl`
NightOwl:      🦉 Claimed by NightOwl. Cloning ishangtxl/<repo>...
NightOwl:      🦉 Implementing on branch ish-12-add-password-reset-endpoint — ETA ~2-4 min.
NightOwl:      🦉 ✅ PR opened: https://github.com/.../pull/47
                ✅ build: pass — lint: skipped — test: skipped
                ⏳ Awaiting review
```

That sequence is verbatim from the smoke test (a slightly less ambitious ticket, but the same flow end-to-end).

All skills are read-mostly. NightOwl never merges, force-pushes, or deploys to production without explicit human approval routed through OpenClaw's exec-approvals.

## Repo layout

```
agents/nightowl/        Agent persona — IDENTITY, SOUL, USER, AGENTS, TOOLS, HEARTBEAT, MEMORY
                        + board-watcher.config.yaml listing managed trackers
skills/                 Per-skill markdown — synced to the agent's per-workspace skills/
bin/                    Shell scripts run by the watcher, not the agent:
  nightowl-board-watcher  systemd-fired tick — finds eligible issues
  nightowl-issue-runner   per-issue executor — clone, branch, claude, push, PR
  adapters/{linear,github-issues}  pluggable BoardAdapter implementations
examples/WORKFLOW.md    Annotated example for adopting NightOwl in your own repo
scripts/sync-to-vps.sh  Idempotent rsync from this repo to the VPS workspace
docs/                   Architecture, setup guide, board-watcher design, demo script
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

Phase 2 MVP — Telegram (2026-05-07):

- [x] `nightowl` agent isolated with its own workspace, identity, and routing
- [x] Dedicated Telegram bot, owner-allowlisted
- [x] Feature-flow skill verified end-to-end on a live demo repo
- [x] Reviews and security passes wired and ready
- [ ] Voice input verified end-to-end (the wrapper exists, just needs a voice-note flow test)

Phase 2.5 — Board watcher (2026-05-08):

- [x] Pluggable `BoardAdapter` protocol with Linear + GitHub Issues adapters
- [x] Per-repo `WORKFLOW.md` schema for install/test/lint/build/deploy config
- [x] Per-issue runner: clone → branch → Claude Code → push → PR → comment back
- [x] Bounded concurrency (cap 2 by default), tick lock, label-based claim/release, restart recovery
- [x] systemd timer driving 30-second polling on the VPS
- [x] Verified end-to-end: two parallel Linear tickets shipped as two PRs autonomously

Phase 3 — Multi-agent orchestration + deploy (planned):

- `nightowl-orchestrate` skill — replaces the single-Claude-Code call inside the per-issue runner with parallel role-specialists (🎨 Designer, 🛠 Backend, 🧪 QA, 🚀 Deploy). Each posts its own update back to the ticket.
- `nightowl-deploy` — Vercel preview on every PR; production deploys behind exec-approval.
- `nightowl-monitor` — post-deploy auto-rollback on Sentry / Vercel error rate spikes.
- Demo video.

## License

MIT — see [`LICENSE`](LICENSE).
