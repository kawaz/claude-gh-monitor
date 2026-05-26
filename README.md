# claude-gh-monitor

> English | [日本語](./README-ja.md)

Claude Code plugin: low-context notifications for GitHub's asynchronous events (PR state changes, GitHub Actions workflow runs) via Claude Code hooks + the Monitor tool.

While you wait for PR reviews / CI results or workflow outcomes after a push, this plugin lets Claude Code keep working on something else — and surfaces only the state changes as one-line notifications in the chat. No more manually re-running `gh pr view` / `gh run watch`.

## Install

```bash
claude plugin marketplace add kawaz/claude-gh-monitor
claude plugin install gh-monitor@gh-monitor
```

After installation, starting Claude Code in a worktree whose branch is tied to an open PR triggers the SessionStart hook to detect the PR and prompt `watch-pr`. Right after a `push`, the PostToolUse hook prompts `watch-workflow` to watch the workflow runs.

Terms used in this README:

- **hook** — a script the plugin registers with Claude Code to run automatically on session start or after a tool call (`SessionStart`, `PostToolUse`)
- **skill** — a Claude Code primitive the assistant can invoke; here it tells Claude to start the Monitor with the right arguments
- **Monitor tool** — the Claude Code background watcher; each emitted stdout line becomes one chat notification

## Quick check after install

```bash
# 1. In a worktree whose branch has an open PR:
gh pr list --head "$(git branch --show-current)"     # should show your PR
claude                                                # SessionStart hook runs
# → Expect a `watch-pr: <owner/repo>#<N>` Monitor to be running

# 2. Right after a push (any of: git push / jj git push / just push / pkf run push):
# → Expect Claude to start a `watch-workflow: <owner/repo>` Monitor
# → Watch the chat for [run:change] ... status:success|failure ... lines
```

## Requirements

- [GitHub CLI (`gh`)](https://cli.github.com/) and `jq` installed
- Authenticated via `gh auth login` with read access to the target repository

  ```bash
  gh auth status      # current auth status
  gh auth login       # interactive setup if not authenticated
  ```

- The repository is laid out as a git worktree or a jj workspace

## Features

### Hook: `SessionStart`

On session start (`startup` / `resume`), the hook detects the open PR tied to the current worktree's branch and asks Claude to start the `watch-pr` skill. It does nothing on branches without an open PR.

### Hook: `PostToolUse`

When a `git push` / `jj git push` / `just push` / `pkf run push` succeeds via the Bash tool, the hook asks Claude to start the `watch-workflow` skill. It stays silent on failures (`is_error` / `interrupted`) or non-push commands.

### Skill: `watch-pr`

One persistent Monitor per PR runs `watch-pr.sh` and emits a single line whenever the PR state changes. The Monitor description follows the `watch-pr: <owner/repo>#<N>` naming convention to prevent duplicate watchers.

Example emits (`[scope:action] key:value` format):

```
[comment:add] user:alice url:https://github.com/owner/repo/pull/N#issuecomment-123 body:"LGTM"
[review:submit] user:alice state:APPROVED
[ci:change] check:Test status:failure url:https://github.com/owner/repo/actions/runs/...
[pr:merge] user:alice commit:abc1234 at:2026-04-23T02:00:00Z
[pr:close]
```

### Skill: `watch-workflow`

One persistent Monitor per repo runs `watch-workflow.sh` and emits a single line whenever a GitHub Actions workflow run changes state. The Monitor description follows the `watch-workflow: <owner/repo>` convention. A 5-minute lookback from the start time is used as the baseline cutoff so that fast CI runs are still surfaced on the first poll ([DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md)).

Example emit:

```
[run:change] workflow:ci.yml id:12345678 status:failure commit:abc1234 branch:main user:kawaz event:push
```

### Common emit format

All notification lines fall into two categories:

- **(a) Skill-specific events** — `[scope:action] key:value ...` (verb:noun + structured payload)
- **(b) Severity messages** — `[INFO|WARN|ERROR] <freeform>` (start ack / failure notice / fatal error)

Scope identifiers such as skill name / repo / PR# are pushed into the Monitor description (= notification summary) and omitted from emit lines. See [docs/DESIGN.md](docs/DESIGN.md) for details.

### Scripts

- `scripts/watch-pr.sh` — PR watcher (Bash + `gh` + `jq`, ~2 MB per process)
- `scripts/watch-workflow.sh` — Actions workflow run watcher
- `scripts/detect-pr.sh` — Detect the open PR tied to the current worktree's branch (works with both git worktree and jj workspace)

## Development

```bash
just ci                  # lint + validate (matches CI exactly)
just version             # show current version
just bump-semver         # patch bump (pass `minor` / `major` for level)
just push                # run all checks + version bump detection + push
just push-without-bump   # for docs-only changes where no bump is required
```

## Troubleshooting

- **`watch-pr` did not start**
  1. `git branch --show-current` — confirm the current branch
  2. `gh pr list --head "$(git branch --show-current)"` — does an open PR exist?
  3. `gh auth status` — is `gh` authenticated for this repo?
- **`watch-workflow` did not start after push**
  1. `git remote get-url origin` — does origin point to GitHub?
  2. `gh api "repos/<owner>/<repo>/actions/runs?per_page=1"` — does the API answer?
  3. Was the push reported as successful by Claude Code? (the hook stays silent on `is_error: true` or `interrupted: true`)
- **Notifications stop arriving**
  - Check the Claude Code TaskList for `watch-*` Monitors — if missing, simply rerun the hook trigger (start a session / push again)

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md) — design document (background, architecture)
- [docs/decisions/INDEX.md](docs/decisions/INDEX.md) — decision records (DR)
- [docs/findings/](docs/findings/) — verification logs
- [CHANGELOG.md](CHANGELOG.md) — release history

## License

MIT License, Yoshiaki Kawazu (@kawaz)
