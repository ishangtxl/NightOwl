---
name: nightowl-security-review
description: |
  Run a security-focused review of a repo, branch, or PR. Use when the user asks
  for a SECURITY pass, AUDIT, or CHECK FOR VULNERABILITIES. Posts findings as a
  GitHub issue or PR comment. Does not modify code.
metadata:
  openclaw:
    emoji: "🦉"
    requires:
      anyBins: ["claude", "gh"]
---

# NightOwl Security Review

Read-only flow focused on finding security issues, not fixing them.

## Scope choices

The user may ask for one of:
1. **A specific PR** — review only the diff
2. **A branch** — diff vs default branch
3. **The whole repo** — focus on auth, data handling, secrets, deps, exec/eval, file uploads, deserialization, IDOR/auth bypasses

If unspecified, assume option 1 if a PR is mentioned, otherwise option 3 (whole repo).

## Flow

### 1. Acknowledge

```
Running security pass on <target>. Will post findings.
```

### 2. Set up

```bash
TASK_ID="$(date +%Y-%m-%d)-sec-<slug>"
WORK="$HOME/.openclaw/workspace/nightowl/repos/$TASK_ID"
mkdir -p "$WORK" && cd "$WORK"
gh repo clone <owner>/<repo>
cd $(basename <repo> .git)
# If reviewing a PR: gh pr checkout <NN>
# If reviewing a branch: git checkout <branch>
```

### 3. Gather context

```bash
# Tree (limit depth, skip vendor dirs)
find . -maxdepth 4 -type f \
  -not -path '*/node_modules/*' -not -path '*/vendor/*' \
  -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' \
  | head -200 > /tmp/sec-tree.txt

# Manifests
ls package.json requirements.txt Pipfile pyproject.toml go.mod Cargo.toml composer.json Gemfile 2>/dev/null

# Look for obvious red flags up-front
grep -rEn 'sk-[a-zA-Z0-9_]{20,}|aws_secret|password\s*=|api[_-]?key\s*=' \
  --include='*.{js,ts,py,go,rs,rb,php,env}' . 2>/dev/null | head -50
```

### 4. Delegate the analysis

```bash
claude-code-opus45 --permission-mode bypassPermissions --print "$(cat <<'PROMPT'
You are doing a SECURITY review of this repository. Focus areas, in priority order:

1. **Secrets in code** — keys, tokens, passwords, .env files committed
2. **Authentication & authorization** — broken access control, IDOR, session handling
3. **Input handling** — SQL injection, command injection, SSRF, XSS, path traversal
4. **Data flow** — anywhere user input reaches `eval`, `exec`, `subprocess`, raw SQL, file system
5. **Deserialization** — unsafe pickle, YAML.load without SafeLoader, JSON.parse on attacker input that flows into eval
6. **Crypto** — homemade crypto, weak algorithms (MD5/SHA1 for passwords), hardcoded IVs/keys, missing TLS
7. **Dependencies** — known-vulnerable versions in lockfile (focus on direct deps with CVEs)
8. **File uploads** — unrestricted MIME, path traversal in filename, missing size limits
9. **Logging** — secrets or PII leaking into logs

Read the relevant files. Be specific. For each finding, output:

{
  "severity": "critical" | "high" | "medium" | "low" | "info",
  "title": "<short>",
  "file": "<path>",
  "line": <int or null>,
  "description": "<what's wrong>",
  "exploit": "<how an attacker uses it>",
  "fix": "<concrete remediation>"
}

End with a JSON array of all findings. If nothing found, return [].

Do NOT include style nits or code-quality issues unrelated to security.
PROMPT
)"
```

### 5. Post findings

If any **critical** or **high** findings → open a GitHub issue:

```bash
gh issue create \
  --title "Security review: <N> findings (<critical> critical, <high> high)" \
  --body "$FINDINGS_MARKDOWN" \
  --label "security"
```

If reviewing a PR, post as a PR comment instead:
```bash
gh pr comment <NN> --body "$FINDINGS_MARKDOWN"
```

If clean:
```bash
gh pr comment <NN> --body "🔒 Security review by NightOwl: no issues found in scope. (Full coverage: <list>)"
# or create no issue at all and just reply on Telegram
```

### 6. Telegram report

```
🔒 Security review on <target>
critical: <N>  high: <N>  med: <N>  low: <N>
<link to issue or PR comment>
<one-line top finding if any>
```

## Hard rules

- Never auto-fix security issues. Findings only. (Fixes go through `nightowl-feature-flow` after Ishan reads the report.)
- Never post the actual exploit payload publicly. Describe in abstract terms.
- If you find an active leaked credential in the repo, **redact it in the report** and tell Ishan via Telegram FIRST, with the file path. Then make the GitHub issue with the redacted version.
