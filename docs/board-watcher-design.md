# Board watcher — design

This is the design document for the autonomous path: a polling loop that watches a kanban board (Linear, GitHub Issues, or any tracker behind the same protocol), claims eligible tickets, hands each one to a per-issue runner, and writes a status comment back to the ticket.

It complements [`docs/architecture.md`](architecture.md), which has the high-level diagram and the rationale for splitting orchestration from code generation. This document goes deeper on the *how*: claim semantics, concurrency, restart recovery, the adapter protocol, and the failure modes that shaped the design.

---

## 1. Goals and non-goals

**Goals**

- Pick up tickets from a tracker without a human in the loop, but only when explicitly opted in.
- Run the same skill library that the Telegram path runs — a ticket and a Telegram message are *peer inputs*, not separate code paths.
- Bound concurrency so a flood of eligible tickets doesn't fork-bomb the VPS or burn through tokens.
- Survive restarts: a daemon crash mid-run must not double-dispatch the same ticket.
- Keep tracker-specific knowledge in a small, swappable adapter so adding Jira / Notion / ClickUp later is a contained change.

**Non-goals**

- Webhook-driven push from the tracker. Polling is enough at this scale and avoids exposing a public ingress on the VPS.
- Auto-merging or auto-deploying anything. The watcher's output is always a pull request requesting review.
- Cross-tracker workflows (a ticket in Linear that depends on an issue in Jira). Each ticket is independent.

---

## 2. High-level loop

```
systemd timer  ──30s──▶  bin/nightowl-board-watcher
                              │
                              │  acquire global tick lock (fcntl)
                              │  load secrets (.secrets/linear.env, etc.)
                              │  read board-watcher.config.yaml
                              │  count active per-issue locks → free slots
                              │
                              ▼
                        for each tracker in config:
                              │
                              │  adapter list → eligible issues
                              │  for each issue, while slots > 0:
                              │     skip if per-issue lock exists
                              │     write per-issue lock
                              │     adapter transition → claimed
                              │     spawn bin/nightowl-issue-runner (background)
                              │     slots -= 1
                              │
                              ▼
                        release tick lock, exit
```

The watcher is a fast, side-effect-light entry point. It never waits for a runner to finish; the runner is responsible for cleaning up its own per-issue lock and posting its own final status.

---

## 3. Configuration

`agents/nightowl/board-watcher.config.yaml` is the single source of truth for which trackers to poll and at what cap.

```yaml
global:
  max_concurrent_runs: 2          # global cap across ALL trackers

trackers:
  - name: linear-ish
    kind: linear                  # adapter file under bin/adapters/<kind>
    config:
      team: ISH
      eligibility:
        require_labels: [nightowl]
      default_repo: ishangtxl/DyslexiAid

  - name: github-nightowl
    kind: github-issues
    config:
      repo: ishangtxl/NightOwl
      eligibility:
        require_labels: [nightowl]
        require_assignee: Ishans-assistant
```

The watcher itself is intentionally dumb about what's inside `config:` — it forwards the whole block to the adapter as the `config` field of the JSON payload. Adapters own their own validation.

---

## 4. The `BoardAdapter` protocol

Adapters are standalone executables under `bin/adapters/<kind>`. They speak a tiny JSON-over-stdio protocol. This keeps the watcher language-agnostic about trackers and makes adapters trivially testable from a shell.

### 4.1 Invocation

```
bin/adapters/<kind> <verb>
  stdin:  <JSON payload>
  stdout: <JSON response>
  exit:   0 ok · 2 bad input · 3 upstream error
```

### 4.2 BoardAdapter interface

Four verbs, identical shape across adapters:

| Verb | Purpose | Stdin | Stdout |
|---|---|---|---|
| `list` | Return all currently eligible issues for this tracker. | `{"config": {...}}` | `{"issues": [Issue, ...]}` |
| `get` | Fetch one issue by id. | `{"config": {...}, "id": "<key>"}` | `{"issue": Issue}` |
| `comment` | Post a comment on an issue. | `{"config": {...}, "id": "<key>", "body": "..."}` | `{"ok": true}` |
| `transition` | Move an issue between NightOwl lifecycle states. | `{"config": {...}, "id": "<key>", "to": "claimed\|done\|failed\|waiting\|release"}` | `{"ok": true}` |

The `Issue` shape is a normalized dict produced by the adapter:

```jsonc
{
  "id":          "5",                 // tracker-local id, used by transition/get
  "tracker":     "linear",            // adapter kind
  "key":         "ISH-5",             // human-facing key (used in branch names)
  "title":       "Add /api/version endpoint",
  "body":        "...",
  "url":         "https://linear.app/...",
  "state":       "Todo",
  "labels":      ["nightowl"],
  "assignees":   ["Ishans-assistant"],
  "repo":        "ishangtxl/DyslexiAid",
  "claimed":     false,
  "branch_hint": "ish-5-add-api-version-endpoint"  // adapter may suggest a branch name
}
```

