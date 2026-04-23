# Changelog

All notable changes to this project will be documented in this file.

## [0.1.2] - 2026-04-24

### Changed

- marketplace 名を `claude-pr-monitor` → `pr-monitor` に変更（`claude-` prefix を削除）。インストールコマンドは `claude plugin install pr-monitor@pr-monitor` になる

## [0.1.1] - 2026-04-23

### Fixed

- `pr-monitor.sh`: `statusCheckRollup` の `StatusContext` (外部 CI 連携、例: CodeRabbit) が `null=null` と表示されていた問題を修正。CheckRun / StatusContext 両 typename を吸収するよう jq を改修

## [0.1.0] - 2026-04-23

### Added

- Initial plugin release
- Skill `pr-monitor`: PR 状態変化を Monitor ツール経由で通知
- Hook `SessionStart` (startup + resume): ブランチに紐づく PR を検出し skill 起動を促す
- Scripts: `pr-monitor.sh` (監視本体) / `detect-pr.sh` (ブランチ→PR 検出)
