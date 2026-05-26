# DR-0004: 自セッション起因イベントはデフォルト suppress

- ステータス: Accepted (改定: 2026-05-26)
- 日付: 2026-05-26
- 関連: DR-0001 (スコープ), DR-0003 (watch-workflow), `scripts/watch-pr.sh`, `scripts/watch-workflow.sh`

## 改定履歴

- 2026-05-26 初版: PR 通知 + workflow run の双方で self filter ON。
- 2026-05-26 改定: **workflow run は self filter 対象外** に縮小。dogfooding 中に「自分の push でも CI 結果通知は欲しい情報」だと気付いた。詳細は本文「対象スコープ」「改定の理由」節を参照。

## 文脈

watch-pr / watch-workflow を実運用していると、**Claude セッション自身が起こしたイベントが自分にエコーバックされる** ノイズが目立つ:

- `gh pr comment` で Claude が PR にコメントを書く → 60 秒後の poll で `[comment:add] user:<self>` が emit される
- Claude が `pkf run push` した直後の `[run:change] ... user:<self>` がほぼ毎回流れる
- Claude が PR を merge した直後の `[pr:merge] user:<self>` が来る (watcher 自体は exit に必要だが通知は不要)

これらは「いまさっき自分でやった操作」であり、Monitor 通知としては **必ず無駄な追加思考を 1 ターン挟む** (`oh, this is my own comment` という独り言の例を観測済み)。コンテキストも噛むし、ターン数も増える。

GitHub の event オブジェクトには明確に actor / author の login が乗っているため、`gh api user --jq .login` で取れる self login と突き合わせて落とせる。

## 対象スコープ

self filter は **「emit 即時に情報価値ゼロな自己 echo」だけ** を対象にする:

| イベント | 対象? | 理由 |
|---|---|---|
| `[comment:add]` (watch-pr) | ✅ suppress | 自分がたった今書いたコメントが 30〜60s 後に echo されても情報量ゼロ |
| `[review:submit]` (watch-pr) | ✅ suppress | 同上 |
| `[pr:merge]` (watch-pr) | ✅ suppress (exit 0 は維持) | 自分が直前に merge したことは知っている。watcher を止めるトリガとしては機能が必要 |
| `[ci:change]` (watch-pr) | ❌ filter 対象外 | author 情報を持たない |
| `[run:change]` (watch-workflow) | ❌ filter 対象外 (改定) | 自分の push でも CI 結果は数分後の遅延通知で価値ある情報。詳細は「改定の理由」節 |

## 決定

watch-pr に限り:

1. **起動時に self login を 1 回だけ取得** (`gh api user --jq .login`)。失敗時は `self_login=""` のまま続行 (= filter 無効)、起動ログに `[WARN] self login 取得失敗、self filter off で続行` を出す。
2. **emit 直前で `author == self_login` の行を 1 行単位で suppress**。`[comment:add]` / `[review:submit]` の author、および `[pr:merge]` の `mergedBy` が対象。`[pr:merge]` は emit を suppress するが exit 0 は実行する (= watcher を止めるトリガとしては機能を維持)。
3. **escape hatch は環境変数 `GH_MONITOR_INCLUDE_SELF=1`** のみ。指定時は self_login を空にして filter を完全に off。CLI 引数は YAGNI で当面追加しない。
4. self filter の発火/抑止は `[INFO] self filter: login=<self>` を起動行の直後に 1 回だけ emit し、運用中に何が抑制されているか追跡可能にする。

watch-workflow では:

- self filter を行わない (改定で削除)。CI 結果は actor 関係なく emit する。
- ただし self login の取得・起動ログだけは将来の拡張に備えて残してもよい (現実装は撤廃で simpler keep)。中間遷移ノイズ (queued / in_progress 連発) は別問題として Followup #1 で扱う。

## 理由 (PR 通知の self filter について)

1. **Monitor の本来目的が「他者起因の非同期イベント」だから**。自分が直前にやった comment / review / merge の echo は本来の責務外。
2. **filter ルールがシンプル**: author の 1 文字列突合せで済む。誤検知の余地が小さい。
3. **gh 認証ユーザー単位の運用と整合**: kawaz の運用では 1 プロセス = 1 gh アカウントが基本で、`gh api user` が watcher 視点の "self" を一意に決められる。
4. **filter off を残す理由**: デバッグ時 (「本当に emit されてる？」の確認) と、まれに同 gh アカウントを共有する別セッションのイベントを敢えて見たい場合のため。env var だけ用意し、対話オプション化は実需が出てから。

## 改定の理由 (workflow run を対象外にした経緯)

初版 (push: kawaz/claude-gh-monitor 0.3.3) では watch-workflow も同じく actor=self で `[run:change]` を suppress していた。直後の dogfooding で「実装+docs を push → 自分の push で CI/release workflow が走る → Monitor が無音」となり、CI 結果が emit されなくなる挙動を観測した。

- **comment / review の echo**: emit 時点で「自分が今書いた内容」を知っているので情報量ゼロ
- **workflow run の状態通知**: emit までに数分の遅延があり、結果 (success / failure) は **自分の push 由来であっても価値ある情報**

両者は性質が違う。前者は「即時 echo の無駄」、後者は「遅延通知に乗った結果情報」で、同じ "self-originated" でも扱いを揃えるのは雑だった。改定により watch-workflow は actor に関わらず emit する形に戻し、自セッションの push の CI 結果も Claude が能動的に拾えるようにする。

中間遷移 (queued / in_progress) が冗長なら **Followup #1 (CI 中間遷移 suppress)** で別途解決する。これは「self/non-self」ではなく「終端状態だけ通知する」軸での絞り込みで、actor とは独立した方が筋がよい。

## トレードオフと既知の限界

- **同じ gh アカウントを並列セッションで共有しているとき、他セッション発の comment / review も silent になる** (PR 通知側のみ)。kawaz の運用では並列セッション同士で同一 PR を同時に触ることは稀 (worktree 分離が前提) なので、許容する。困ったら `GH_MONITOR_INCLUDE_SELF=1` で一時 off できる。
- **bot コメント / 他人レビュー / Renovate / Dependabot 等は当然 filter されない**。これらは noise ではあるが「他者発」なので別問題 (Followup #2 で別途検討)。
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
