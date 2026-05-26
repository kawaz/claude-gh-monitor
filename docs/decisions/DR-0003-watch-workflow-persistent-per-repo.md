# DR-0003: watch-workflow は repo 単位の常駐 Monitor 1 本

- ステータス: Accepted
- 日付: 2026-05-25
- 関連: DR-0001 (改名 + スコープ拡大), DR-0002 (hook 出力最小化), `scripts/watch-workflow.sh` (新規予定), `hooks/hooks.json`

## 文脈

新規 `watch-workflow` 機能の実装にあたり、起動戦略に複数の選択肢がある:

| 案 | 戦略 |
|----|------|
| α | push のたびに新しい Monitor を立てる (push ↔ run の 1:1) |
| β | repo 単位で 1 本の Monitor を `persistent: true` で常駐させる |
| γ | SessionStart で repo を検出して即常駐 |

push 検出のトリガとして PostToolUse hook を使うこと、Monitor の `persistent: true` 指定で長時間ポーリングできることは前提として確定済み (DR-0002 と関連)。

## 決定

**`watch-workflow` は repo 単位の常駐 Monitor 1 本にする (案 β)。**

- 重複キー: Monitor description = `watch-workflow: <user/repo>`
- 起動コマンド: `command: watch-workflow.sh <user/repo>`, `persistent: true`
- トリガ: **PostToolUse hook での push 検出** (SessionStart 案 γ は不採用、後述)。hook は plain stdout ではなく JSON の `hookSpecificOutput.additionalContext` に Monitor 起動指示を載せて返す ([DR-0002](./DR-0002-hook-minimal-output.md) 参照)
- 動作: スクリプトはその repo の workflow run を継続 poll し、状態変化を 1 行で emit し続ける

push はあくまで「Monitor をまだ立てていなければ立てる」きっかけ。最初の push で 1 本立ち、以降の push は既存 Monitor がカバーするため push ごとに増殖しない。

## 理由

1. **常駐 poll なら自分発 / 他人発を区別する必要が消える**
   - 案 α だと push のたびに「どの run を見るか」の同定が必要 (workflow_run.head_sha == push.commit など)。GitHub API のラグでマッチに失敗するケースもある
   - β は repo の全 workflow run を素直に拾うだけなので、起動側の同定ロジックが不要
2. **Monitor の persistent モデルとの相性**
   - `persistent: true` 指定で Monitor は長時間 1 本のプロセスとして走る前提。`timeout_ms` も無視される
   - 「1 push = 1 Monitor」だと Monitor の数が push 回数に比例して肥大化する
3. **push ごとに Monitor が増殖しない**
   - 重複防止は DR-0002 の description マッチで成立
   - 1 セッション中に何度 push しても、Monitor は repo ごとに 1 本に収まる

## emit 足切り (codex 2 回分のレビューで修正済み)

当初は **「起動時刻以降に `created` された run のみ emit」** という方針だったが、PostToolUse hook は `git push` 完了**後**に動くため、その時点で監視したい run は既に created 済みであり **初回 push の run を取りこぼす**。

これを「起動時点で `queued` / `in_progress` の run を baseline に取り込み、completed の古い run だけ抑止」に修正したが、これにもまだ穴がある — **fast CI** (数秒で終わる lint チェック等) は `git push` → hook → Claude による Monitor 起動 → 初回 poll の間に `completed` まで到達してしまい、未完了 run には引っかからず、初回 emit 抑止で見落とされる。

**確定方針** (cutoff を明示的に定義する):

> Monitor 起動時刻 (`startedAt`) から **過去 N 分** (初期実装は `N=5`) を `cutoff = startedAt - N分` とする。
>
> 初回 poll で取得した run のうち、以下を **emit 対象に含める**:
>
> 1. status が `queued` / `in_progress` の run (= 未完了) — 以後の状態変化も追跡
> 2. status が `completed` で、かつ `updatedAt >= cutoff` の run — 即 emit (fast CI 救済)
>
> それ以外 (= `completed` かつ `updatedAt < cutoff` の古い run) **だけ** 抑止する。
> 2 周目以降は通常通り、状態変化があれば emit。

cutoff として「hook が trigger timestamp を Monitor 起動指示に渡す」案もあるが、hook と script の I/F を増やすコストの割に精度向上が限定的なため、初期実装では **script 起動時刻からの固定 lookback** で足りる。`N` の値は運用しながら調整。

