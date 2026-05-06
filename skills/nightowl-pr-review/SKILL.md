---
name: nightowl-pr-review
description: |
  Review an open GitHub PR and post structured review comments. Use when the user
  asks NightOwl to REVIEW, CHECK, or LOOK AT an existing PR. Does not modify code.
metadata:
  openclaw:
    emoji: "🦉"
    requires:
      anyBins: ["claude", "gh"]
---

# NightOwl PR Review

Read-only flow. NightOwl never pushes commits in this skill.

## When to use

- "Review PR 47 on owner/repo"
- "Look at <PR URL>"
- "What do you think of <PR URL>"

## Inputs needed

- **PR identifier:** Either a full URL or `owner/repo#NN`. If only a number is given and the repo is ambiguous, ask which repo.

## Flow

### 1. Acknowledge

```
Reviewing <PR_URL>. Will post comments and a summary.
```

### 2. Fetch the PR into a temp checkout

```bash
TASK_ID="$(date +%Y-%m-%d)-review-pr<NN>"
WORK="$HOME/.openclaw/workspace/nightowl/repos/$TASK_ID"
mkdir -p "$WORK" && cd "$WORK"
gh repo clone <owner>/<repo>
cd $(basename <repo> .git)
gh pr checkout <NN>
PR_DIFF=$(gh pr diff <NN>)
PR_META=$(gh pr view <NN> --json title,body,baseRefName,headRefName,additions,deletions,files)
```

### 3. Run Claude Code in review mode

```bash
claude-code-opus45 --permission-mode bypassPermissions --print "$(cat <<PROMPT
You are reviewing PR #<NN> on <owner>/<repo>.

Title: <from PR_META>
Description: <from PR_META>

Diff:
<PR_DIFF>

Review the changes critically. Cover:
1. Correctness — does it do what it says?
2. Risk — auth, data loss, race conditions, error handling, secrets?
3. Tests — adequate? do they actually exercise the new code path?
4. Style / maintainability — only flag things that matter, not nits.

Output JSON with this shape:
{
  "verdict": "approve" | "request-changes" | "comment",
  "summary": "<2-3 sentence overall>",
  "blocking": [{"file": "<path>", "line": <int>, "issue": "<what>", "fix": "<suggestion>"}],
  "non_blocking": [{"file": "<path>", "line": <int>, "comment": "<what>"}]
}

Be strict on blocking items: only block for correctness, security, or "this will break in prod" issues. Style nits go in non_blocking.
PROMPT
)"
```

### 4. Post the review

For each `blocking` entry, post a line comment:
```bash
gh pr review <NN> --request-changes --comment "<verdict summary>"
# Then per-file comments via gh api:
# (the gh CLI's `gh pr review --comment` posts a single body; for line-anchored
#  comments use `gh api -X POST /repos/{owner}/{repo}/pulls/{N}/comments` per item)
```

For `non_blocking`, post as `--comment` (informational).

If `verdict == "approve"` and no blocking items:
```bash
gh pr review <NN> --approve --body "<summary>"
```

### 5. Telegram report

```
✅ Review posted on <PR_URL>
verdict: <approve | request-changes | comment>
🚫 blocking: <count>
💬 non-blocking: <count>
<one-line summary>
```

## Hard rules

- Never click merge, never approve a PR with blocking issues, never resolve someone else's conversations.
- Never pull the PR's source changes into NightOwl's main workspace — only into the per-task `repos/<task-id>/`.
- If the PR has merge conflicts, do not resolve them. Note it in the review and stop.
