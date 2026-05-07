# `WORKFLOW.md` — per-repo NightOwl config

> Status: Draft v1, for review before implementation.
> Lives in the **target repo's root** (the codebase NightOwl is going to work on), not the agent workspace. Version-controlled with the code.

## Why per-repo

Different codebases need different behavior:
- DyslexiAid: `npm` workspace, `frontend/` + `backend/`, no test runner yet.
- A typical Next.js app: `pnpm`, `vitest`, `playwright`.
- A backend service: `pytest`, `mypy`, custom CI.

`WORKFLOW.md` keeps that knowledge with the code so NightOwl never has to guess. Inspired by Symphony's design — same idea, OpenClaw-flavored.

## File location

- Target repo root: `WORKFLOW.md`
- NightOwl reads it from `main` (or the configured default branch) on every tick.
- If absent: fall back to defaults baked into the watcher; post a one-time setup-hint comment on the first ticket NightOwl works in that repo.

## File format

YAML front matter + Markdown body.

```yaml
---
tracker:
  kind: linear              # or "github"
  team: ISH                 # Linear: team key. GitHub: repo (owner/name)
  active_states: [Todo, "In Progress"]
  terminal_states: [Done, Cancelled, Duplicate]
  eligibility:
    require_labels: [nightowl]
    require_assignee: null  # GitHub only — set to "Ishans-assistant" to filter

polling:
  interval_seconds: 30
  max_concurrent_runs: 2

agent:
  model: claude-opus-4-5
  hard_timeout_minutes: 15
  role: solo                # Phase B: solo. Phase C: orchestrator.

repo:
  default_branch: main
  install: |
    npm run install-all
  test: |
    npm test --workspaces --if-present
  lint: |
    npm run lint --workspaces --if-present
  build: |
    npm run build --workspaces --if-present

deploy:
  provider: vercel
  preview_on_pr: true
  prod_requires_approval: true

hooks:
  before_run: |
    # Runs after clone, before agent dispatch
    node --version
  after_run: |
    # Runs after agent completes (success or failure)
    rm -rf node_modules/.cache 2>/dev/null || true

pr:
  draft_on_test_failure: true
  closes_keyword: true      # PR description includes "Closes ISH-12"
  reviewers: [ishangtxl]
---

# NightOwl prompt for this repo

You are NightOwl, working autonomously on a ticket assigned to you.

Conventions:
- Tests live in `**/*.test.js` (Vitest, when added).
- Frontend code is in `frontend/`. Backend is in `backend/`. Don't cross-import.
- Static assets go in `frontend/public/`.

When in doubt about scope, lean small — open a draft PR and ask.
```

## Front-matter sections

### `tracker`
Identifies which board this repo is connected to and how tickets are filtered. The watcher will check every configured tracker on each tick; a repo can technically be wired to both Linear and GitHub by listing the tracker section as a list, but the recommended pattern is **one tracker per repo**.

### `polling`
- `interval_seconds`: minimum polling cadence in seconds. The cron tick runs every 30s; this value lets a repo opt into a slower cadence (e.g. 300 = 5 min) by skipping ticks.
- `max_concurrent_runs`: how many tickets from this repo can be in flight simultaneously. Global cap is enforced separately.

### `agent`
- `model`: which model the per-issue runner uses. Default `claude-opus-4-5` via the `claude-code-opus45` wrapper.
- `hard_timeout_minutes`: kill the runner if it exceeds this.
- `role`: `solo` (single agent) or `orchestrator` (Phase C — spawns role-specialists).

### `repo`
Build/test/lint commands. Treated as bash. Nightowl runs them in the cloned workspace; failure of any of these aborts the PR with a draft + diagnostic comment.

### `deploy`
- `provider`: `vercel` (Phase C) or null.
- `preview_on_pr`: if true, NightOwl deploys a preview and includes the URL in the PR description.
- `prod_requires_approval`: prod deploys require an explicit Telegram approval message before running.

### `hooks`
Pre-/post-run shell snippets. Same shape as Symphony: `before_run`, `after_run`. Failure in `before_run` aborts the attempt; failure in `after_run` is logged but ignored.

### `pr`
- `draft_on_test_failure`: open as draft instead of failing the run outright when tests don't pass.
- `closes_keyword`: include `Closes <ticket-key>` in PR description so the tracker auto-links / auto-closes.
- `reviewers`: GitHub usernames to request review from on every PR.

## Body — the prompt template

The Markdown body below the front matter is the **agent prompt template** for this repo. NightOwl appends the ticket title, body, and any structured context to this template before dispatching to Claude Code.

Keep it short — the prompt is run on every ticket, so verbosity scales with token cost. Treat it like a short README for the agent: conventions, gotchas, what to avoid.

## Validation

The watcher rejects a `WORKFLOW.md` that:
- Has no front matter, OR
- Sets `tracker.kind` to an unsupported value, OR
- References shell commands containing `rm -rf` outside the workspace path, OR
- Sets `hard_timeout_minutes` greater than 60.

Validation errors are posted as a comment on the first ticket NightOwl tries to run from that repo, then the repo is skipped until fixed.

## Examples

See [`/examples/WORKFLOW.md`](../examples/WORKFLOW.md) for a fully annotated example you can copy as a starting point.

DyslexiAid uses [its own WORKFLOW.md committed to that repo](https://github.com/Ishans-assistant/DyslexiAid/blob/main/WORKFLOW.md).
