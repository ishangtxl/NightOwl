#!/usr/bin/env bash
# Sync NightOwl agent files + skills from this repo to the VPS workspace.
# Idempotent. Safe to re-run. Does NOT touch other agents' workspaces.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_HOST="${NIGHTOWL_SSH_HOST:-nightowl-vps}"
REMOTE_WORKSPACE="${NIGHTOWL_REMOTE_WORKSPACE:-/root/.openclaw/workspace/nightowl}"

echo "==> NightOwl sync"
echo "    repo:      $REPO_ROOT"
echo "    ssh host:  $SSH_HOST"
echo "    remote ws: $REMOTE_WORKSPACE"

# Sanity: ensure the remote workspace dir exists. If not, the agent hasn't been
# created yet — bail with instructions.
if ! ssh "$SSH_HOST" "test -d $REMOTE_WORKSPACE" 2>/dev/null; then
  cat <<EOF >&2

Remote workspace $REMOTE_WORKSPACE does not exist.

Create the agent first:

  ssh $SSH_HOST 'openclaw agents add nightowl \\
    --workspace $REMOTE_WORKSPACE \\
    --model microsoft-foundry/gpt-5.5 \\
    --non-interactive'

Then add the dedicated NightOwl Telegram bot account and bind it:

  ssh $SSH_HOST 'openclaw channels add --channel telegram --account nightowl \\
    --token <BOT_TOKEN_FROM_BOTFATHER> --name "NightOwl"'
  ssh $SSH_HOST 'openclaw agents bind --agent nightowl --bind telegram:nightowl'

Then re-run this script.
EOF
  exit 1
fi

# 1. Sync agent identity files (IDENTITY/SOUL/USER/AGENTS/TOOLS/HEARTBEAT/MEMORY).
#    These go directly into the workspace root. We do NOT use --delete-excluded
#    because the workspace contains other files OpenClaw manages (BOOTSTRAP.md,
#    memory/, .git/, .openclaw/, repos/, etc.) that we must not touch.
echo "==> sync agent files"
rsync -av \
  --include='IDENTITY.md' \
  --include='SOUL.md' \
  --include='USER.md' \
  --include='AGENTS.md' \
  --include='TOOLS.md' \
  --include='HEARTBEAT.md' \
  --include='MEMORY.md' \
  --include='board-watcher.config.yaml' \
  --exclude='*' \
  "$REPO_ROOT/agents/nightowl/" "$SSH_HOST:$REMOTE_WORKSPACE/"
ssh "$SSH_HOST" "chown -R root:root $REMOTE_WORKSPACE/IDENTITY.md $REMOTE_WORKSPACE/SOUL.md $REMOTE_WORKSPACE/USER.md $REMOTE_WORKSPACE/AGENTS.md $REMOTE_WORKSPACE/TOOLS.md $REMOTE_WORKSPACE/HEARTBEAT.md $REMOTE_WORKSPACE/MEMORY.md $REMOTE_WORKSPACE/board-watcher.config.yaml 2>/dev/null || true"

# 2. Sync skills into the per-agent skills dir. --delete IS safe here because
#    skills/ is owned entirely by this repo.
echo "==> sync skills"
ssh "$SSH_HOST" "mkdir -p $REMOTE_WORKSPACE/skills"
rsync -av --delete \
  "$REPO_ROOT/skills/" "$SSH_HOST:$REMOTE_WORKSPACE/skills/"
ssh "$SSH_HOST" "chown -R root:root $REMOTE_WORKSPACE/skills 2>/dev/null || true"

# 2b. Sync NightOwl-owned bin scripts (board watcher, adapters). These are
#     separate from the shared bins — they implement NightOwl-specific logic.
if [[ -d "$REPO_ROOT/bin" ]]; then
  echo "==> sync nightowl bin"
  ssh "$SSH_HOST" "mkdir -p $REMOTE_WORKSPACE/bin/adapters"
  rsync -av \
    --include='*/' \
    --include='nightowl-*' \
    --include='adapters/*' \
    --exclude='*' \
    "$REPO_ROOT/bin/" "$SSH_HOST:$REMOTE_WORKSPACE/bin/"
  ssh "$SSH_HOST" "chmod +x $REMOTE_WORKSPACE/bin/nightowl-* $REMOTE_WORKSPACE/bin/adapters/* 2>/dev/null || true"
  ssh "$SSH_HOST" "chown -R root:root $REMOTE_WORKSPACE/bin 2>/dev/null || true"
fi

# 3. Symlink shared wrappers from the main workspace into NightOwl's bin.
#    These wrappers live at /root/.openclaw/workspace/bin and are stable.
echo "==> link shared bins"
ssh "$SSH_HOST" "bash -s" <<'REMOTE'
set -euo pipefail
WS="/root/.openclaw/workspace/nightowl"
SHARED_BIN="/root/.openclaw/workspace/bin"
mkdir -p "$WS/bin"
for tool in claude-code-opus45 transcribe-audio transcribe-local-whisper transcribe-audio-azure browser-harness-vps start-browser-harness-chrome; do
  src="$SHARED_BIN/$tool"
  dst="$WS/bin/$tool"
  if [[ -e "$src" ]]; then
    ln -sf "$src" "$dst"
  fi
done
echo "linked: $(ls -1 $WS/bin)"
REMOTE

# 4. Make sure repos/ scratch dir exists.
ssh "$SSH_HOST" "mkdir -p $REMOTE_WORKSPACE/repos $REMOTE_WORKSPACE/memory"

echo "==> done"
echo "Verify with:"
echo "  ssh $SSH_HOST 'openclaw agents list'"
echo "  ssh $SSH_HOST 'ls $REMOTE_WORKSPACE'"
