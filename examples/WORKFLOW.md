---
# NightOwl per-repo configuration. Drop this file at your repo root.
# Full schema: https://github.com/ishangtxl/NightOwl/blob/main/docs/workflow-md.md

tracker:
  # Which kanban / issue tracker NightOwl should poll for this repo.
  # Supported: linear | github
  kind: linear

  # Linear team key (e.g. "ENG"), or for GitHub: "owner/repo".
  team: ENG

  # State names treated as "in scope for NightOwl".
  active_states: [Todo, "In Progress"]

  # State names treated as terminal — NightOwl will not pick these up.
  terminal_states: [Done, Cancelled, Duplicate]

  eligibility:
    # Tickets must have ALL these labels to be picked up.
    require_labels: [nightowl]

    # GitHub only: also require this assignee. Use `null` to skip.
    require_assignee: null

polling:
  # The cron tick is every 30s. This value lets you slow that down for a repo.
  interval_seconds: 30

  # How many tickets from this repo can run in parallel.
  # Global cap (across all repos) is set in the agent config.
  max_concurrent_runs: 2

agent:
  # Which Claude model the per-issue runner uses.
  model: claude-opus-4-5

  # Kill the runner if it takes longer than this.
  hard_timeout_minutes: 15

  # `solo` = single Claude Code session per ticket.
  # `orchestrator` = Phase C — spawns role-specialists in parallel.
  role: solo

repo:
  # Branch NightOwl bases new branches on, and the branch its PRs target.
  default_branch: main

  # Run after clone, before agent dispatch. Treated as bash.
  install: |
    npm ci

  # Test command. Failure does not block the PR if `pr.draft_on_test_failure: true`.
  test: |
    npm test

  # Optional lint step. If present, must pass.
  lint: |
    npm run lint

  # Optional build verification. If present, must pass.
  build: |
    npm run build

deploy:
  # `vercel` is supported in Phase C. Use `null` to disable deploy integration.
  provider: vercel

  # If true, NightOwl runs `vercel --prod=false` after merging tests pass and
  # includes the preview URL in the PR description.
  preview_on_pr: true

  # If true, prod deploys require an explicit Telegram approval message
  # before NightOwl will run them. Recommended.
  prod_requires_approval: true

hooks:
  # Runs after clone, before agent dispatch. Failure aborts the attempt.
  before_run: |
    node --version
    npm --version

  # Runs after the agent completes (success or failure). Failure is logged
  # but ignored.
  after_run: |
    rm -rf node_modules/.cache 2>/dev/null || true

pr:
  # If tests fail, open the PR as a draft (with test output in the description)
  # rather than marking the ticket as failed. Recommended for early adoption.
  draft_on_test_failure: true

  # Include `Closes <ticket-key>` in PR descriptions. Linear and GitHub will
  # then auto-link the PR and (on merge) auto-close the ticket.
  closes_keyword: true

  # Always request review from these GitHub usernames.
  reviewers: [your-github-username]
---

# NightOwl prompt for this repo

You are NightOwl, working autonomously on a ticket assigned to you.

## Conventions

- Tests live in `**/*.test.js`. Run with `npm test`.
- Frontend code in `frontend/`, backend code in `backend/`. Don't cross-import.
- Static assets go in `frontend/public/`.
- TypeScript is preferred for new files; existing JS files can stay JS.

## Defaults when in doubt

- Lean small. A draft PR with a follow-up comment is better than a sprawling diff.
- Match existing patterns rather than introducing new ones.
- Never modify CI config (`.github/workflows/`) unless the ticket explicitly asks.
- Never bump dependencies as part of feature work.

## Boundaries

- Do not touch `secrets/`, `.env*`, or anything in `infra/`.
- Do not run database migrations as part of an issue you weren't explicitly asked to.
