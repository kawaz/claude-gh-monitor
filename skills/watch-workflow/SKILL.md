---
description: "Watch GitHub Actions workflow runs via the Monitor tool and emit one-line notifications on state changes. Two modes: SHA-pinned (recommended for own work — pin to a specific commit, auto-exit when all checks reach terminal state) and Passive (opt-in, repo-wide, idle backoff, runs until --timeout). PostToolUse hook prompts launching this skill in SHA-pinned mode right after `git/jj/just/pkf push`. Suggest enabling after push or while waiting for CI — even without explicit instruction. Prefer SHA-pinned to avoid leaving idle pollers behind. (日本語: GitHub Actions の workflow run を Monitor 経由で監視し、状態変化を 1 行通知。SHA-pinned モード=特定コミットを追跡し全 check 終了で自動 exit (自分作業の第一推奨)、Passive モード=repo 全体を idle backoff 付きで監視 (明示オプトイン)。push 直後は SHA-pinned で起動するのが基本。)"
---

# watch-workflow

GitHub Actions workflow run の状態変化を 1 行通知する skill。**SHA-pinned (推奨)** と **Passive (オプトイン)** の 2 モード。

## モードの使い分け (重要)

| モード | 用途 | 終了条件 |
|---|---|---|
| **SHA-pinned** (第一推奨) | 自分の push を見届ける / 特定コミットの CI 結果を見る | 指定 SHA のチェックが全て terminal state に到達したら自動 exit |
| Passive (オプトイン) | repo 全体をだらだら見守る / 他人の push も含めて変化を捕まえる | `--timeout` (デフォルト 24h) または手動 stop |

**だらだら見たい需要は少ない**。「CI 見て」「push したけど後で結果欲しい」等の指示は **基本 SHA-pinned**。明示的に「repo 全体を見守って」「リリース workflow が走ったら教えて」のような repo 横断の意図がある場合のみ Passive。

## いつ起動するか

| 状況 | 起動判断 |
|---|---|
| PostToolUse hook から `[gh-monitor]` 出力 (push 検知) を受け取った | **SHA-pinned で自動起動** (ユーザ確認不要) |
| ユーザが push 直後に別タスクへ移ろうとしている | **SHA-pinned で起動を提案** |
| ユーザが「この PR の CI 見てて」「コミット X の結果待ち」等と特定対象を指示 | **SHA-pinned で起動** |
| ユーザが「repo 全体を見守って」「他人 push も含めて」と明示 | **Passive で起動** |
| ユーザが単に「CI 見てて」と曖昧に言った | 「直近の push を追跡しますか? それとも repo 全体ですか?」と確認、推奨は SHA-pinned |
| ユーザが「もう使わない」「監視止めて」と明示 | 起動しない。既存 Monitor があれば TaskStop |

## SHA-pinned モード (推奨)

### 重複起動の防止

`TaskList` で稼働中 Monitor を確認。`description` が `watch-workflow: <OWNER/REPO>@<SHA7>` と **同一 (repo, SHA) で完全一致** する場合は起動しない。

**別 SHA は並列許可**。連続 push で「直前 push の CI も並行で見届けたい」需要に応える。自然 exit するので積み上がらない。

### SHA の特定

- PostToolUse hook 経由なら additionalContext に埋め込まれた値を使う
- ユーザが明示した場合 (`コミット abc1234 の CI 見てて` 等) はそれを使う
- 「直近の push の CI」を頼まれた場合は `git -C "$CLAUDE_PROJECT_DIR" rev-parse HEAD` で取得
- SHA は完全 SHA (40 文字) または 7 文字以上の prefix。watch スクリプト側で実際の run と prefix マッチさせる

### Monitor 起動コマンド

```
command:     bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-workflow.sh --sha <SHA> <OWNER/REPO>
description: watch-workflow: <OWNER/REPO>@<SHA7>
persistent:  true
```

- `persistent: true`: セッション終了 or 自然 exit まで継続
- exit 条件: 指定 SHA に紐づく run が 1 つ以上観測されており、それら全てが terminal state (success/failure/cancelled/timed_out/action_required/skipped/neutral/stale/startup_failure)、かつ「最後に新規 matching run または state transition を観測してから grace window 経過 (デフォルト 60s)」
- grace window は late-arriving run / `workflow_run` cascade / 後追い dispatch を取りこぼさないための救済
- re-run policy: **監視中**に再実行された run はそのまま追う (terminal に戻るまで継続)。**自然 exit 後**の再実行は対象外 (必要なら再起動)
- **no-match-timeout** (デフォルト 10m): 指定 SHA に紐づく run を一度も観測できないまま経過したら exit する。未 push の SHA / 誤検出 repo / workflow 不在 repo を pin した場合に 24h 張り付くのを防ぐ (= grace とは別パラメータ)
- queue 詰まり等の救済として安全 timeout (デフォルト 24h) が走る

## Passive モード (明示的オプトイン)

「repo 全体を見守りたい」「他人 push の CI / リリース workflow も含めて捕まえたい」用途。**SHA-pinned で済む需要はそちらを優先**すること。

### 重複起動の防止