The runner only ever reads this shape — it never speaks to the tracker directly.

### 4.3 Lifecycle states

Lifecycle is encoded as labels prefixed `nightowl:`. The label vocabulary is shared across adapters so behaviour is consistent regardless of tracker:

| Label | Meaning |
|---|---|
| `nightowl:claimed`  | Watcher has dispatched a runner. Don't pick up again. |
| `nightowl:done`     | Runner finished and opened a PR. |
| `nightowl:failed`   | Runner crashed or exhausted retries. |
| `nightowl:waiting`  | Runner is blocked on something (review, exec-approval). |

A `transition` verb call with `to: "release"` strips all four — used for manual re-queueing or test resets.

---

## 5. Eligibility

The single most important property: **NightOwl must never pick up a ticket that wasn't explicitly opted in.** Filling someone's backlog with autonomous PRs is the kind of "feature" that turns into a Slack apology.

Rules (applied in the adapter's `is_eligible`):

1. **Lifecycle exclusion.** Any of `nightowl:claimed`, `nightowl:done`, `nightowl:failed`, `nightowl:waiting` → skip.
2. **Default-deny opt-in.** If neither `require_labels` nor `require_assignee` is configured, nothing is eligible. Empty config = silent watcher, not greedy watcher.
3. **Either-or match.** A ticket is eligible if it matches `require_labels` *or* `require_assignee` (logical OR). Both can be configured; either alone is sufficient.

This makes the contract for adopters trivially explicit: drop a ticket in your backlog, label it `nightowl`, and only then does anything happen.

---

## 6. Claim and release semantics

Two layers of protection ensure an issue is dispatched at most once per state change.

### 6.1 Per-issue lock file

Path: `~/.openclaw/workspace/nightowl/.locks/<kind>-<safe-key>.lock`

The watcher writes this *before* calling the adapter's `transition → claimed`. This is intentional ordering: if the tracker is down and the label can't be applied, the lock still prevents the next tick from re-dispatching. The runner is responsible for deleting the lock when it terminates (success or failure).

### 6.2 Lifecycle label

The `nightowl:claimed` label is the cross-process, cross-host source of truth. Even if the lock file is somehow deleted manually, the eligibility filter will skip a `claimed` ticket.

### 6.3 Stale lock handling

A long-stuck `.lock` file (process died, lock not cleaned up) is *not* automatically purged on tick — the conservative default is to leave it there and require manual intervention. Logged loudly so the next tick reports `[KEY] already locked, skipping` and a human can look. Auto-purging stale locks risks re-dispatching tickets that are actually still in flight.

---

## 7. Concurrency

A single global cap, configured under `global.max_concurrent_runs`. Default 2. Counted by enumerating active per-issue lock files, not by talking to the tracker. This means concurrency holds even across watcher invocations and tracker outages.

The cap is *global* across trackers, not per-tracker. Two simultaneous Linear tickets and zero GitHub tickets is fine; three Linear tickets means the third waits for the next tick. Per-tracker caps are a deliberate non-feature — the bottleneck is the VPS and the model, both of which are global resources.

A tick-level lock (`.locks/.tick.lock`, `fcntl.flock`) prevents two ticks from racing each other. If a tick fires while another is mid-flight (e.g. the previous tick is still inside the adapter's network call), the new tick exits immediately without claiming anything.

---

## 8. The per-issue runner

`bin/nightowl-issue-runner` is invoked by the watcher with a JSON payload on stdin and is detached via `start_new_session=True`. It runs to completion or crash without the watcher's involvement.

### 8.1 Workspace and branch model

```
~/.openclaw/workspace/nightowl/
  repos/
    <kind>-<safe-key>/         ← one workspace per ticket
      <fresh clone of target repo>
  .locks/
    <kind>-<safe-key>.lock     ← held until runner exits
  logs/
    <kind>-<key>-<epoch>.log   ← runner's stdout/stderr
```

Branch name comes from `issue.branch_hint` if the adapter provided one, otherwise it's generated as `<key-lowercase>-<title-slug>`. For Linear this matches the format Linear's GitHub integration auto-detects, so opening a PR on that branch automatically links it back to the ticket.

### 8.2 Steps

1. Resolve target repo (`issue.repo` or tracker `default_repo`).
2. Clean and recreate the per-issue workspace.
3. `gh repo clone` into it (uses bot account auth).
4. Read the repo's `WORKFLOW.md` (see [`workflow-md.md`](workflow-md.md)).
5. Create branch from `branch_hint` or generated slug.
6. Post 🦉 *Implementing* status comment via `adapter comment`.
7. Run the optional `install` hook from `WORKFLOW.md`.
8. Invoke Claude Code with the assembled prompt template + ticket body via stdin.
9. Verify the diff is non-empty.
10. Commit as `NightOwl <ishans-assistant@users.noreply.github.com>`.
11. Run the configured quality gates (`test`, `lint`, `build`).
12. Push the branch.
13. `gh pr create` with `Closes <key>` in the body.
14. Post final status comment + `transition → done` (or `failed` on test gate failure).
15. Delete the per-issue lock file.

Steps 5–15 are all logged to the per-issue log file. The watcher never reads these logs; they exist for human debugging.

---

## 9. Status update protocol

Three comments per successful run, posted via the adapter's `comment` verb so they end up on the ticket regardless of tracker:

```
🦉 Claimed by NightOwl. Cloning <repo>…
🦉 Implementing on branch <branch> — ETA ~2-4 min.
🦉 ✅ PR opened: <url>
   ✅ build: pass — lint: skipped — test: skipped
   ⏳ Awaiting review
```

Failed runs replace the third comment with a draft-PR message including the failing gate's last 30 lines of output, and transition the ticket to `nightowl:failed`. The PR is opened as a draft so reviewers see the failure context but no one accidentally merges broken code.

---

## 10. Restart recovery

The watcher is stateless across invocations. State lives in two places:

1. **Lock files on disk** — survive watcher restarts. A runner mid-flight when the watcher process dies still holds its lock; the next tick correctly skips the ticket.
2. **Lifecycle labels on the tracker** — survive lock-file deletion. If the workspace is wiped (e.g. a fresh VPS provisioning), tickets already in `nightowl:claimed` are skipped until manually released via `transition → release`.

There is no in-memory queue. There is no local database. The watcher reads everything fresh on every tick.

---

## 11. Failure handling

| Failure | Recovery |
|---|---|
| Adapter `list` fails (tracker outage). | Log, continue to next tracker. No claim made. |
| Adapter `transition → claimed` fails after lock acquired. | Lock prevents double-dispatch. Runner proceeds; runner's own status comment will reveal the missing label state and a human can re-label manually. |
| Runner crashes before posting final comment. | Lock file remains. Lifecycle label remains `nightowl:claimed`. Manual cleanup required (logged). |
| Quality gate fails. | PR opened as draft with failure output in the body. Lifecycle → `nightowl:failed`. |
| `gh repo clone` fails (auth, missing repo). | Runner aborts, posts a 🦉 ❌ comment, transitions to `failed`. |

The conservative bias is "never silently retry" — a failed run sits visible until a human looks.

---

## 12. Adapter implementation notes

### 12.1 Linear

Uses the Linear GraphQL API directly via `urllib`. Auth header is the personal API key with no `Bearer` prefix (Linear's convention). The adapter caches the team ID and label IDs across calls in a single watcher tick to avoid redundant lookups.

`branch_hint` is constructed from Linear's `branchName` field on the issue, with the user prefix stripped (`ishan/ish-5-add-api-version-endpoint` → `ish-5-add-api-version-endpoint`) so PRs auto-link cleanly.

### 12.2 GitHub Issues

Uses `gh` CLI subprocess. This piggybacks on the bot's existing device-flow auth — no PAT required, no extra credentials to rotate. `gh` is invoked with `--json` flags so the parsing is the same JSON shape regardless of `gh` version cosmetics.

The lifecycle labels are created on first use via `gh label create` with a fixed colour (`#5319e7`) and the description "NightOwl lifecycle", so a fresh repo gets a consistent palette without manual setup.

---

## 13. What's deliberately out of scope

- **Per-ticket retries.** A failed run stays failed. Re-queueing is a manual `transition → release`.
- **Priority queues.** Tickets are processed oldest-first within a tracker; cross-tracker order is "whichever tracker the watcher iterates first". Adding a priority field is a config-only change later.
- **Subscriptions.** No webhooks, no persistent connections. The polling cadence is fast enough (30 s) that the user-visible latency is dominated by Claude Code's run time, not the polling delay.
- **Cross-watcher coordination.** Exactly one watcher is expected to run on the VPS. Two watchers polling the same trackers would race on label transitions; the design does not protect against this and the deployment doesn't create that condition.

---

## 14. References

- [`docs/architecture.md`](architecture.md) — high-level system design, why two model layers, voice path.
- [`docs/workflow-md.md`](workflow-md.md) — the per-repo `WORKFLOW.md` schema the runner reads.
- [`examples/WORKFLOW.md`](../examples/WORKFLOW.md) — annotated reference template.
- [`bin/nightowl-board-watcher`](../bin/nightowl-board-watcher) — orchestrator implementation.
- [`bin/nightowl-issue-runner`](../bin/nightowl-issue-runner) — per-issue runner implementation.
- [`bin/adapters/linear`](../bin/adapters/linear) and [`bin/adapters/github-issues`](../bin/adapters/github-issues) — the two reference adapters.
