# Issue Index

| date | category | status | slug | 概要 |
|------|----------|--------|------|------|
| 2026-06-28 | request | open | [release-yml-semver-gate-latest-release-parallel-check](./2026-06-28-release-yml-semver-gate-latest-release-parallel-check.md) | release.yml semver gate に latest-release 並列 check 追加 (DR-0039 canonical 同期) |
| 2026-06-28 | design | open | [watch-workflow-on-success-notify-cmux-msg](./2026-06-28-watch-workflow-on-success-notify-cmux-msg.md) | watch-workflow に --on-success-notify API を追加して cmux-msg notify --self に統合 |
| 2026-07-03 | task | idea | [docs-issue-legacy-format-and-misfiled-cross-repo-items](./2026-07-03-docs-issue-legacy-format-and-misfiled-cross-repo-items.md) | docs/issue の旧形式 3 件が INDEX 未反映 + 他リポ向け issue の混入 |
| 2026-09-23 | bug | open | [post-tool-use-sha-before-push-or-on-failure](./2026-09-23-post-tool-use-sha-before-push-or-on-failure.md) | post_tool_use.sh の --sha 案内が push 前 / push 失敗時 / background 起動時に誤る |
| 2026-07-03 | bug | open | [posttooluse-hook-wrong-repo-after-cd-push](./2026-07-03-posttooluse-hook-wrong-repo-after-cd-push.md) | PostToolUse hook が別リポへの push 時に session cwd 側の repo/SHA を案内する (誤対象の watch 指示) |
| 2026-08-13 | bug | open | [watch-pr-duplicate-emission-needs-state-persistence](./2026-08-13-watch-pr-duplicate-emission-needs-state-persistence.md) | watch-pr が同一内容を繰り返し emit する (状態を永続化して直近との差分がなければ通知しない) |
| 2026-08-13 | design | open | [watch-pr-shared-cache-across-sessions](./2026-08-13-watch-pr-shared-cache-across-sessions.md) | 同一 PR を複数セッションで監視すると gh API を重複で叩く (蓄積ファイルを共有キャッシュとして使う) |
