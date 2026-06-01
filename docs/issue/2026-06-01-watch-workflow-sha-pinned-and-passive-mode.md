# watch-workflow: SHA-pinned モード追加 + Passive モード backoff 化

## 背景: 多重 CI watch による RateLimit 問題

DR-0003 で「repo 単位 1 本常駐」を確立したが、運用してみると以下のパターンで CI watch が積み上がり、結果的に GH API の RateLimit に引っかかる事案が頻発:

- 親エージェントが複数のサブエージェントを並列起動 → 各サブエージェントがそれぞれ `watch-workflow` Monitor を起動 → 同じ repo に対して N 個の poller が走る (DR-0003 は「同セッション内で重複起動しない」は防げるが、**別セッション間で重複している軸**を捕まえていなかった)
- ほぼ完了状態のサブエージェントが Monitor を抱えたまま放置される → 不要な poll が継続
- main コンテキストに同一イベントの通知が N 重で届く

> サブエージェント起因のスケールは DR-0003 のスコープ外。各セッションが独立に Monitor を抱えてよいが、それが N 並列するとサーバ側に効いてしまう。

## 提案 1: SHA-pinned モード (新規)

「自分の push を見届ける」用途向け。指定 SHA のチェックが全て terminal state に到達したら **Monitor プロセス自身が exit** する。

### 仕様

```
watch-workflow.sh --sha <SHA> [--exit-on-final] [--grace=60s] [--timeout=24h] <OWNER/REPO>
```

- `--sha <SHA>`: フィルタ対象コミット (完全 SHA、または 7 文字以上の prefix)
- `--exit-on-final`: SHA 指定モードのデフォルトとして有効。後述の exit 条件を満たしたら exit 0
- terminal state 一覧: `success` / `failure` / `cancelled` / `timed_out` / `action_required` / `skipped` / `neutral` / `stale` / `startup_failure`
- `--grace=<duration>`: terminal 集約後の grace window (デフォルト 60s)。後述の late-arriving / `workflow_run` cascade 対策
- `--timeout=<duration>`: 安全 timeout (queue 詰まり等で永遠に terminal にならないケース対策、デフォルト 24h)

### exit 条件 (codex review 反映)

terminal state 直後に即 exit すると、以下を取りこぼす:

- **late-arriving run**: SHA push 直後、最初の run が API に現れる前に poll するケース。terminal な run が 0 個 = 「全部 terminal」と誤判定する
- **`workflow_run` cascade**: 「他 workflow の completion で trigger される後続 workflow」(`on.workflow_run`) は親 run の completion 後に現れる
- **手動 dispatch の後追い**: 監視中に `workflow_dispatch` で同一 SHA を指定して追加 run が走るケース

そこで exit 条件は:

> **指定 SHA に紐づく run が 1 つ以上観測されており、それら全てが terminal state、かつ「最後に新規 matching run または state transition を観測してから grace 期間 (デフォルト 60s) 経過」**

- 「最初の run を観測するまで」は exit 評価しない (= late-arriving 救済)
- terminal 集約後も grace 期間中は新規 run / state transition を待つ (= cascade / 後追い救済)
- grace 期間内に新しい event があれば grace を再起動

### re-run policy (codex review 反映)

- **監視中に re-run が発生 → そのまま追う** (= `in_progress` に戻る → 再 terminal → grace → exit)
- **exit 後の re-run は対象外** (= 必要なら user が再度起動)
- 自然な「割り切り」: 一度自然 exit したら終わり

### 利点

- エージェントの「停止し忘れ」を構造的に排除 (= Monitor 自身が自走 exit)
- 自分の関心以外のコミットの CI 変化を見ない → 通知が綺麗
- 同じ repo に SHA 違いで複数 attach されても、それぞれ自然消滅する

### DR-0003 との関係

DR-0003 は「push のたびに増えるが exit しないので積み上がる」問題への対処だった。SHA-pinned は「増えるが自然 exit する」ので積み上がらない → DR-0003 の精神 (= 並列を許容しつつ常駐ゴミを残さない) に整合する。

ただし以下は **DR-0005 として別途決める必要**:

- 同 repo の SHA-pinned が既にあるところに新規 push → 旧 SHA Monitor は TaskStop してから新規起動 vs そのまま並列許可
- force-push で旧 SHA が消えるケース → 旧 Monitor は永遠に terminal を待つ → safety timeout 必須
- passive モードと SHA-pinned モードの共存ルール (同 repo に両方立てて良いか)

## 提案 2: Passive モード backoff 化 (現状改修 + 明示オプトイン)

