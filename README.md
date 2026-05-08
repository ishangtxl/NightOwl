# NightOwl

> An autonomous off-hours developer agent built on [OpenClaw](https://openclaw.ai). Talk to it on Telegram — text or voice — or just label a Linear ticket `nightowl` and walk away. Either way, you arrive home to a finished pull request.

**OpenClaw Hackathon submission — Theme 3: Productivity Platforms.**

---

## Problem

Even with AI coding assistants, real engineering work still stops when you step away from the keyboard. Compile times, code reviews, deploys, and night-time incidents all sit in the queue until a human is back at a desk. AI coding tools amplify what you can do *while sitting at the laptop*; they don't extend your reach beyond it.

The gap is a lack of *delegation surface*. There's no easy way to hand a small task to an autonomous agent and trust that, by the time you're back, the work is done in a form you can review — a pull request, with tests run and a link back to wherever the task originated.

## Solution

NightOwl gives you two ways to delegate, both running the same skill library underneath.

**On the go** — send NightOwl a Telegram message or voice note. *"Add a `/api/version` endpoint to DyslexiAid that returns the package version."* It plans the work, writes the code, runs quality gates, opens a pull request from its own GitHub identity, and replies on Telegram with the URL.

**During work hours** — drag a Linear ticket into Todo, label it `nightowl`, and forget about it. Within 30 seconds NightOwl claims the ticket, posts a status comment, and starts working. A few minutes later there's a PR linked back to the ticket, with quality-gate output and a link to the Vercel preview.

By the time you next look at GitHub, the PR is already there waiting for review.

```
You (Linear):
  Drag ticket "ISH-12: Add password reset endpoint" into Todo, label `nightowl`

NightOwl (~5 sec):
  🦉 Claimed by NightOwl. Cloning ishangtxl/<repo>...

NightOwl (~10 sec):
  🦉 Implementing on branch ish-12-add-password-reset-endpoint — ETA ~2-4 min.

NightOwl (~3 min):
  🦉 ✅ PR opened: https://github.com/.../pull/47
  ✅ build: pass — lint: skipped — test: skipped
  ⏳ Awaiting review
```

The same loop runs from Telegram, with the bot's response landing in your DM instead of the ticket.

---

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
| **NightOwl's contribution** | One persona (IDENTITY/SOUL/USER/AGENTS/TOOLS), four orchestration skills, two BoardAdapters, a per-issue runner, and a systemd-driven watcher loop |

NightOwl's contribution lives in plain-text markdown and small Python scripts — no compiled artifacts, no daemons of its own. Drop the agent files into a fresh OpenClaw VPS, install the systemd timer, and you have an autonomous engineer that never gets tired.

See [`docs/architecture.md`](docs/architecture.md) for the full diagram and rationale.

---

## What it does today

### Telegram — for delegating on the go

| Intent | Skill | What happens |
|---|---|---|
| Implement / fix / change | [`nightowl-feature-flow`](skills/nightowl-feature-flow/SKILL.md) | Clones the target repo, branches, edits (delegating non-trivial code to Claude Code), runs quality gates, pushes, opens a PR, replies with the URL |
| Review a PR | [`nightowl-pr-review`](skills/nightowl-pr-review/SKILL.md) | Checks out the PR in a sandbox, asks Claude Code for a structured review, posts line comments and a verdict |
| Security audit | [`nightowl-security-review`](skills/nightowl-security-review/SKILL.md) | Scans the repo or PR for OWASP-style top categories, posts findings as a GitHub issue or PR comment |

### Board watcher — for delegating during work hours

A systemd timer fires `bin/nightowl-board-watcher` every 30 seconds. It polls each configured tracker (Linear, GitHub Issues — pluggable via the `BoardAdapter` protocol) for tickets that match the eligibility filter (label `nightowl`, or assigned to the bot on GitHub) and dispatches up to `max_concurrent_runs` per-issue runners in parallel. Each runner clones the repo, branches as `<ticket-key>-<slug>`, runs Claude Code per the target repo's [`WORKFLOW.md`](docs/workflow-md.md), executes quality gates, pushes, opens a PR with `Closes <ticket-key>`, and posts the URL back to the ticket.

The eligibility filter is intentionally narrow: tickets must be explicitly opted-in via label, so NightOwl never picks up your entire backlog by accident. Bounded global concurrency, label-based claim/release, and lock files keep the loop safe even across daemon restarts.

### Safety properties

All skills are read-mostly. NightOwl never merges, force-pushes, or deploys to production without explicit human approval routed through OpenClaw's exec-approvals. PRs that fail their quality gates are opened as drafts with the test output in the description, so a failed run never silently retries — it asks a human.

---

## Repo layout

```
agents/nightowl/        Agent persona — IDENTITY, SOUL, USER, AGENTS, TOOLS, HEARTBEAT, MEMORY
                        + board-watcher.config.yaml listing managed trackers
skills/                 Per-skill markdown synced to the agent's per-workspace skills/
bin/                    Runtime executables (not invoked by the agent — invoked by cron):
  nightowl-board-watcher  systemd-fired tick — finds eligible issues, dispatches runners
  nightowl-issue-runner   per-issue executor — clone, branch, claude, push, PR
  adapters/{linear,github-issues}  pluggable BoardAdapter implementations
examples/WORKFLOW.md    Annotated example for adopting NightOwl in your own repo
scripts/sync-to-vps.sh  Idempotent rsync from this repo to the VPS workspace
docs/                   Architecture, setup, board-watcher design
```

---

## Reproducing locally

Full provisioning steps in [`docs/setup.md`](docs/setup.md). The short version:

1. **VPS prerequisites** — OpenClaw 2026.5+, `claude` Code CLI logged in, `gh` CLI installed.
2. **Create a dedicated GitHub account** for the bot (NightOwl uses `@Ishans-assistant`). Authenticate `gh` as that account on the VPS.
3. **Create a dedicated Telegram bot** via [@BotFather](https://t.me/BotFather). NightOwl needs its own bot — sharing one with another OpenClaw agent will collide on routing.
4. **Add the agent and bind the bot:**
   ```bash
   openclaw agents add nightowl \
     --workspace /root/.openclaw/workspace/nightowl \
     --model microsoft-foundry/gpt-5.5 --non-interactive

   openclaw channels add --channel telegram --account nightowl \
     --token "<your-bot-token>" --name "NightOwl"

   openclaw agents bind --agent nightowl --bind telegram:nightowl
   openclaw daemon restart
   ```
5. **Sync the persona, skills, and bin scripts:**
   ```bash
   ./scripts/sync-to-vps.sh
   ```
6. **DM the bot on Telegram** — that's the Telegram path, ready to use.
7. **(Optional) Enable the board watcher** — see [`docs/setup.md`](docs/setup.md#optional-enable-the-board-watcher) for the systemd timer + Linear API key + per-repo `WORKFLOW.md` setup.

---

## Status

**Verified end-to-end:**

- [x] Telegram `nightowl-feature-flow` — text input, real PR opened against a real repo
- [x] Linear board watcher loop — ticket → claim → implement → push → PR → comment back, with autonomous concurrency cap
- [x] GitHub Issues `BoardAdapter` — list verified; write paths use the same shared lifecycle-label vocabulary as Linear
- [x] systemd-driven 30-second polling on the VPS
- [x] Quality gates honoured per-repo (`WORKFLOW.md`)
- [x] CI workflow added to demo target so NightOwl PRs get a green check before review

**Wired but not exercised end-to-end on demo day yet:**

- [ ] Telegram voice input (transcribe wrapper exists; needs a live voice-note flow test)
- [ ] `nightowl-pr-review` end-to-end via Telegram
- [ ] `nightowl-security-review` end-to-end via Telegram

These are covered in the test plan and will be exercised before the demo recording.

---

## Roadmap beyond submission

These are intentionally out of scope for the submission — the loop above is what's built and verified. Listed here for completeness:

- **Multi-agent orchestration** — replace the single Claude Code call inside the per-issue runner with parallel role-specialists (Designer / Backend / QA), each posting its own update to the ticket.
- **`nightowl-deploy`** — Vercel preview on every PR; production deploys gated on Telegram approval.
- **`nightowl-monitor`** — post-deploy auto-rollback on Sentry / Vercel error rate spikes.
- **WhatsApp adapter** — second messaging channel via Baileys.

---

## License

MIT — see [`LICENSE`](LICENSE).
