---
name: nightowl-feature-flow
description: |
  End-to-end implementation of a feature request from Telegram to PR. Use when the
  user asks NightOwl to ADD, IMPLEMENT, BUILD, FIX, or CHANGE something in a repo.
  Covers: clone → branch → delegate to Claude Code → run tests → push → open PR → reply.
metadata:
  openclaw:
    emoji: "🦉"
    requires:
      anyBins: ["claude", "gh"]
---

# NightOwl Feature Flow

Top-level flow when Ishan says "add X" or "fix Y" in a repo.

## When to use

- Any imperative work request that mutates code: add, implement, build, refactor, fix, change, port, migrate.
- Issue triage: "look at issue #42 and fix it."

## When NOT to use

- "Review PR 47" → use `nightowl-pr-review`.
- "Audit auth flow" / "security pass" → use `nightowl-security-review`.
- "What's the status of X" → answer directly, no skill.

## Inputs needed

Before doing anything, you need:

1. **Repo** — `owner/repo`. If Ishan didn't say one, ask.
2. **Scope** — what specifically. If the message is vague ("make it nicer"), ask one clarifying question.
3. **Branch base** — usually `main`. Don't assume; check `gh repo view <owner>/<repo> --json defaultBranchRef`.

If you have to ask, ask ONCE. Don't re-prompt.

## Flow

### 1. Acknowledge (Telegram)

Send one short ack so Ishan knows you got it:
```
On it. Cloning <owner>/<repo>, will report back with PR.
```

### 2. Verify GitHub auth + collaborator status

```bash
gh auth status
gh api repos/<owner>/<repo>/collaborators/Ishans-assistant -i 2>&1 | head -1
```

If 404 on the collaborator check → reply: "Add `Ishans-assistant` as collaborator on `<owner>/<repo>` first." Stop.

### 3. Clone fresh into a per-task workspace

```bash
TASK_ID="$(date +%Y-%m-%d)-<short-slug-from-request>"
WORK="$HOME/.openclaw/workspace/nightowl/repos/$TASK_ID"
mkdir -p "$WORK" && cd "$WORK"
gh repo clone <owner>/<repo>
cd $(basename <repo> .git)
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
git checkout "$DEFAULT_BRANCH" && git pull
BRANCH="feat/<short-slug>"
git checkout -b "$BRANCH"
```

### 4. Delegate the actual coding to Claude Code

Use the pinned wrapper. Print mode, bypass permissions (we're already in a sandboxed task dir):

```bash
claude-code-opus45 --permission-mode bypassPermissions --print "$(cat <<'PROMPT'
You are working in a fresh clone of <owner>/<repo>. Branch: <branch>.

Task: <verbatim user request, transcribed if it was voice>

Context: <anything Ishan mentioned: files, framework specifics, constraints>

Constraints:
- Make the smallest change that fully satisfies the task.
- Add or update tests for the new behavior.
- Do not touch unrelated files.
- Do not change package versions unless required.
- If the task is ambiguous in a way you can't fix, say so explicitly and stop.

When done, output a one-paragraph PR description suitable for `gh pr create --body`.
PROMPT
)"
```

### 5. Run tests

Detect test runner from package files and run it. Common cases:
- `package.json` with `test` script → `npm test --silent` (or `pnpm test`, `yarn test` based on lockfile)
- `pyproject.toml` or `pytest.ini` → `pytest -q`
- `go.mod` → `go test ./...`
- `Cargo.toml` → `cargo test --quiet`

If tests fail:
- Feed the failure output back to `claude-code-opus45` with prompt: "Tests failed. Output below. Fix without changing the task scope. <output>"
- Re-run.
- Cap at 3 attempts. If still failing, push what you have, open the PR as **draft**, and tell Ishan exactly what's failing.

### 6. Commit, push, open PR

```bash
git add -A
git commit -m "<imperative subject under 60 chars>" -m "<short body if needed>"
git push -u origin "$BRANCH"

PR_URL=$(gh pr create \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH" \
  --title "<title>" \
  --body "$PR_BODY")
```

PR body MUST include:
- One-line summary of what changed
- Test results (pass/fail/skipped counts)
- Anything left to do (if draft)
- Footer: `Opened by NightOwl 🦉 — see https://github.com/<your>/NightOwl`

### 7. Telegram report

Single message. Format:
```
✅ <one-line summary>
📦 <PR_URL>
🧪 tests: <X passed, Y failed if any>
⏳ awaiting your review (no auto-merge)
```

If something went wrong:
```
⚠️ <one-line failure summary>
📦 <draft PR_URL>
🚫 blocker: <what's blocking>
ask Ishan: <specific question or action needed>
```

## What never to do in this flow

- Never `gh pr merge` — that requires explicit approval via exec-approvals.
- Never push to `main` directly. Always a branch.
- Never `git push --force`. If history needs rewriting, ask.
- Never edit anything outside the task workspace.
- Never include API keys, tokens, or secrets in commits, PR descriptions, or Telegram messages.

## Failure recovery

- Clone fails (permissions): see step 2 — most likely missing collaborator.
- Claude Code times out: re-run with a tighter scope. If still failing, draft PR + ask.
- Push rejected (branch protection): tell Ishan; we may need a different base or someone with admin.
- PR creation fails: most likely wrong default branch detected. Re-check and retry once.
