# gh-monitor Design Document

> English | [日本語](./DESIGN-ja.md)

## Purpose of this document

A complete context-sharing document so that a fresh Claude Code session can pick up this project without knowing the prior discussions. The authoritative record of design decisions lives under [docs/decisions/](decisions/).

---

## 1. Background and motivation

### Existing pain points

- Running multiple PRs in parallel often leaves reviews / CI waiting unattended for a long time
- Repeatedly running `gh pr view` / `gh pr checks` / `gh run watch` by hand is inefficient and eats up Claude Code's conversation context
- We want a mechanism that surfaces the moment a PR or workflow run actually moves

### Comparison with existing options

| Option | Notification granularity | Cost |
|---|---|---|
| Email notifications | Almost everything (noisy) | Switching to a mail client |
| GitHub desktop notifications | Comments / reviews | OS-dependent setup |
| Repeating `gh pr view` / `gh run watch` manually | Only when you choose to look | Eats conversation context |
| **This tool** | **Only what the conversation needs** | One Bash process (~2 MB) |

### Properties of Claude Code's Monitor tool

- Delivers a chat notification per stdout line of a long-running script
- `persistent: true` keeps it alive until session end
- Can be started independently across multiple sessions

We use this to keep a Bash script resident that "polls GitHub → emits a single line on state change."

---

## 2. Decisions

The canonical record of design decisions is [docs/decisions/INDEX.md](decisions/INDEX.md). This section only summarizes.

| # | Topic | Decision | Reference |
|---|---|---|---|
| 1 | Scope | Low-context notifications for GitHub's asynchronous events (PR / workflow run) | [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) |
| 2 | Distribution | Claude Code Plugin (`.claude-plugin/` + `marketplace.json`) | — |
| 3 | Feature split | Two skills: `watch-pr` + `watch-workflow` | [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) |
| 4 | Hook responsibility | Limited to "state detection + one-line Monitor launch instruction" | [DR-0002](decisions/DR-0002-hook-minimal-output.md) |
| 5 | Workflow-watch launch strategy | One persistent Monitor per repo (triggered by PostToolUse hook detecting push) | [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) |
| 6 | Cross-session interference | Each session is independent (1 process ~2 MB in Bash, no locking needed) | — |
| 7 | Implementation language | Bash + `gh` + `jq` (memory-efficient; Bun/TS were considered but the 1 process ~2 MB profile wins) | — |
| 8 | Self-originated events | Suppressed by default (`GH_MONITOR_INCLUDE_SELF=1` to disable) | [DR-0004](decisions/DR-0004-suppress-self-originated-events.md) |

### Why Bash

Measured: Bash ~2 MB / Bun ~22 MB / Node ~46 MB. Bash chosen for many parallel sessions.

---

## 3. Architecture

### watch-pr (implemented)

```
[Claude Code session starts]
        │
        ▼
[SessionStart hook] ← plugin's hooks/hooks.json (matcher=startup|resume)
        │
        ▼
[hooks/session_start.sh] ← under ${CLAUDE_PLUGIN_ROOT}/hooks/
        │
        ▼
[scripts/detect-pr.sh] ← current worktree branch → detect PR
        │
        │ (if PR found)
        ▼
[emit Monitor launch instruction to stdout] ← Claude reads it and starts a Monitor
        │
        ▼
[Monitor tool] runs [scripts/watch-pr.sh] persistently
        │
        ▼ every 60s
[gh pr view ... --json] → [hash via jq, compare to previous]
        │
        │ (on change)
        ▼
[emit 1 line to stdout] → Monitor delivers it to Claude as a [task-notification]
        │
        ▼
[Claude reports to the user as needed]
```

### watch-workflow (implemented)

```
[Claude invokes git/jj/just/pkf push via the Bash tool]
        │
        ▼
[PostToolUse hook] ← loose push-detect regex + tool_response success check
        │
        │ (only on success)
        ▼
[Return JSON with hookSpecificOutput.additionalContext]
        │
        │ Claude reads the context
        ▼
[Start a Monitor if `watch-workflow: <user/repo>` is not already in the list]
        │
        ▼
[Monitor tool] runs [scripts/watch-workflow.sh] persistently, one per repo
        │
        ▼ every 30s+
[gh api .../actions/runs] → [build baseline with start-time lookback, emit only on state change]
        │
        ▼
[emit 1 line to stdout] → notification to Claude
```

Details: [DR-0002](decisions/DR-0002-hook-minimal-output.md) / [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md).

### Components

| File | Responsibility |
|---|---|
| `.claude-plugin/plugin.json` | plugin manifest (name / version / author / repository) |
| `.claude-plugin/marketplace.json` | marketplace manifest (for install) |
| `hooks/hooks.json` | hook registration (SessionStart + PostToolUse) |
| `hooks/session_start.sh` | hook body. Detect PR → emit skill launch instruction on stdout |
| `hooks/post_tool_use.sh` | hook body. Detect Bash tool push success → return JSON additionalContext |
| `scripts/detect-pr.sh` | Find an open PR for the current branch. Outputs `OWNER/REPO\tPR_NUMBER` |
| `scripts/watch-pr.sh` | Monitor body. Calls `gh pr view` every 60s, emits one line on change |
| `scripts/watch-workflow.sh` | Monitor body. Polls `gh api .../actions/runs` every 30s, emits one line on change |
| `skills/watch-pr/SKILL.md` | watch-pr skill definition. Monitor launch args, notification meaning, duplicate prevention |
| `skills/watch-workflow/SKILL.md` | watch-workflow skill definition (same) |
| `justfile` | validate / lint / version / push |

