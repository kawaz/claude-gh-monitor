# DR-0004: 自セッション起因イベントはデフォルト suppress

- ステータス: Accepted
- 日付: 2026-05-26
- 関連: DR-0001 (スコープ), DR-0003 (watch-workflow), `scripts/watch-pr.sh`, `scripts/watch-workflow.sh`

## 文脈

watch-pr / watch-workflow を実運用していると、**Claude セッション自身が起こしたイベントが自分にエコーバックされる** ノイズが目立つ:

- `gh pr comment` で Claude が PR にコメントを書く → 60 秒後の poll で `[comment:add] user:<self>` が emit される
- Claude が `pkf run push` した直後の `[run:change] ... user:<self>` がほぼ毎回流れる
- Claude が PR を merge した直後の `[pr:merge] user:<self>` が来る (watcher 自体は exit に必要だが通知は不要)

これらは「いまさっき自分でやった操作」であり、Monitor 通知としては **必ず無駄な追加思考を 1 ターン挟む** (`oh, this is my own comment` という独り言の例を観測済み)。コンテキストも噛むし、ターン数も増える。

GitHub の event オブジェクトには明確に actor / author の login が乗っているため、`gh api user --jq .login` で取れる self login と突き合わせて落とせる。

## 決定

両 watcher 共通で:

1. **起動時に self login を 1 回だけ取得** (`gh api user --jq .login`)。失敗時は `self_login=""` のまま続行 (= filter 無効)、起動ログに `[WARN] self login 取得失敗、self filter off で続行` を出す。
2. **emit 直前で `author == self_login` の行を 1 行単位で suppress**。watch-pr では comment / review、watch-workflow では `[run:change]` の `user:` フィールドが対象。`[pr:merge] user:<self>` は suppress するが exit 0 は実行する (= watcher を止めるトリガとしては機能を維持)。
3. **escape hatch は環境変数 `GH_MONITOR_INCLUDE_SELF=1`** のみ。指定時は self_login を空にして filter を完全に off。CLI 引数は YAGNI で当面追加しない。
4. **CI 状態 (`[ci:change]`) は author 情報を持たないので filter 対象外**。CI 失敗の追跡は self/non-self に関わらず必要。
5. self filter の発火/抑止は `[INFO] self filter: login=<self>` を起動行の直後に 1 回だけ emit し、運用中に何が抑制されているか追跡可能にする。

## 理由

1. **Monitor の本来目的が「他者起因の非同期イベント」だから**。自分が直前にやった操作の echo は本来の責務外。
2. **filter ルールがシンプル**: actor / author の 1 文字列突合せで済む。誤検知の余地が小さい。
3. **gh 認証ユーザー単位の運用と整合**: kawaz の運用では 1 プロセス = 1 gh アカウントが基本で、`gh api user` が watcher 視点の "self" を一意に決められる。
4. **filter off を残す理由**: デバッグ時 (「本当に emit されてる？」の確認) と、まれに同 gh アカウントを共有する別セッションのイベントを敢えて見たい場合のため。env var だけ用意し、対話オプション化は実需が出てから。

## トレードオフと既知の限界

- **同じ gh アカウントを並列セッションで共有しているとき、他セッション発の操作も silent になる**。kawaz の運用では並列セッション同士で同一 PR を同時に触ることは稀 (worktree 分離が前提) なので、許容する。困ったら `GH_MONITOR_INCLUDE_SELF=1` で一時 off できる。
- **bot コメント / 他人レビュー / Renovate / Dependabot 等は当然 filter されない**。これらは noise ではあるが「他者発」なので別問題 (DR-0005 候補で別途検討)。
- **PR の self-merge は emit suppress だが watcher は exit する**。merge 直後の通知は冗長だが exit シグナルは Claude 側で `[pr:merge]` を期待しているわけではない (Monitor タスクの自然終了で十分)。

## 不採用案

### A. PostToolUse hook で Claude の操作 (gh pr comment 等) を記録し、watcher が消し込む

操作ごとの fingerprint (body hash, timestamp, target) を hook → watcher へ受け渡す機構が必要で複雑。`gh` 経由以外の操作 (web UI からの kawaz 自身の操作) には効かない。費用対効果で不採用。

### B. デフォルト off + 明示 on

「watcher の責務縮小は破壊変更だから保守的に off で出す」案。しかし現状の echo ノイズは実害が大きく、すぐに kawaz が「self filter on にする env var ない？」となる蓋然性が高い。デフォルト on にして escape hatch だけ提供するのが筋。

### C. CLI 引数 `--include-self` / `--no-include-self`

env var だけで足りる。skill 側から引数を渡し分ける状況がまだ無い。実需が出たら追加する。

## 関連

- DR-0001: 改名 + スコープ拡大の前提
- DR-0003: watch-workflow が repo 単位の常駐 1 本である前提 (self filter は 1 本に対して効けばよい)
- `scripts/watch-pr.sh`, `scripts/watch-workflow.sh`: 実装対象
