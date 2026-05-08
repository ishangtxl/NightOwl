# Contributing

Thanks for helping improve NightOwl. This repo is designed to be easy to copy to a VPS, run through OpenClaw, and change through normal pull requests.

## Clone the repo

```bash
git clone https://github.com/ishangtxl/NightOwl.git
cd NightOwl
```

Create a branch for your change:

```bash
git checkout -b <type>/<short-description>
```

Examples:

```bash
git checkout -b docs/update-setup
git checkout -b fix/board-watcher-locks
```

## Sync changes to the VPS

NightOwl runs from an OpenClaw workspace on the VPS. After changing persona files, skills, docs, or runtime scripts locally, sync them with:

```bash
./scripts/sync-to-vps.sh
```

The script is idempotent and copies the repo content into the NightOwl workspace used by OpenClaw. Run it from the repo root.

If you changed executable scripts under `bin/` or `scripts/`, verify they still have the right permissions after syncing:

```bash
ls -l bin scripts
```

## Open a pull request

Before opening a PR:

1. Keep the change focused and avoid unrelated formatting churn.
2. Run the smallest relevant check for the change.
   - Docs-only change: read the rendered Markdown or inspect the diff.
   - Shell/Python script change: run the script's help path or a dry-run if available.
   - Watcher/runner change: test in a scratch repo or clearly state what was not exercised.
3. Confirm no secrets, tokens, local paths, or private logs are included.

Push your branch and open a PR:

```bash
git push -u origin <type>/<short-description>
gh pr create --base main --fill
```

In the PR description, include:

- What changed
- How it was tested
- Anything left untested or blocked
- Any linked issue, for example `Closes #1`

NightOwl PRs should remain reviewable and safe: no force-pushes, no direct pushes to `main`, no production deploys, and no merging without explicit approval.
