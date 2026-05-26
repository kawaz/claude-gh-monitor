# Claude Code Plugin: gh-monitor

## 概要

GitHub の非同期イベント（PR の状態変化 + GitHub Actions workflow run）を Claude Code の Monitor ツール経由で低コンテキストに通知する。

実装機能:

- **watch-pr**: ブランチに紐づく GitHub PR の状態変化（コメント / レビュー / CI / マージ）。SessionStart hook で PR を検出して skill 起動を促す
- **watch-workflow**: GitHub Actions workflow run の start / success / failure 等。PostToolUse hook で push を検出して skill 起動を促す（[DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md)）

## 3-layer 構造

| Layer | watch-pr | watch-workflow |
|-------|----------|----------------|
| Hook | `hooks/hooks.json` + `hooks/session_start.sh` | `hooks/hooks.json` + `hooks/post_tool_use.sh` |
| Skill | `skills/watch-pr/SKILL.md` | `skills/watch-workflow/SKILL.md` |
| Scripts | `scripts/watch-pr.sh` / `scripts/detect-pr.sh` | `scripts/watch-workflow.sh` |

## 設計原則

- **Hook は最小指示だけ、Monitor 起動は Claude の仕事**: hook で直接常駐プロセスを起こさない（[DR-0002](docs/decisions/DR-0002-hook-minimal-output.md)）
- **変化時のみ emit**: PR 全体ハッシュと CI ハッシュを独立管理し、不要な再通知を抑止
- **repo 単位の常駐 Monitor**: watch-workflow は 1 repo = 1 Monitor で push ごとに増殖させない（[DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md)）
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

詳細設計は [docs/DESIGN.md](docs/DESIGN.md)、設計判断は [docs/decisions/INDEX.md](docs/decisions/INDEX.md) を参照。
