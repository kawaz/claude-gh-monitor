# claude-gh-monitor

> [English](./README.md) | 日本語

Claude Code plugin: GitHub の非同期イベント（PR の状態変化、GitHub Actions workflow run）を Claude Code hooks + Monitor ツール経由で低コンテキストに通知する。

PR を出した後のレビュー待ち・CI 待ちや push 直後の workflow 結果待ちに別作業をしつつ、変化があった時だけ Claude Code のチャットに 1 行で通知されます。`gh pr view` / `gh run watch` を手動で繰り返す必要がありません。

## Install

```bash
claude plugin marketplace add kawaz/claude-gh-monitor
claude plugin install gh-monitor@gh-monitor
```

インストール後、対応するブランチ（= open PR に紐づく bookmark / branch）の worktree で Claude Code を起動すると、SessionStart hook が PR を自動検出し watch-pr の起動を促します。push を実行した直後は PostToolUse hook が workflow run の watch を促します。

本 README で使う用語:

- **hook**: plugin が Claude Code に登録するスクリプト。セッション開始時や tool 実行後に自動で動く (`SessionStart`, `PostToolUse`)
- **skill**: Claude Code が呼び出せる primitive。ここでは Claude に「適切な引数で Monitor を起動して」と指示する役割
- **Monitor ツール**: Claude Code 内蔵のバックグラウンド watcher。emit された stdout 1 行 = chat に 1 件の通知

## インストール後の動作確認

```bash
# 1. open PR のあるブランチの worktree で:
gh pr list --head "$(git branch --show-current)"     # PR が表示されるはず
claude                                                # SessionStart hook 発火
# → `watch-pr: <owner/repo>#<N>` description の Monitor が動くのが期待値

# 2. push (git push / jj git push / just push / pkf run push のいずれか) の直後:
# → `watch-workflow: <owner/repo>` description の Monitor が立ち上がる
# → chat に [run:change] ... status:success|failure ... が流れるのを待つ
```

## 前提

- [GitHub CLI (`gh`)](https://cli.github.com/) と `jq` がインストール済み
- `gh auth login` で対象リポジトリを読める権限で認証済み

  ```bash
  gh auth status      # 現在の認証状態
  gh auth login       # 未認証なら対話形式で登録
  ```

- git worktree または jj workspace 方式のリポジトリ配下で作業

## Features

### Hook: `SessionStart`

セッション開始（`startup` / `resume`）時にカレント worktree のブランチから open PR を検出し、Claude に「watch-pr スキルを起動してほしい」と伝えます。PR が無いブランチでは何もしません。

### Hook: `PostToolUse`

Bash tool で `git push` / `jj git push` / `just push` / `pkf run push` の成功を検出した直後、Claude に「watch-workflow スキルを起動してほしい」と伝えます。push 失敗 (`is_error` / `interrupted`) や非 push コマンドでは何もしません。

### Skill: `watch-pr`

PR ごとに 1 本の Monitor で `watch-pr.sh` を `persistent: true` で常駐させ、状態変化があれば 1 行 emit します。重複防止のために Monitor description は `watch-pr: <owner/repo>#<N>` 規約。

emit 例 (`[scope:action] key:value` 形式):

```
[comment:add] user:alice url:https://github.com/owner/repo/pull/N#issuecomment-123 body:"LGTM"
[review:submit] user:alice state:APPROVED
[ci:change] check:Test status:failure url:https://github.com/owner/repo/actions/runs/...
[pr:merge] user:alice commit:abc1234 at:2026-04-23T02:00:00Z
[pr:close]
```

### Skill: `watch-workflow`

repo ごとに 1 本の Monitor で `watch-workflow.sh` を常駐させ、GitHub Actions workflow run の状態変化を 1 行 emit します。Monitor description は `watch-workflow: <owner/repo>` 規約。起動時刻 - 5 分を cutoff として fast CI も初回 emit に救います ([DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md))。

emit 例:

```
[run:change] workflow:ci.yml id:12345678 status:failure commit:abc1234 branch:main user:kawaz event:push
```

### 自セッション起因イベントの suppress

`watch-pr` のみ、デフォルトで **同じ gh authenticated user (= `gh api user` の `.login`) が起こした comment / review / merge の通知を抑制** します ([DR-0004](docs/decisions/DR-0004-suppress-self-originated-events.md))。Claude 自身が `gh pr comment` 等で発火したイベントが Monitor 経由でエコーバックされて余計な思考ターンを誘発する問題への対策です。

- 起動ログに `[INFO] self filter: login=<your-gh-login>` が 1 行出ます
- `GH_MONITOR_INCLUDE_SELF=1` で suppress を完全に off
- self-merge は `[pr:merge]` emit を抑制しますが watcher は exit 0 で正常終了
- `[ci:change]` は author 情報を持たないため対象外
- `watch-workflow` は self filter を **かけません** (改定)。自分の push の CI 結果も遅延後の有用情報なので emit します

### 共通 emit 形式

すべての通知行は 2 系統:

- **(a) skill 固有のイベント** — `[scope:action] key:value ...` (verb:noun + 構造化 payload)
- **(b) severity メッセージ** — `[INFO|WARN|ERROR] <自由文>` (起動 ack / 障害通知 / 致命エラー)

skill 名 / repo / PR# などのスコープ識別子は Monitor description (= 通知 summary) に逃がし、emit 行からは省略しています。詳細は [docs/DESIGN-ja.md](docs/DESIGN-ja.md) を参照。

### Scripts

- `scripts/watch-pr.sh` — PR 監視本体。Bash + `gh` + `jq`、1 プロセス ~2MB
- `scripts/watch-workflow.sh` — Actions workflow run 監視本体
- `scripts/detect-pr.sh` — カレント worktree のブランチから open PR を検出（git / jj workspace 両対応）

## Development

```bash
just ci                  # lint + validate (CI と同一)
just version             # バージョン表示
just bump-semver         # patch bump (minor / major も引数で指定可)
just push                # 全チェック + version bump 検出 + push
just push-without-bump   # docs only 等で bump 不要な場合
```

## トラブルシューティング

- **`watch-pr` が起動しない**
  1. `git branch --show-current` — 現在のブランチを確認
  2. `gh pr list --head "$(git branch --show-current)"` — open PR があるか
  3. `gh auth status` — 該当 repo への gh 認証は有効か
- **push しても `watch-workflow` が起動しない**
  1. `git remote get-url origin` — origin が GitHub を指しているか
  2. `gh api "repos/<owner>/<repo>/actions/runs?per_page=1"` — API が応答するか
  3. push 自体は Claude Code 内で成功扱いだったか (hook は `is_error: true` / `interrupted: true` だと黙る)
- **通知が来なくなった**
  - Claude Code の TaskList で `watch-*` Monitor が動いているか確認 → 消えていれば再度 hook を発火 (セッション再開 / 再 push)

## ドキュメント

- [docs/DESIGN-ja.md](docs/DESIGN-ja.md) — 設計ドキュメント（背景・アーキテクチャ）
- [docs/decisions/INDEX.md](docs/decisions/INDEX.md) — 設計判断記録 (DR)
- [docs/findings/](docs/findings/) — 検証ログ
- [CHANGELOG.md](CHANGELOG.md) — バージョン履歴

## License

MIT License, Yoshiaki Kawazu (@kawaz)