### Responsibility split between scripts

- **The hook only emits the minimal instruction.** Claude reads the hook's output and starts the Monitor.
  - Reason: if the hook itself starts a Monitor as a child process, its lifetime becomes ambiguous when the hook exits.
  - By having Claude invoke the Monitor tool (rather than the hook starting a child process directly), the process lifetime is correctly managed as "part of the session."
  - The context-injection path differs per event type: SessionStart uses plain stdout, PostToolUse uses JSON with `hookSpecificOutput.additionalContext`. See [DR-0002](decisions/DR-0002-hook-minimal-output.md) for details.
- **`watch-pr.sh` / `watch-workflow.sh` only do change detection and emit.** Duplicate-launch prevention is the responsibility of the upper layer (Monitor description match).

---

## 4. Operational specification

### Common emit design

All skill output follows two formats:

#### (a) Skill-specific events — `[scope:action] key:value ...`

- The leading `[scope:action]` is the event kind (verb:noun). Examples: `[run:change]` `[comment:add]` `[review:submit]` `[ci:change]` `[pr:merge]` `[pr:close]`
- The rest is `key:value` separated by spaces
- Values are double-quoted only when they contain spaces or special characters
- Scope identifiers such as skill name / repo / PR# are pushed into the **Monitor description** (= `<summary>` of `<task-notification>`) and omitted from emit lines
- Descriptions are locked by naming convention in SKILL.md (`watch-pr: <owner/repo>#<N>`, `watch-workflow: <owner/repo>`). Duplicate prevention (TaskList grep) also rides on this naming.

#### (b) Severity messages — `[INFO|WARN|ERROR] <freeform>`

- Intentionally structured differently from skill-specific events (payload is freeform; KV constraint is relaxed)
- Start ack (`[INFO] <skill> start: <repo> (interval=...)`) belongs here. Configuration values that aren't on the description (interval / lookback) can also be written here.
- Failure notices use natural language too, e.g. `[WARN] gh ... が N 回連続失敗`
- Fatal script-level errors (e.g., usage errors) go to stderr instead (not the stdout notification path)

### watch-pr

#### Lines emitted on change

| Event | Trailing fields | Meaning |
|---|---|---|
| `[comment:add]` | `user:<login> url:<url> body:"..."` | New comment, first 200 chars of body, URL for follow-up |
| `[review:submit]` | `user:<login> state:<STATE>` | Review submitted (url omitted; not present in `gh` CLI's json schema) |
| `[ci:change]` | `check:"<name>" status:<status> url:<url>` | One line per individual CI check state change; url = detailsUrl/targetUrl |
| `[pr:merge]` | `user:<login> commit:<sha7> at:<timestamp>` | Merge detected → exits immediately. Fields omitted if mergedBy / mergeCommit are missing |
| `[pr:close]` | (none) | Close detected → exits immediately |
| `[INFO]` / `[WARN]` | (freeform) | Start ack / recovery / N consecutive gh failures, etc. |

#### Fields used for hash-based deduplication

```jq
{
    state, mergedAt,
    comments: [.comments[] | {createdAt, a:.author.login}],
    reviews:  [.reviews[]  | {state, a:.author.login, submittedAt}],
    checks:   [.statusCheckRollup[] | {name, status, conclusion}]
}
```

Minor edits to an existing comment body (typo fixes, etc.) do not trigger emit. Reaction additions do not either. The design tracks "who acted, and when."

### watch-workflow

#### Start ack

```
[INFO] watch-workflow start: kawaz/foo (interval=30s, lookback=5m)
```

#### Lines emitted on change

```
[run:change] workflow:ci.yml id:12345678 status:failure commit:abc1234 branch:main user:kawaz event:push
```

#### Failure notices

```
[WARN] gh api が 5 回連続失敗
[INFO] gh api が復旧 (5 回失敗のあと)
```

The `status` vocabulary follows `gh` (`queued` / `in_progress` / `success` / `failure` / `cancelled` / `skipped` / `timed_out` / `action_required`, etc., flattened). Details: [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md).

---

## 5. Status

### watch-pr ✅ implemented

- SKILL.md / hook / script / detect-pr.sh are implemented
- Skill description optimizer has not been applied (will iterate from real usage)
- Real-usage verification: see [docs/findings/](findings/)

### watch-workflow ✅ implemented

- Design decisions: [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) / [DR-0002](decisions/DR-0002-hook-minimal-output.md) / [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md)
- Delta from DR-0003's emit format: `gh run list --json` in gh 2.92.0 does not expose the `actor` field, so the poll path switched to `gh api /repos/<owner>/<repo>/actions/runs?per_page=100`, and the emit was finalized to include both `actor.login` and `event` (adjustment made during implementation on 2026-05-26)

### Future improvements

- Include the PR check URL in `[CI]` lines (faster drill-down on failure)
- `watch-workflow.sh` options (`--only-mine` / `--workflow` / `--events`). See "Future extensibility" in [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md)
- Invocable skill for manual start (e.g., `/gh-monitor:watch-ci`)

---

## 6. Reference

### jj workspace layout

```
github.com/kawaz/claude-gh-monitor/
├── .git/         # git bare
├── .jj/          # jj default workspace (keeps an empty @ as a guard against parent-directory .git/.jj scanning)
└── main/         # main work workspace (development happens here)
```

Owner is `kawaz` (personal OSS, MIT). Adopts jj workflow (since `.jj` is present, follow jj-workflow.md).
