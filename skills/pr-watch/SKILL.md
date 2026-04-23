---
name: pr-watch
description: 現在のセッションに紐づく GitHub PR（または引数で指定した任意の PR）の状態変化を Monitor ツールで継続監視し、新規コメント・レビュー・CI・マージ状態の変化を通知する。PR 作業中のユーザーは基本全てのセッションで使うので、ユーザーが明示的に「監視して」と言わなくても、PR を作業しているセッションでは積極的に起動候補として検討すること。レビュー待ち・CI 完了待ち中に別作業を進めたい時に有用。
---

# pr-watch

## いつ起動するか

- SessionStart hook から自動提案された時（最優先）
- ユーザーが "PR を見てて" / "CI が通ったら教えて" / "レビュー来たら知らせて" と指示した時
- push / PR作成直後に、ユーザーが確認せず他作業に移ろうとしている時（起動を提案）

既に同じ PR を監視している Monitor が動いているか必ず確認してから起動する（重複は害）。

## 監視対象の特定

1. 引数で PR が指定されていればそれを使う: `{owner}/{repo} #N`
2. 指定が無ければ現在の worktree のブランチから検出:
   ```bash
   bash ${HOME}/.local/share/repos/github.com/kawaz/claude-pr-monitor/main/scripts/detect-pr.sh
   ```
   stdout に `OWNER/REPO\tPR_NUMBER` が出る。exit 1 なら PR 無し（そのまま終了）。

## 起動方法

Monitor ツールに以下を渡す:

```
command:     bash ${HOME}/.local/share/repos/github.com/kawaz/claude-pr-monitor/main/scripts/pr-watch.sh <OWNER/REPO> <PR_NUMBER>
description: PR <OWNER/REPO>#<N> 監視
persistent:  true
timeout_ms:  3600000
```

`persistent: true` なのでセッション終了まで継続。PR が merged / closed されればスクリプト側で exit 0 して自然終了する。

## 通知の読み方

Monitor から以下のいずれかの行が届く:

| 行頭 | 意味 |
|---|---|
| `[WATCH-START]` | 監視開始（起動確認用、1回のみ） |
| `[COMMENT by LOGIN]` | 新規コメント。本文先頭200文字 |
| `[REVIEW STATE by LOGIN]` | レビュー提出。STATE は APPROVED / CHANGES_REQUESTED / COMMENTED |
| `[CI]` | CI check 状態サマリ（変化時のみ） |
| `[MERGED] at ...` | PR マージ検出。この直後 exit |

## 手動停止

不要になったら Monitor を TaskStop で止める。セッション終了でも自動終了する。

## 設計の背景

- Bash + `gh` + `jq` で書いてあり、1プロセスあたり ~2MB と軽量（多数セッションで起動されても影響が小さい）
- ハッシュ比較で「変化時だけ emit」するため Claude のコンテキストを圧迫しない
- 詳細は リポジトリの [docs/DESIGN.md](../../docs/DESIGN.md) 参照
