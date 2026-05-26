---
description: "Watch GitHub Actions workflow runs (CI / lint / release / dispatch, etc.) per repository via the Monitor tool and emit one-line notifications on state changes (queued / in_progress / success / failure / cancelled / timed_out / action_required). PostToolUse hook prompts launching this skill right after a successful `git/jj/just/pkf push`. Suggest enabling after push, while waiting for CI, or to watch release workflows — even without explicit instruction. (日本語: GitHub Actions の workflow run を repo 単位で継続監視し、状態変化を 1 行通知する。push 直後・CI 通過待ち・release workflow 監視では明示指示なしでも起動候補。)"
---

# watch-workflow

## いつ起動するか

| 状況 | 起動判断 |
|---|---|
| PostToolUse hook から `[gh-monitor]` 出力を受け取った | **自動で起動**（ユーザ確認不要） |
| ユーザが "CI 見てて" / "release workflow 通ったら教えて" 等と指示 | **起動** |
| ユーザが push 直後に別タスクへ移ろうとしている | **起動を提案** |
| ユーザが「もう使わない」「監視止めて」と明示 | 起動しない。既存 Monitor があれば TaskStop |

## 重複起動の防止（起動前に必ず確認）

起動前に `TaskList` で稼働中の Monitor を確認する。`description` に `watch-workflow: <OWNER/REPO>` を含むタスクが **既にある場合は起動しない**。

watch-workflow は **repo 単位の常駐 1 本** が設計（DR-0003）。同じ repo に複数立てない。別の repo を監視するなら別の Monitor を追加でよい。

## 監視対象 repo の特定

### (1) 引数で指定された場合

ユーザが `kawaz/foo` のように明示した場合はそれを使う。

### (2) 指定がない場合は CLAUDE_PROJECT_DIR の origin remote から自動検出

```bash
git -C "$CLAUDE_PROJECT_DIR" config --get remote.origin.url
```

`https://github.com/<owner>/<repo>(.git)?` または `git@github.com:<owner>/<repo>(.git)?` を `<owner>/<repo>` にパース。

remote が GitHub 以外、または取れない場合は起動せず「この workspace の origin remote は GitHub の repo を指していません」と報告する。

## Monitor 起動コマンド

Monitor ツールに以下を渡す:

```
command:     bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-workflow.sh <OWNER/REPO>
description: watch-workflow: <OWNER/REPO>
persistent:  true
```

- `persistent: true` セッション終了まで継続（`timeout_ms` は無視される）
- repo 単位の常駐なので、スクリプトは自分で exit しない（外部 kill か session end のみ）
- ポーリング間隔は 30s 固定、起動時刻 - 5 分を cutoff として fast CI も初回 emit に救う

## 通知行の読み方

emit は 2 系統:

### (a) skill 固有のイベント — `[scope:action] key:value ...` 形式

skill 名 / repo は Monitor description (= 通知 `<summary>`) で識別する前提で emit からは省略される。残り payload は `key:value`。

watch-workflow は run の状態変化のみ:

```
[run:change] workflow:<name> id:<id> status:<status> commit:<sha7> branch:<branch> user:<actor> event:<event>
```

status の語彙（gh 準拠、フラット化）:

| status | 意味 | アクション目安 |
|---|---|---|
| `queued` | キュー投入 | 通常黙殺 |
| `in_progress` | 実行中 | 通常黙殺 |
| `success` | 完了・成功 | ユーザに「CI 通った」を報告 |
| `failure` | 完了・失敗 | **即報告**。`gh run view <id> --log-failed --repo <repo>` で深堀候補 |
| `cancelled` | 完了・キャンセル | 内容次第で報告 |
| `skipped` | 完了・スキップ | 通常黙殺 |
| `timed_out` | 完了・タイムアウト | **報告** |
| `action_required` | 完了・手動承認待ち | **報告** |
| `neutral` / `stale` / `startup_failure` 等 | gh の他語彙 | 内容を見て判断 |

event は run の trigger 種別（`push` / `pull_request` / `workflow_dispatch` / `schedule` 等）。filter 用情報として活用可。

### (b) severity メッセージ — `[INFO|WARN|ERROR] <自由文>` 形式

skill 固有イベントの構造とは異質。payload は自然文 OK（KV 縛りを緩める）。

| イベント | 例 | アクション目安 |
|---|---|---|
| `[INFO] watch-workflow start: <repo> (interval=..., lookback=...)` | 起動 ack。設定値も含む | 黙殺 (起動確認用) |
| `[INFO] self filter: login=<login>` | self filter ON、`<login>` 起因の run を suppress 中 (DR-0004) | 黙殺 |
| `[INFO] gh api が復旧 (N 回失敗のあと)` | 障害復旧 | 通常は黙殺 |
| `[WARN] self login 取得失敗、self filter off で続行` | `gh api user` 失敗。filter は off で続行 | gh 認証を要確認 |
| `[WARN] gh api が N 回連続失敗` | gh 認証 / ネットワーク不調の可能性 | ユーザに要確認を促す |
| `[ERROR] ...` | 致命的なエラー (実装上は usage error 等は stderr) | ユーザに報告 |

監視起動の ack は出さない（Monitor description で起動は把握できる）。baseline 構築までは無出力。

## 自セッション起因 run の suppress (DR-0004)

`gh api user --jq .login` で取得した自 login と一致する run actor の `[run:change]` は **デフォルトで emit されません**。Claude 自身が `pkf run push` で発火した run の echo を抑制する目的です。

- 起動行の直後に `[INFO] self filter: login=<login>` が 1 回 emit される
- `known_state` には状態を記録するので、他者が同 run を再実行した場合の差分検出は維持される
- `GH_MONITOR_INCLUDE_SELF=1` を Monitor 起動時の env に渡すと suppress off
- 同じリリースが他者の dispatch で再実行された場合等は、actor がそちらに切り替わるので emit される

## 手動停止

- 会話で「監視止めて」と言われた → 対応する Monitor を TaskStop
- セッション終了時 → 自動終了（persistent の挙動）

## 設計の背景

- repo 単位の常駐 1 本（DR-0003）。push のたびに増殖しない
- `gh api /repos/<owner>/<repo>/actions/runs?per_page=100` を 30s 間隔で poll し、起動時刻 - 5 分の lookback で fast CI を初回 emit に救う
- 起動時刻より前の完了 run は emit しないので、push 検出より前から動いていた他人 run の過去履歴で会話を汚さない
- 詳細は リポジトリの [docs/DESIGN.md](../../docs/DESIGN.md) と [DR-0003](../../docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md) 参照