現行の「SHA 指定なし = repo 常駐 1 本」モードは維持しつつ、idle backoff を入れる。**`--passive` flag を必須化** (= codex review #4 反映、誤起動の事前 guard)。

### 仕様

```
watch-workflow.sh --passive [--max-interval=10m] [--timeout=24h] <OWNER/REPO>
```

- `--passive`: **必須**。明示的オプトイン。これと `--sha` のどちらも無い起動は exit 2 (エラー終了)
- 初期 interval: 30s 固定 (現行通り)
- backoff: 「state 変化なし」が続いたら指数的 (×1.5 等) に伸ばす
- `--max-interval=10m` で上限 (デフォルト 10 分)
- `--timeout=24h` で自走 exit
- **reset trigger** (短間隔へ戻す条件):
  1. workflow run の新規発火
  2. 既存 run の state 遷移
  3. Monitor サブスクライバ側からの ping (= 「いま見たい」シグナル、後検討)
- terminal で全部固まった後の idle と queue 詰まりの idle は区別不要 (どっちも「変化を待つ間」)

### 利点

- 夜中放置で「変化なしなのに 30s 毎に N 並列で API 叩く」を回避
- GH API 5000 req/h / IP の制限に対して、10min interval なら 1 セッション 6 req/h → 50 並列でも 300 req/h で余裕

### 懸念

- 10min 間隔中に push → 通知最大 10 分遅延。**Passive モードの代償としては妥当**だが、エージェントが SHA-pinned を使わずに passive で済ませると遅延が出る → SKILL 文書で「自分作業は SHA-pinned」を強く誘導する必要
- backoff 中に別セッションから ping したい (= 寝起きで「いま CI どう?」) ケース → ping reset は将来追加検討

## 提案 3: 起動 mode 必須化 (codex review #4 反映)

エージェントが脊髄反射で passive 起動 (= 長時間ゴミ常駐) するのを抑制するため、**起動 mode を必須化** (`--sha` または `--passive` のどちらかを必ず付ける)。

### 仕様

- `--sha` も `--passive` も無い起動 → **exit 2 (エラー終了)**。stderr に以下を出す:
  ```
  [ERROR] mode required: --sha <SHA> (recommended for own work) or --passive (repo-wide watch).
  ```
- WARN ではなく **事前 guard** にする (= WARN は起動後に出るので「気付いた時には既に走っている」を防げない)
- 移行中の互換: 現状の `post_tool_use.sh` は `--sha` 無しで起動するので、**実装と hook 更新は同時 or hook 更新が先**。さもないと既存セッションで起動失敗する

### 妥協案 (採用しない)

「--sha 省略時は WARN 出して passive で起動」案も検討したが、誤起動の構造的防止にならないため不採用 (codex review #4)。

## 提案 4: SKILL 説明文の方針更新

`skills/watch-workflow/SKILL.md` を以下方向で書き換え:

- **SHA-pinned を第一推奨** として明示。「いつ起動するか」テーブルの第一行を「自分の push 後 → `--sha <最新コミットSHA>` 付きで起動」に置く
- **Passive モードは明示的オプトインセクション**に分離。「だらだら需要は少ない」「自分作業の追跡には SHA-pinned を使う」を冒頭で書く
- `hooks/post_tool_use.sh` の additionalContext を **SHA-pinned 起動コマンドに乗せ替える** (push 検知時点で head SHA を解決して埋め込む)
- SHA 省略時の warning 仕様を skill 側にも記載

## 将来 issue: 共有キャッシュレイヤ

別ファイルに分離: [2026-06-02-shared-cache-layer.md](2026-06-02-shared-cache-layer.md)

概要: 同一 repo を見ているセッションが N 並列でも、effective GH API 呼び回数を 1 セッション分に抑え込む。`XDG_CACHE_HOME/gh-monitor/api-cache/` (共有 cache) + `XDG_STATE_HOME/gh-monitor/sessions/` (per-session state) + single-flight fetcher + `SessionEnd` での GC。

## 対応順

直近タスクは以下順で着手:

1. **SKILL 文書を先に整える** (提案 4) — ✅ 完了 (2026-06-01)
2. **scripts 実装** (提案 1, 2, 3): 文書の通りに動くよう追従
3. **hooks/post_tool_use.sh を SHA-pinned 起動に乗せ替え**: 提案 3 で「mode 必須化」が走るので、hook の additionalContext も `--sha <HEAD>` 付き起動文へ更新が必須。実装と同タイミング or hook 更新が先

文書 → 実装の順とした理由: 実装してから文書だと、文書化までの空白期間が今と同じ挙動になる。文書先行なら方針徹底が早く効く。

## 関連

- [DR-0003](../decisions/DR-0003-watch-workflow-persistent-per-repo.md): repo 単位常駐 1 本 (本 issue で **Passive モードに限定**と再解釈、SHA-pinned 並列を許容する方向)
- [DR-0004](../decisions/DR-0004-suppress-self-originated-events.md): self filter (workflow run は対象外として維持)
- [2026-05-26-suppress-noise-followups.md](2026-05-26-suppress-noise-followups.md): 中間遷移 suppress / bot 連投 集約 / self-merge silent (別軸の follow-up)

## 確定事項 (DR-0005 でまとめる予定)

- 同 repo SHA-pinned **並列許可**ポリシー (案 B、自然 exit 任せ): 2026-06-01 確定
- passive と SHA-pinned の **同居可能** (description 違いで区別): 2026-06-01 確定
- DR-0003 (= repo 単位常駐 1 本) を **Passive モードのみに limit** と明記: 2026-06-01 確定 (codex review #6)
- SHA-pinned exit 条件に **grace window** を含める: 2026-06-01 確定 (codex review #1)
- 起動 mode **必須化** (`--sha` or `--passive` 必須): 2026-06-01 確定 (codex review #4)

## 開いた問い (将来)

- ping reset 機構 (将来 cache 層とどう繋ぐか)
- 共有 cache 層の詳細 (= 上記「将来 issue: 共有キャッシュレイヤ」)
