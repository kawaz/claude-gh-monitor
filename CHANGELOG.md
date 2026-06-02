# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

- `.github/workflows/release.yml`: 旧 `vcs:latest-tag()` 構文 (bump-semver v0.29.0 で削除済) を `bump-semver vcs tag latest --include-prerelease --vcs git` + `compare gt` の 2 段構えに置換 ([DR-0020](https://github.com/kawaz/bump-semver/blob/main/docs/decisions/DR-0020-pr-tag-latest.md))。現行 v0.31.1 で旧構文が exit 2 を返し、release.yml の case 文がそれを「初回 release 扱い」で握り潰すため、二重リリース防止の semver guard が完全無効化されていた (workflow は緑のまま、潜在バグ)。canonical (`kawaz/bump-semver/main/.github/workflows/release.yml`) と整合

### Changed

- `justfile`: jj 直書きから `bump-semver vcs` サブコマンド (DR-0020) ベースへ全面 refactor。jj/git 透過化。
  - `ensure-clean`: `jj log -r @ -T empty` → `bump-semver vcs is clean`
  - `check-version-bump` → `check-version-bumped`: 自前 `jj file show` + jq + `jj diff --summary` 手書きブロックを `bump-semver vcs diff -q main@origin -- <paths>` + `bump-semver compare gt <local> vcs:<ref>:<file>` に置換
  - `push` / `push-without-bump`: `jj bookmark set + jj git push` → `bump-semver vcs push --branch main --jj-bookmark-auto-advance`
  - recipe `bump-semver` → `bump-version` rename (コマンド名衝突解消)
  - `version-files` / `bump-trigger-paths` を justfile 先頭で変数定義
  - `check-versions` gate (plugin.json と marketplace.json の version 整合性) は維持

## [0.4.1] - 2026-06-02

### Added

- `scripts/watch-workflow.sh`: SHA-pinned モードに `--no-match-timeout=<dur>` (default 10m) を追加。指定 SHA の matching run が API に現れないまま経過した場合に exit して、誤検出 / 未 push SHA の無駄常駐を防ぐ ([docs/issue/2026-06-02-sha-pinned-no-match-timeout-and-wrong-repo.md](docs/issue/2026-06-02-sha-pinned-no-match-timeout-and-wrong-repo.md))

## [0.4.0] - 2026-06-01

### Added

- `scripts/watch-workflow.sh`: SHA-pinned モード (`--sha <SHA>`) を追加 ([DR-0005](docs/decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md))。指定 commit の workflow run を追跡し、全 check terminal + grace 経過で自走 exit。push のたびに増えても自然 exit するため、複数サブエージェント並列 watch でも RateLimit を圧迫しない

### Changed

- **Breaking**: `scripts/watch-workflow.sh` は mode 明示が必須化 (`--sha` または `--passive`)。どちらも無い起動は exit 2 (誤起動の事前 guard)
- Passive モード (`--passive`) は明示オプトイン化。repo 全体監視 (`<repo>` 単位で 1 本のみ)、idle backoff + `--timeout` 経過で exit

## [0.3.5] - 2026-05-27

### Fixed

- `hooks/post_tool_use.sh`: `additionalContext` に埋める Monitor 起動コマンドの plugin root を literal `${CLAUDE_PLUGIN_ROOT}` から `$0` ベース resolve に変更。`additionalContext` は plugin loader の変数置換対象外で、Claude 本体が Monitor ツールに渡した時点でも置換されないため、watch-workflow が `bash /scripts/watch-workflow.sh ...` で起動して exit 127 になっていた。`session_start.sh` と同じ `SCRIPT_DIR=$(dirname $0)` 方式に統一

### Documentation

- `docs/findings/2026-05-27-claude-plugin-root-substitution-scope.md`: `${CLAUDE_PLUGIN_ROOT}` 置換スコープ表 (どこで置換され / どこでされないか) と実機検証結果を追加

## [0.3.4] - 2026-05-26

### Changed

- **DR-0004 改定**: `scripts/watch-workflow.sh` の self-actor filter を撤廃 ([DR-0004](docs/decisions/DR-0004-suppress-self-originated-events.md))。0.3.3 で導入した「自セッションの push で trigger された workflow run を suppress」は、dogfooding で「自分の push でも CI 結果は数分後の遅延通知で価値ある情報」と判明したため撤回。watch-workflow は actor に関わらず emit する
- `scripts/watch-pr.sh` 側 (comment / review / merge) の self filter はそのまま継続
- `tests/run-tests.sh`: watch-workflow のテストを「actor に関わらず全 run emit」に書き換え
- docs/{DESIGN,DESIGN-ja,README,README-ja,skills/watch-workflow/SKILL,decisions/INDEX}: 改定に追従

## [0.3.3] - 2026-05-26

### Added

- `scripts/watch-pr.sh` / `scripts/watch-workflow.sh`: 自セッション (= 同じ gh authenticated user) 起因の comment / review / workflow run をデフォルト suppress ([DR-0004](docs/decisions/DR-0004-suppress-self-originated-events.md))。Claude 自身が `gh pr comment` 等で発火したイベントが echo されて余計な思考ターンを誘発するのを防ぐ。`GH_MONITOR_INCLUDE_SELF=1` で suppress off
- `scripts/watch-pr.sh`: self-merge の `[pr:merge]` emit を抑制 (exit 0 は維持)
- `tests/run-tests.sh`: gh コマンドを stub した self filter の smoke test を追加、`just test` / `just ci` で実行
- `scripts/watch-pr.sh` / `scripts/watch-workflow.sh`: `WATCH_PR_INTERVAL` / `WATCH_WORKFLOW_INTERVAL` env でポーリング間隔を上書き可能に (主にテスト用、デバッグでも有用)

## [0.3.2] - 2026-05-26

### Security

- `hooks/post_tool_use.sh`: origin remote URL のパース regex を `^(https?://|ssh://(git@)?|git@)github\.com[:/]...` に厳密化。従来は `github.com/...` 部分文字列マッチで `https://attacker.com/github.com/hacker/...` のような中間詐称を accept する可能性があった
- `scripts/watch-pr.sh` / `scripts/watch-workflow.sh`: `quote_value()` に backslash と改行のエスケープを追加。GitHub API が返す値に control char が含まれた場合に emit 行境界が壊れるのを防ぐ
- `.github/workflows/ci.yml`: `permissions: contents: read` を明示 (最小権限原則)

### Changed

- `.github/workflows/ci.yml`: shellcheck install を `shellcheck --version || apt install` に変更 (pre-install されていれば apt update をスキップして高速化)、`timeout-minutes: 10` を追加 (hang 防止)
- `scripts/watch-workflow.sh`: `known_state` の GC を追加。poll で取得した run id 集合に含まれないキーは unset (per_page=100 から押し出された古い run のメモリ圧迫対策)

## [0.3.1] - 2026-05-26

### Changed

- justfile を kawaz/* 横断ルールに揃える: `bump-version` レシピを `bump-semver` に改名、手書き jq の 2 ファイル書き換えを `bump-semver --write` の 1 行に置換、新 `ci` レシピ (lint + validate) を追加、`push` の deps を `ci` に追従
- `.github/workflows/`: 旧 `shellcheck.yml` を廃止し `ci.yml` に統合 (setup-bun + setup-just + `just ci`)
- `.github/dependabot.yml` 新設 (github-actions weekly)
- README / docs/DESIGN を翻訳ペア化 (`README-ja.md` 原本 + `README.md` 英訳、`docs/DESIGN-ja.md` + `docs/DESIGN.md`)。冒頭に相互リンク blockquote

### Removed

- `docs/issue/2026-05-09-migrate-justfile-and-ci-and-dependabot.md` (本リリースで解決)
- `docs/issue/2026-05-09-migrate-to-docs-structure.md` (本リリースで解決)

## [0.3.0] - 2026-05-26

### Added

- `watch-workflow` 機能を実装: `gh api /repos/<owner>/<repo>/actions/runs` を 30s 間隔で poll し、状態変化を 1 行 emit ([DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md))
- PostToolUse hook を追加: Bash tool の `git`/`jj`/`just`/`pkf` push 成功を検出して `watch-workflow` 起動を促す ([DR-0002](docs/decisions/DR-0002-hook-minimal-output.md))
- `skills/watch-workflow/SKILL.md` 新設

### Changed

- 全 skill の emit format を統一:
  - (a) skill 固有のイベント: `[scope:action] key:value ...` (verb:noun)
  - (b) severity メッセージ: `[INFO|WARN|ERROR] <自由文>` (起動 ack / 障害通知)
  - skill 名 / repo / PR# などのスコープ識別子は Monitor description (= 通知 summary) に逃がし、emit 行から省略
- watch-pr の CI 通知を「全 check サマリ 1 行」から「変化のあった check 1 つにつき 1 行」に変更
- watch-pr の `[pr:merge]` に user / commit (sha7) を追加
- watch-pr の `[comment:add]` に url を追加
- watch-pr の `[ci:change]` に url (detailsUrl / targetUrl) を追加

## [0.2.0] - 2026-05-26

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
