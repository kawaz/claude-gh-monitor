# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-04-23

### Added

- Initial plugin release
- Skill `pr-monitor`: PR 状態変化を Monitor ツール経由で通知
- Hook `SessionStart` (startup + resume): ブランチに紐づく PR を検出し skill 起動を促す
- Scripts: `pr-monitor.sh` (監視本体) / `detect-pr.sh` (ブランチ→PR 検出)
