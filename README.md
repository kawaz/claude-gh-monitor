# claude-gh-monitor

Claude Code plugin: GitHub の非同期イベント（PR の状態変化、GitHub Actions workflow run）を Claude Code hooks + Monitor ツール経由で低コンテキストに通知する。

PR を出した後のレビュー待ち・CI 待ちに別作業をしつつ、変化があった時だけ Claude Code のチャットに 1 行で通知されます。`gh pr view` や `gh run watch` を手動で繰り返す必要がありません。

## Install

```bash
claude plugin marketplace add kawaz/claude-gh-monitor
claude plugin install gh-monitor@gh-monitor
```

インストール後、対応するブランチ（= open PR に紐づく bookmark / branch）の worktree で Claude Code を起動すると、SessionStart hook が PR を自動検出し Monitor で監視が始まります。

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

### Skill: `watch-pr`

Claude が明示的に「監視して」と言われた時・push/PR 作成直後・SessionStart hook の指示を受け取った時に起動するスキル。`Monitor` ツールで `watch-pr.sh` を `persistent: true` で常駐させ、変化時のみ 1 行を emit します。

通知行例:

| 行頭 | 意味 |
|---|---|
| `[WATCH-START]` | 監視開始 |
| `[COMMENT by LOGIN]` | 新規コメント (本文先頭 200 字) |
| `[REVIEW STATE by LOGIN]` | レビュー提出 (APPROVED / CHANGES_REQUESTED / COMMENTED) |
| `[CI]` | CI check 状態サマリ (変化時のみ) |
| `[MERGED] at ...` / `[CLOSED]` | 終了検出 (直後に exit) |

詳細は `skills/watch-pr/SKILL.md` を参照。

### (予定) watch-workflow

PostToolUse hook で `git push` / `jj git push` / `pkf run push` 等を検出し、その repo の GitHub Actions workflow run を常駐 Monitor で監視。設計詳細は [docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md)。

### Scripts

- `scripts/watch-pr.sh` — PR 監視本体。Bash + `gh` + `jq`、1 プロセス ~2MB
- `scripts/detect-pr.sh` — カレント worktree のブランチから open PR を検出（git / jj workspace 両対応）

## Development

```bash
just validate         # plugin.json の検証
just lint             # shellcheck
just version          # バージョン表示
just bump-version     # パッチバンプ（minor / major も引数で指定可）
just push             # バージョン一致 + validate + lint + push
just push-without-bump
```

## ドキュメント

- [docs/DESIGN.md](docs/DESIGN.md) — 設計ドキュメント（背景・アーキテクチャ）
- [docs/decisions/INDEX.md](docs/decisions/INDEX.md) — 設計判断記録 (DR)
- [docs/findings/](docs/findings/) — 検証ログ
- [CHANGELOG.md](CHANGELOG.md) — バージョン履歴

## License

MIT License, Yoshiaki Kawazu (@kawaz)