`description` が `watch-workflow: <OWNER/REPO>` (SHA 部なし) と一致する Monitor が既にあれば起動しない (DR-0003: repo 単位 1 本)。

Passive と SHA-pinned は **同 repo に同居可能** (description が異なる)。Passive で全体を見つつ、特定 push は SHA-pinned で別途追跡してよい。

### Monitor 起動コマンド

```
command:     bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-workflow.sh --passive [--max-interval=10m] [--timeout=24h] <OWNER/REPO>
description: watch-workflow: <OWNER/REPO>
persistent:  true
```

- `--passive` は **必須**。明示的オプトイン。`--sha` も `--passive` も無い起動は exit 2 (エラー終了)。これは「だらだら起動の事前 guard」(WARN だと起動後にしか気付けない)
- idle backoff: 初期 30s、`--max-interval` 上限まで指数的 (×1.5) に伸ばす
- reset trigger: workflow run の新規発火 / 既存 run の state 遷移
- `--timeout` 経過で自走 exit (デフォルト 24h)

## 監視対象 repo の特定

### (1) 引数で指定された場合

ユーザが `kawaz/foo` のように明示した場合はそれを使う。

### (2) 指定がない場合は CLAUDE_PROJECT_DIR の origin remote から自動検出

```bash
git -C "$CLAUDE_PROJECT_DIR" config --get remote.origin.url
```

`https://github.com/<owner>/<repo>(.git)?` または `git@github.com:<owner>/<repo>(.git)?` を `<owner>/<repo>` にパース。

remote が GitHub 以外、または取れない場合は起動せず「この workspace の origin remote は GitHub の repo を指していません」と報告する。

## 通知行の読み方

emit は 2 系統:

### (a) skill 固有のイベント — `[scope:action] key:value ...` 形式

skill 名 / repo は Monitor description (= 通知 `<summary>`) で識別する前提で emit からは省略される。残り payload は `key:value`。

watch-workflow は run の状態変化のみ:

```
[run:change] workflow:<name> id:<id> status:<status> commit:<sha7> branch:<branch> user:<actor> event:<event>
```

status の語彙 (gh 準拠、フラット化):

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

event は run の trigger 種別 (`push` / `pull_request` / `workflow_dispatch` / `schedule` 等)。filter 用情報として活用可。

### (b) severity メッセージ — `[INFO|WARN|ERROR] <自由文>` 形式

skill 固有イベントの構造とは異質。payload は自然文 OK (KV 縛りを緩める)。

| イベント | 例 | アクション目安 |
|---|---|---|
| `[INFO] watch-workflow start: <repo> (mode=sha-pinned sha=<SHA7> grace=...)` または `(mode=passive max-interval=..., timeout=...)` | 起動 ack | 黙殺 (起動確認用) |
| `[INFO] gh api が復旧 (N 回失敗のあと)` | 障害復旧 | 通常は黙殺 |
| `[INFO] all checks reached terminal state, grace window elapsed, exiting` | SHA-pinned 完了による自走 exit | 黙殺 |
| `[WARN] gh api が N 回連続失敗` | gh 認証 / ネットワーク不調の可能性 | ユーザに要確認を促す |
| `[ERROR] mode required: --sha <SHA> or --passive` | 起動 mode 未指定 (= 誤起動の事前 guard) | 起動失敗。コマンドに `--sha <SHA>` を付けて再試行 |
| `[ERROR] ...` | その他致命的なエラー | ユーザに報告 |

## self filter について (DR-0004 改定の結果)

watch-workflow には **self filter はかかりません** (DR-0004 改定)。自セッションの push で trigger された CI/release workflow run も emit されます。理由は「CI 結果は数分後の遅延通知で価値ある情報、自分の push 由来でも知りたい」から。中間遷移 (queued / in_progress) の冗長性は別問題 (Followup #1) で扱います。

`[comment:add]` / `[review:submit]` 側の self filter は watch-pr に残っており、そちらは初版どおりデフォルト ON です。

## 手動停止

- 会話で「監視止めて」と言われた → 対応する Monitor を TaskStop
- SHA-pinned は対象 SHA の全 check が terminal に到達したら自動 exit
- Passive は `--timeout` (デフォルト 24h) で自走 exit
- セッション終了時 → 自動終了 (persistent の挙動)

## 設計の背景

- **SHA-pinned (本 issue 2026-06-01)**: 自分作業を見届ける用途では指定 SHA の terminal 到達で自走 exit。並列許可で連続 push も並行追跡可能。エージェントの「停止し忘れ」が構造的に発生しない
- **Passive (DR-0003 を精緻化)**: repo 単位常駐 1 本ルールは維持しつつ、idle backoff + safety timeout を追加。「だらだら見」需要に対する RateLimit 配慮
- 詳細は [DR-0005](../../docs/decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md) (SHA-pinned + Passive opt-in 化)、過去判断は [DR-0003](../../docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md) (Passive 限定と再解釈) / [DR-0004](../../docs/decisions/DR-0004-suppress-self-originated-events.md) 参照
- 将来: 同一 repo を見る並列セッション間で API キャッシュを共有 (single-flight + XDG_CACHE_HOME / XDG_STATE_HOME) → RateLimit 根治
