# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed (BREAKING)

- プラグイン名 `pr-monitor` → `gh-monitor` に改名 + スコープ拡大（[DR-0001](docs/decisions/DR-0001-rename-and-scope-expand.md)）。インストールコマンドは `claude plugin install gh-monitor@gh-monitor` に変更
- リポジトリ名: `kawaz/claude-pr-monitor` → `kawaz/claude-gh-monitor`
- skill 名: `pr-monitor` → `watch-pr`（`gh-monitor:` prefix と組み合わせて `gh-monitor: watch pr` という英語語順で読めるよう verb-noun に統一。`watch-workflow` も同じ命名規則）
- スクリプト: `scripts/pr-monitor.sh` → `scripts/watch-pr.sh`
- SessionStart hook の出力プレフィックス: `[claude-pr-monitor]` → `[gh-monitor]`
- Monitor の重複防止 description 規約: `PR <repo>#<N> 監視` → `watch-pr: <repo>#<N>`

### Added

- DR-0001/0002/0003 を起票（`docs/decisions/`）
- `watch-workflow` 機能の設計（実装は次回以降。[DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md)）

### Removed

- `evals/`（skill-creator の eval 成果物、超初期のゴミ）
- `HANDOFF-PROMPT.md`（旧ハンズオフ、スコープ刷新で陳腐化）
- 環境変数 `PR_MONITOR_INTERVAL` / `PR_MONITOR_FAIL_WARN` を削除。デフォルト値 (60s / 5) を `watch-pr.sh` 内にハードコード。alpha 段階でチューニング実需が無いため (将来必要になれば `--interval` 等の CLI option で再導入)

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