実装パターンとしては、現 `pr-monitor.sh` の「初回ループの run-id 集合をスキップリストに記録」を流用しつつ、スキップリスト構築時に上記 cutoff フィルタを噛ます形になる。

## トリガ選択: PostToolUse vs SessionStart

|  | PostToolUse (push 検出) | SessionStart (repo 検出) |
|--|-------------------------|--------------------------|
| 起動タイミング | 初回 push の直後 | セッション開始時に即 |
| 無駄な常駐 | 起きない (push しなければ Monitor も立たない) | 起きる (調査だけのセッションでも常駐) |
| 個人用途の実感 | 「push して初めて CI が気になる」と一致 | 過剰 |

**PostToolUse を採用、SessionStart 案は不採用。** 個人用途の実態は「push して初めて CI が気になる」のがほぼ全てで、Actions を走らせないセッション (調査・読書) で常駐する価値は乏しい。手動起動の余地は invocable skill 案 (未決論点) で別途残す。

### push 検出 regex (確定版)

```
(^|[(;&|])\s*((jj\s+)?git|just|pkf\s+run)\s+push\b
```

- `[(;&|]` でコマンド区切り `(` `;` `&` `|` をカバー (`&&` `||` も末尾 1 文字がマッチするのでカバーされる)
- regex は **緩くてよい**。PostToolUse はプロンプト注入のみで push をブロックしないため、誤マッチ = 余計な一言、取りこぼし = watch 漏れ、で両方とも害は軽微
- **精度の本体は tool_response の成否判定**: PostToolUse hook は Bash tool の実行結果 (`tool_response` JSON) を input 経由で受け取れる。push 失敗 (exit code 非 0 等) の場合は context 注入をスキップする (watch 不要)。具体的なフィールド名・schema は実装時に Claude Code hooks の最新仕様を確認すること

### `<user/repo>` の決定方法

workflow hook には `detect-pr.sh` 相当の補助がない。初期実装は **session cwd (`CLAUDE_PROJECT_DIR`) の `origin` remote が指す repo のみ対応**とする。

`git -C <別repo> push` / `cd <別repo> && git push` / 別 remote への push などは誤検出・取りこぼしの可能性があるが、ブロックしない以上 害は軽微。次セッション以降で「push コマンド文字列から cwd / remote を解決すべきか」を判断する余地は残す。

## emit フォーマット (watch-workflow)

軽量 1 行:

```
[watch-workflow] workflow:ci.yml id:12345678 status:failure commit:abc1234 branch:main user:kawaz event:push
```

- `status` の語彙は **gh 準拠**: workflow run の `status` (`queued` / `in_progress` / `completed`) と、`completed` 時の `conclusion` (`success` / `failure` / `cancelled` / `skipped` / `timed_out` / `action_required` 等) をフラット化した 1 語として出す
- ユーザー当初挙げた `run` / `succeeded` / `failed` は gh 語彙とズレるため使わない (正: `in_progress` / `success` / `failure`)

### 2026-05-26 実装時調整 (2): emit を `[event] key:value` 形式に統一、スコープ識別は Monitor description に逃がす

実機で Monitor 通知の見え方 (Claude 側の `<task-notification>` ラッパー) を確認した結果、以下が判明:

- Monitor の `description` (例: `watch-workflow: kawaz/foo`) が `<summary>` として全通知に乗る (= 起動時に Claude が設定した値がそのまま反映される、システム側のアレンジは無い)
- timestamp は通知本体に含まれない (= 到着時刻 ≈「今」と扱う)
- 同じ Monitor から複数種の行 (状態通知 / 障害通知 / ack 等) が混じると、行内の構造で型を判別する必要がある

これを踏まえて emit format を以下に刷新 (watch-pr 側も同様に揃える):

- emit は 2 系統で形式を分ける:
  - **(a) skill 固有のイベント**: `[scope:action] key:value ...` 形式 (verb:noun)。watch-workflow は `[run:change]`、watch-pr は `[comment:add]` / `[review:submit]` / `[ci:change]` / `[pr:merge]` / `[pr:close]`。payload は構造化された key:value
  - **(b) severity メッセージ**: `[INFO|WARN|ERROR] <自由文>` 形式。skill スコープと一致しないメタ通知 (起動 ack / 障害通知 / 致命エラー) は KV 縛りを緩めて自然文。skill 固有イベントとの構造的な異質感をあえて残す
