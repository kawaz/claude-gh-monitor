# Issue Index

| date | category | status | slug | 概要 |
|------|----------|--------|------|------|
| 2026-06-28 | request | open | [release-yml-semver-gate-latest-release-parallel-check](./2026-06-28-release-yml-semver-gate-latest-release-parallel-check.md) | release.yml semver gate に latest-release 並列 check 追加 (DR-0039 canonical 同期) |
| 2026-06-28 | design | open | [watch-workflow-on-success-notify-cmux-msg](./2026-06-28-watch-workflow-on-success-notify-cmux-msg.md) | watch-workflow に --on-success-notify API を追加して cmux-msg notify --self に統合 |
| 2026-07-03 | task | idea | [docs-issue-legacy-format-and-misfiled-cross-repo-items](./2026-07-03-docs-issue-legacy-format-and-misfiled-cross-repo-items.md) | docs/issue の旧形式 3 件が INDEX 未反映 + 他リポ向け issue の混入 |
| 2026-07-03 | bug | open | [posttooluse-hook-wrong-repo-after-cd-push](./2026-07-03-posttooluse-hook-wrong-repo-after-cd-push.md) | PostToolUse hook が別リポへの push 時に session cwd 側の repo/SHA を案内する (誤対象の watch 指示) |
| 2026-07-06 | bug | open | [workflow-absence-check-bypassed-on-jj-workspace](./2026-07-06-workflow-absence-check-bypassed-on-jj-workspace.md) | post_tool_use hook の workflow 不在チェックが git bare + jj workspace 構成で素通りし、workflow 無しリポでも watch nudge が出る |
