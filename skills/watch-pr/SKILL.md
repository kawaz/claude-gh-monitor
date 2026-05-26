---
description: "Continuously watch a GitHub PR (the one tied to the current session, or one given as argument) and notify on new comments, reviews, CI check changes, and merge/close events via the Monitor tool. Suggest enabling on SessionStart, right after push, or while waiting for reviews/CI — even without explicit instruction. (日本語: 現在のセッションに紐づく GitHub PR の状態変化を Monitor ツールで継続監視し、新規コメント・レビュー・CI・マージ状態の変化を通知する。PR 作業中・push 直後・レビュー待ち・CI 待ちでは明示指示なしでも起動提案してよい。)"
---

# watch-pr

## いつ起動するか

| 状況 | 起動判断 |
|---|---|
| SessionStart hook から `[gh-monitor]` 出力を受け取った | **自動で起動**（ユーザ確認不要） |
| ユーザが "PR 見てて" / "CI 通ったら教えて" / "レビュー来たら知らせて" 等と指示 | **起動** |
| ユーザが push / PR 作成直後に別タスクへ移ろうとしている | **起動を提案** |
| ユーザが「もう使わない」「監視止めて」と明示 | 起動しない。既存 Monitor があれば TaskStop |

## 重複起動の防止（起動前に必ず確認）

起動前に `TaskList` で稼働中の Monitor を確認する。`description` に `watch-pr: <OWNER/REPO>#<N>` を含むタスクが **既にある場合は起動しない**（同じ PR への多重監視はノイズ元）。

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

1セッションで複数 worktree / 複数 PR を触っている場合、PR ごとに個別の Monitor を起動してよい。description を `watch-pr: owner/repo#N` で分けておけば重複判定もそのまま機能する。

## Monitor 起動コマンド

Monitor ツールに以下を渡す:

```
command:     bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-pr.sh <OWNER/REPO> <PR_NUMBER>
description: watch-pr: <OWNER/REPO>#<N>
persistent:  true
```

- `persistent: true` セッション終了まで継続（`timeout_ms` は無視される）
- PR が merged / closed されればスクリプト側で自然終了（exit 0）
- ポーリング間隔は 60s 固定

## 通知行の読み方

emit は 2 系統:

### (a) skill 固有のイベント — `[scope:action] key:value ...` 形式

skill 名 / repo / PR# は Monitor description (= 通知 `<summary>`) で識別する前提で emit からは省略される。残り payload は `key:value`。

| イベント | 後続フィールド | 意味 | アクション目安 |
|---|---|---|---|
| `[comment:add]` | `user:<login> url:<url> body:"..."` | 新規コメント、本文先頭 200 字、URL は深堀用 | 内容を判断しユーザに要約報告 |
| `[review:submit]` | `user:<login> state:<STATE>` | レビュー提出、STATE ∈ {APPROVED, CHANGES_REQUESTED, COMMENTED}。url は gh CLI の json schema に無いため省略 | ユーザに通知 |
| `[ci:change]` | `check:"<name>" status:<status> url:<url>` | 個別 CI check の状態変化（変化時のみ、check 1 つで 1 行）。url は detailsUrl / targetUrl のあるものだけ付く | failure / error / cancelled は url から直接ログにジャンプして詳細取得 |
| `[pr:merge]` | `user:<login> commit:<sha7> at:<timestamp>` | PR マージ検出（スクリプトはこの直後 exit）。mergedBy / mergeCommit が無い場合はその field を省略 | ユーザに完了を報告 |
| `[pr:close]` | (なし) | PR close 検出（exit） | ユーザに通知 |

### (b) severity メッセージ — `[INFO|WARN|ERROR] <自由文>` 形式

skill 固有イベントの構造とは異質。payload は自然文 OK（KV 縛りを緩める）。

| イベント | 例 | アクション目安 |
|---|---|---|
| `[INFO] watch-pr start: <repo>#<N> (interval=...)` | 起動 ack。設定値も含む | 黙殺 (起動確認用) |
| `[INFO] self filter: login=<login>` | self filter ON、`<login>` の発火イベントを suppress 中 (DR-0004) | 黙殺 |
| `[INFO] gh pr view が復旧 (N 回失敗のあと)` | 障害復旧 | 通常は黙殺 |
| `[WARN] self login 取得失敗、self filter off で続行` | `gh api user` 失敗。filter は off で続行 | gh 認証を要確認 |
| `[WARN] gh pr view が N 回連続失敗` | gh 認証 / ネットワーク不調の可能性 | ユーザに要確認を促す |
| `[ERROR] ...` | 致命的なエラー (実装上は usage error 等は stderr) | ユーザに報告 |

## 自セッション起因イベントの suppress (DR-0004)

`gh api user --jq .login` で取得した自 login と一致する author の `[comment:add]` / `[review:submit]` は **デフォルトで emit されません**。Claude 自身が `gh pr comment` 等で発火したイベントの echo を抑制する目的です。

- 起動行の直後に `[INFO] self filter: login=<login>` が 1 回 emit される
- `GH_MONITOR_INCLUDE_SELF=1` を Monitor 起動時の env に渡すと suppress off
- self-merge の `[pr:merge]` も suppress するが exit 0 は変わらず (watcher は閉じる)
- `[ci:change]` は author 情報を持たないため対象外

## 手動停止

- 会話で「監視止めて」と言われた → 対応する Monitor を TaskStop
- セッション終了時 → 自動終了（persistent の挙動）
- PR がマージ/クローズ → スクリプト側が自発的に exit

## 設計の背景

- Bash + `gh` + `jq` のみの実装。1プロセス ~2MB なので多数セッションで起動しても影響小
- ハッシュ比較で「変化時だけ emit」するため Claude のコンテキストを圧迫しない
- 全体ハッシュと CI ハッシュを分離しているので、コメントが動いただけで CI 現状が毎回再通知されるノイズが出ない
- 詳細は リポジトリの [docs/DESIGN.md](../../docs/DESIGN.md) 参照
