---
description: "現在のセッションに紐づく GitHub PR（または引数で指定した任意の PR）の状態変化を Monitor ツールで継続監視し、新規コメント・レビュー・CI・マージ状態の変化を通知する。PR 作業中のセッションでは常に有効化候補。push 直後・レビュー待ち・CI 待ちの文脈では明示指示なしでも起動提案してよい。"
---

# pr-monitor

## いつ起動するか

| 状況 | 起動判断 |
|---|---|
| SessionStart hook から `[claude-pr-monitor]` 出力を受け取った | **自動で起動**（ユーザ確認不要） |
| ユーザが "PR 見てて" / "CI 通ったら教えて" / "レビュー来たら知らせて" 等と指示 | **起動** |
| ユーザが push / PR 作成直後に別タスクへ移ろうとしている | **起動を提案** |
| ユーザが「もう使わない」「監視止めて」と明示 | 起動しない。既存 Monitor があれば TaskStop |

## 重複起動の防止（起動前に必ず確認）

起動前に `TaskList` で稼働中の Monitor を確認する。`description` に `PR <OWNER/REPO>#<N> 監視` を含むタスクが **既にある場合は起動しない**（同じ PR への多重監視はノイズ元）。

別の PR を監視する場合は重複にならないので、追加で起動してよい。

## 監視対象 PR の特定

### (1) 引数で指定された場合

ユーザが `PR #N` / `{owner}/{repo}#N` のように明示した場合はそれを使う。

### (2) 指定がない場合はカレント workspace のブランチから自動検出

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/detect-pr.sh
```

stdout に `OWNER/REPO\tPR_NUMBER` が出れば成功、exit 1 なら PR 無し。PR 無しの場合は起動せず「この worktree には open PR がありません」と報告する。

### (3) 複数 PR を同時監視したい

1セッションで複数 worktree / 複数 PR を触っている場合、PR ごとに個別の Monitor を起動してよい。description を `PR owner/repo#N 監視` で分けておけば重複判定もそのまま機能する。

## Monitor 起動コマンド

Monitor ツールに以下を渡す:

```
command:     bash ${CLAUDE_PLUGIN_ROOT}/scripts/pr-monitor.sh <OWNER/REPO> <PR_NUMBER>
description: PR <OWNER/REPO>#<N> 監視
persistent:  true
timeout_ms:  3600000
```

- `persistent: true` セッション終了まで継続
- PR が merged / closed されればスクリプト側で自然終了（exit 0）
- `PR_MONITOR_INTERVAL`（秒, default=60）で間隔調整可（環境変数）

## 通知行の読み方

Monitor から 1 行ずつ届く。行頭のタグで意味が分かる:

| 行頭 | 意味 | アクション目安 |
|---|---|---|
| `[WATCH-START]` | 監視開始（起動確認） | 特に何もしない（ユーザへの確認不要） |
| `[COMMENT by LOGIN]` | 新規コメント、本文先頭 200 字 | 内容を判断しユーザに要約報告 |
| `[REVIEW STATE by LOGIN]` | レビュー提出、STATE ∈ {APPROVED, CHANGES_REQUESTED, COMMENTED} | ユーザに通知 |
| `[CI]` | CI check 状態サマリ（変化時のみ） | failure があれば内容取得しユーザに報告 |
| `[MERGED] at ...` | PR マージ検出（スクリプトはこの直後 exit） | ユーザに完了を報告 |
| `[CLOSED] ...` | PR close 検出（exit） | ユーザに通知 |
| `[WARN] gh pr view が N 回連続失敗...` | gh 認証・ネットワーク不調の可能性 | ユーザに要確認を促す |
| `[INFO] gh pr view が復旧` | 障害からの復旧 | 通常は黙殺してよい |

## 手動停止

- 会話で「監視止めて」と言われた → 対応する Monitor を TaskStop
- セッション終了時 → 自動終了（persistent の挙動）
- PR がマージ/クローズ → スクリプト側が自発的に exit

## 設計の背景

- Bash + `gh` + `jq` のみの実装。1プロセス ~2MB なので多数セッションで起動しても影響小
- ハッシュ比較で「変化時だけ emit」するため Claude のコンテキストを圧迫しない
- 全体ハッシュと CI ハッシュを分離しているので、コメントが動いただけで CI 現状が毎回再通知されるノイズが出ない
- 詳細は リポジトリの [docs/DESIGN.md](../../docs/DESIGN.md) 参照