- **skill 名 / repo / PR# などのスコープ識別子は emit から省略**。Monitor description (= `<summary>`) で識別する前提とし、description の命名規約を SKILL.md でロック (`watch-workflow: <owner/repo>`, `watch-pr: <owner/repo>#<N>`)
- 起動 ack は (b) の `[INFO] <skill> start: <repo> (interval=..., lookback=...)` として残す (description には乗らない設定値を残せる)
- 値にスペース等を含む場合のみ double quote (skill 固有イベント側のみ)

新しい emit 例:

```
[INFO] watch-workflow start: kawaz/foo (interval=30s, lookback=5m)
[run:change] workflow:ci.yml id:12345678 status:failure commit:abc1234 branch:main user:kawaz event:push
[WARN] gh api が 5 回連続失敗
[INFO] gh api が復旧 (5 回失敗のあと)
```

この調整も本 DR の本筋には影響しない実装ディテール。

### 2026-05-26 実装時調整 (1): gh API 経路への切替 + event の追加

当初案では `gh run list --json ...` を poll 経路として想定していたが、gh 2.92.0 時点で `--json` field に **`actor` が含まれない** ことが実装時の動作検証で判明。`actor` field を要求すると `Unknown JSON field: "actor"` で gh が即失敗し、poll 自体が成立しない。

対応として:

- **poll 経路を `gh api /repos/<owner>/<repo>/actions/runs?per_page=100` に変更**。REST API の `workflow_runs[]` には `actor.login` / `triggering_actor.login` が含まれる。1 page 想定で paginate なし (個人プロジェクトの run 件数想定として十分)
- emit format に `event` フィールドを追加。`event` (`push` / `pull_request` / `workflow_dispatch` / `schedule` 等) は trigger 起因の判別に役立ち、将来 `--only-mine` / `--events` のフィルタ実装時にも一貫した語彙を維持できる
- `actor.login` も emit に含める方針は維持。個人用途では実質ほぼ自分 (kawaz) だが、チーム開発の将来需要を見据えて情報の取得自体は確保する

この調整は本 DR の本筋 (= repo 単位の常駐 Monitor 1 本 / cutoff lookback での baseline 構築) に影響しない実装ディテール。Superseded 扱いではなく追記で済む範囲。

## ポーリング仕様

- poll 間隔は **30s 以上** (remote API の rate limit 配慮)
- transient な失敗 (`gh` 呼び出し失敗) は 1 回でループを殺さない (`|| true`)
- `persistent: true` 指定なので `timeout_ms` は書かない (スキーマ仕様で無視される)

## 将来の拡張余地 (初期実装には入れない、YAGNI)

チーム開発で他メンバーの run が煩わしい場合に備えて DESIGN に記録するに留める:

- `--only-mine` — コミッタ または 手動実行者が自分の run のみ emit
- `--workflow all[,xx.yml,...]` — 対象 workflow ファイルの絞り込み
- `--events all,queued,in_progress,success,failure,cancelled,...` — emit する event の絞り込み
- 単語選びは gh 仕様とブレないこと

## 不採用案

### α. push のたびに新規 Monitor を立てる (1 push = 1 Monitor)

- どの run を見るかの同定 (head_sha マッチ等) が必要で、GitHub API のラグでマッチに失敗するケースが出る
- push 回数に比例して Monitor が増え、Monitor リストが汚れる
- 各 Monitor のライフサイクル管理 (run 完了で自分を kill するか、放っておくか) が別途必要

### γ. SessionStart で repo を検出して即常駐

- Actions を走らせないセッション (調査・読書) でも常駐するため無駄
- 個人用途の実感「push して初めて CI が気になる」と合わない
- ただし「push 前から他人の run も拾いたい」というユースケースが将来出れば、PostToolUse と併用する形で再評価する余地はある

## 関連

- DR-0001: 改名 + スコープ拡大 (本 DR の上位)
- DR-0002: hook 出力最小化 (Monitor 起動指示の文言設計)
- `scripts/pr-monitor.sh`: 初回 emit 抑止のハッシュ比較パターン (流用元)
- `~/.claude/rules/push-workflow.md`: push 後の CI watch を必須化する個人ルール
