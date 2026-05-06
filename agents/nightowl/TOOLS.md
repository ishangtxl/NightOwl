# TOOLS.md - NightOwl's Local Setup

Tool paths and environment-specific notes for this VPS. Skills tell you HOW; this file tells you WHERE.

## Coding agent (Claude Code)

- **Wrapper:** `/root/.openclaw/workspace/bin/claude-code-opus45`
- **Pinned model:** `claude-opus-4-5`
- **Auth:** Already logged in via the Claude Code CLI (uses `~/.claude/.credentials.json`). Do **not** rely on the OpenClaw `anthropic:default` provider — its token is broken.
- **Print mode invocation:**
  ```bash
  claude-code-opus45 --permission-mode bypassPermissions --print '<prompt>'
  ```
- Always run inside the per-task repo clone. `cd ~/.openclaw/workspace/nightowl/repos/<task-id>/<repo>` first.

## STT (voice notes)

- **Wrapper:** `/root/.openclaw/workspace/bin/transcribe-audio`
- **Path:** Azure first (uses `~/.openclaw/workspace/.secrets/azure-transcribe.env`), falls back to local Whisper `base` model.
- Output: plain transcript on stdout. Pipe directly into intent classification.

## GitHub

- **CLI:** `gh` (already on `$PATH`)
- **Identity:** `Ishans-assistant` (logged in via `gh auth login --web`)
- **Pattern:** Always check `gh auth status` before a flow that needs auth. If logged out, post Telegram message: "Need re-auth. Tell Ishan to run `gh auth login --web` on the VPS."
- **Repos must have `Ishans-assistant` as a collaborator** before NightOwl can push.

## Browser (when needed)

- **Wrapper:** `/root/.openclaw/workspace/bin/browser-harness-vps` (CDP at `127.0.0.1:9222`)
- Use only for tasks that genuinely need browser automation (e.g., scraping a docs page, verifying a deploy URL renders).

## Telegram

- **Bot:** A dedicated NightOwl Telegram bot (separate from any other agent bots), registered as a second account via `openclaw channels add --channel telegram --account nightowl ...`.
- **Routing:** NightOwl receives messages bound via `openclaw agents bind --agent nightowl --bind telegram:nightowl`. The owner allowlist in `~/.openclaw/openclaw.json` (`commands.ownerAllowFrom`) restricts which peer the bot will respond to.
- Do not reply to non-allowlisted senders.

## Orchestrator model

- **Primary:** `microsoft-foundry/gpt-5.5` (the same model the `main` agent uses).
- This is the model that runs YOU — the model that decides which skill to invoke. It is **not** the model that writes code. Code is delegated to Claude Code.

## Approvals

- Tool: OpenClaw `exec-approvals.json` socket (already provisioned, see `~/.openclaw/exec-approvals.json`).
- Use for: PR merges, any deploy, branch deletions, anything that mutates `main` directly.

## Repo clone pattern

```bash
TASK_ID="$(date +%Y-%m-%d)-<short-slug>"
WORK="$HOME/.openclaw/workspace/nightowl/repos/$TASK_ID"
mkdir -p "$WORK"
cd "$WORK"
gh repo clone <owner>/<repo>
cd <repo>
git checkout -b <branch>
```

## Cleanup

Stale clones in `repos/` older than 7 days can be `trash`ed during a heartbeat.
