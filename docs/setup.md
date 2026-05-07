# Setup

This document covers provisioning NightOwl on a fresh VPS or re-provisioning if you blow it away.

## Prerequisites

A VPS with:
- OpenClaw 2026.5+ installed (`openclaw --version`)
- `claude` CLI installed and logged in (`claude` Code CLI, separate from OpenClaw's anthropic provider)
- `gh` CLI installed
- `node`, `python3`, `docker` (for sandboxed builds)
- An Azure transcribe deployment (optional — for voice; falls back to local Whisper)

## One-time VPS configuration

### 1. Authenticate the GitHub bot account

```bash
gh auth login --hostname github.com --web --git-protocol https --scopes "repo,workflow,read:org"
```

When prompted, log in as the bot account (`Ishans-assistant` for this project). Verify:

```bash
gh auth status
gh api user --jq .login
```

The output should show the bot account name.

### 2. Confirm the orchestrator model is reachable

NightOwl's orchestrator uses `microsoft-foundry/gpt-5.5`. Verify:

```bash
openclaw channels list
```

The "Usage" block should show no errors for `microsoft-foundry`. (The `Claude: HTTP 401` line is fine — NightOwl doesn't use that path.)

### 3. Confirm Claude Code CLI auth

```bash
claude --version
ls -la ~/.claude/.credentials.json
```

If credentials are missing, run `claude` once interactively to log in.

### 4. (Optional) Configure Azure transcribe for voice

Voice notes will fall back to local Whisper if Azure isn't configured. If you want Azure (faster, more accurate):

```bash
cat > /root/.openclaw/workspace/.secrets/azure-transcribe.env <<'EOF'
AZURE_TRANSCRIBE_ENDPOINT=https://<your-azure-endpoint>/openai/v1/audio/transcriptions
AZURE_TRANSCRIBE_MODEL=whisper-1
AZURE_API_KEY=<your-azure-key>
EOF
chmod 600 /root/.openclaw/workspace/.secrets/azure-transcribe.env
```

The `bin/transcribe-audio` wrapper picks this up automatically.

## Create a dedicated Telegram bot for NightOwl

NightOwl needs its own Telegram bot, separate from any other OpenClaw agents you have on the same VPS. Otherwise message routing collides — both agents poll the same bot.

1. On Telegram, DM [@BotFather](https://t.me/BotFather).
2. Send `/newbot`, pick a name and username (must end in `bot`).
3. Save the bot token BotFather replies with.
4. Optional polish: `/setdescription`, `/setuserpic`, `/setname`.

## Create the NightOwl agent

```bash
openclaw agents add nightowl \
  --workspace /root/.openclaw/workspace/nightowl \
  --model microsoft-foundry/gpt-5.5 \
  --non-interactive
```

## Register the bot and bind it

```bash
# Register the bot account
openclaw channels add --channel telegram --account nightowl \
  --token "<your-bot-token>" --name "NightOwl"

# Route the new bot to the nightowl agent
openclaw agents bind --agent nightowl --bind telegram:nightowl
```

Verify:
```bash
openclaw agents list             # both agents shown, nightowl with 1 routing rule
openclaw agents bindings         # nightowl <- telegram accountId=nightowl
openclaw channels status --probe # nightowl bot connected, polling
```

## Restart the gateway

Bindings registered while the gateway is running are not always picked up live. Restart so the routing table is reloaded:

```bash
openclaw daemon restart
```

## Sync the agent files from this repo

From your local checkout:

```bash
./scripts/sync-to-vps.sh
```

This pushes:
- `agents/nightowl/{IDENTITY,SOUL,USER,AGENTS,TOOLS,HEARTBEAT,MEMORY}.md` → `~/.openclaw/workspace/nightowl/`
- `skills/*` → `~/.openclaw/workspace/nightowl/skills/`
- Symlinks shared wrappers from `~/.openclaw/workspace/bin/` into NightOwl's `bin/`

Re-run any time you change agent files or skills locally.

## Set the agent's identity in OpenClaw's registry

```bash
openclaw agents set-identity \
  --agent nightowl \
  --workspace /root/.openclaw/workspace/nightowl \
  --from-identity
```

This reads the synced `IDENTITY.md` and registers name/emoji.

## Add the bot as collaborator on the demo repo

```bash
gh api -X PUT repos/<your-username>/<demo-repo>/collaborators/Ishans-assistant \
  -f permission=push
```

`Ishans-assistant` will receive an invitation. Run the next step from THAT account:

```bash
# As Ishans-assistant (the VPS gh session is logged in as this user)
gh api user/repository_invitations --jq '.[].id' | xargs -I{} gh api -X PATCH user/repository_invitations/{}
```

Verify push access:

```bash
gh repo clone <your-username>/<demo-repo> /tmp/test-clone
cd /tmp/test-clone
git push origin --dry-run HEAD
```

## Confirm the owner allowlist

NightOwl will only respond to the Telegram peer listed in `commands.ownerAllowFrom` of `~/.openclaw/openclaw.json`. If you've already configured OpenClaw, this is set. Otherwise, find your peer ID via `openclaw directory self --channel telegram` and add it.

## Smoke test

DM the NightOwl Telegram bot from the authorized peer. Try in order:

1. `hi` — short ack, no action.
2. `add a "Built by NightOwl 🦉" footer to the index.html in <owner>/<demo-repo>` — clones, branches, pushes, opens a PR.
3. `review <PR URL>` — posts review comments on the PR.
4. `security pass on <owner>/<demo-repo>` — runs a security review.

If any step hangs or fails, check `~/.openclaw/logs/` or `journalctl --user -u openclaw-gateway -n 200` (the daemon runs as a systemd user service).

## Updating

The sync script defaults to SSH host `nightowl-vps`. Either add a matching entry to your `~/.ssh/config` or override with an env var:

```bash
NIGHTOWL_SSH_HOST=my-other-host ./scripts/sync-to-vps.sh
```

Whenever you change agent files or skills locally:

```bash
./scripts/sync-to-vps.sh
ssh nightowl-vps 'openclaw agents list'   # confirm nothing got broken
```

For a full restart of OpenClaw on the VPS (rare):

```bash
ssh nightowl-vps 'openclaw daemon restart'
```

## (Optional) Enable the board watcher

The Telegram flow above is enough for the MVP. To also let NightOwl pick up tickets from Linear or GitHub Issues autonomously, set up the board watcher.

### 1. Configure trackers

Edit `agents/nightowl/board-watcher.config.yaml` in this repo to list every tracker NightOwl should poll. The committed example wires both a Linear team and a GitHub Issues repo. Adjust to your team key and repo, then re-sync:

```bash
./scripts/sync-to-vps.sh
```

### 2. Add Linear API key (if using Linear)

```bash
ssh nightowl-vps "mkdir -p /root/.openclaw/workspace/.secrets && \
  cat > /root/.openclaw/workspace/.secrets/linear.env <<EOF
LINEAR_API_KEY=<your-linear-personal-api-key>
LINEAR_API_ENDPOINT=https://api.linear.app/graphql
EOF
chmod 600 /root/.openclaw/workspace/.secrets/linear.env"
```

Get a key at https://linear.app/settings/api. The watcher uses it for both reads and writes (listing tickets, posting comments, transitioning labels).

### 3. Add a `WORKFLOW.md` to each target repo

Each repo NightOwl operates on needs a `WORKFLOW.md` at its root. Copy [`examples/WORKFLOW.md`](../examples/WORKFLOW.md) and tune the install / test / lint / build commands for your stack. See [`docs/workflow-md.md`](workflow-md.md) for the full schema.

### 4. Verify before scheduling

```bash
ssh nightowl-vps '/root/.openclaw/workspace/nightowl/bin/nightowl-board-watcher --dry-run'
```

You should see a list of eligible tickets per tracker. Nothing dispatches in `--dry-run`.

### 5. Install the systemd timer

```bash
ssh nightowl-vps "cat > /etc/systemd/system/nightowl-board-watcher.service <<EOF
[Unit]
Description=NightOwl board watcher tick
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/root/.openclaw/workspace/nightowl/bin/nightowl-board-watcher
StandardOutput=append:/var/log/nightowl-watcher.log
StandardError=append:/var/log/nightowl-watcher.log
TimeoutStartSec=120
EOF
cat > /etc/systemd/system/nightowl-board-watcher.timer <<EOF
[Unit]
Description=NightOwl board watcher every 30s

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now nightowl-board-watcher.timer"
```

Verify it's ticking:

```bash
ssh nightowl-vps 'systemctl list-timers nightowl-board-watcher.timer --no-pager'
ssh nightowl-vps 'tail -f /var/log/nightowl-watcher.log'
```

### Operational handles

```bash
# Status
systemctl status nightowl-board-watcher.timer

# Pause (no autonomous activity until resumed)
systemctl stop nightowl-board-watcher.timer

# Resume
systemctl start nightowl-board-watcher.timer

# One-shot manual run
/root/.openclaw/workspace/nightowl/bin/nightowl-board-watcher
```

### Driving it

Once the timer is running, drag any Linear ticket into Todo (or any state in `active_states`), add the `nightowl` label, and the next 30-second tick picks it up. Track progress in the ticket's comment thread. The PR appears in the configured target repo with `Closes <ticket-key>` so Linear's GitHub integration auto-links.
