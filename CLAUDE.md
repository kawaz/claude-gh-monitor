# Claude Code Plugin: pr-monitor

## 概要

- ブランチに紐づく GitHub PR の状態変化（コメント / レビュー / CI / マージ）を Monitor ツール経由で通知
- SessionStart hook で PR を検出し、Claude に skill 起動を促す

## 3-layer 構造

| Layer | Files | Role |
|-------|-------|------|
| Hook | `hooks/hooks.json` + `hooks/session_start.sh` | SessionStart で PR を検出し Claude に起動指示を出す |
| Skill | `skills/pr-monitor/SKILL.md` | Monitor 起動時の引数 / 通知行の意味 / 重複防止手順 |
| Scripts | `scripts/pr-monitor.sh` / `scripts/detect-pr.sh` | 実ロジック（Bash + gh + jq） |

## 設計原則

- **Hook は指示だけ、Monitor 起動は Claude の仕事**: hook で直接常駐プロセスを起こさない
- **変化時のみ emit**: PR 全体ハッシュと CI ハッシュを独立管理し、不要な再通知を抑止
- **軽量**: Bash + gh + jq のみ。1 プロセス ~2MB

## 開発

```bash
just validate         # プラグイン検証
just lint             # shellcheck
just version          # バージョン表示
just bump-version     # バージョンバンプ（patch）
just push             # バージョン一致 + validate + lint + push
just push-without-bump
```

詳細設計は [docs/DESIGN.md](docs/DESIGN.md) を参照。
