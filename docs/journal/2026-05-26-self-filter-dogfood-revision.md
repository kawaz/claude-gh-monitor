# 2026-05-26 self filter の即時 dogfood → 設計改定

## やったこと (時系列)

1. kawaz 報告: 「自セッションのコメント追加で通知が来るのは無駄」
2. DR-0004 起票: watch-pr / watch-workflow ともに self filter (actor / author == `gh api user --jq .login`) ON、`GH_MONITOR_INCLUDE_SELF=1` で off
3. 両 script に filter 実装、smoke test (`tests/run-tests.sh`) を追加、`just test` / `just ci` に組み込み
4. README{,-ja} / DESIGN{,-ja} / 両 SKILL.md / CHANGELOG (0.3.3) / docs/issue follow-up を更新
5. push → watch-workflow Monitor 起動 (self filter 入り)
6. dogfooding で「自分の push の CI が emit されない」を観測
7. 即改定: watch-workflow から self filter 撤廃、watch-pr のみに縮小
8. 再 push (0.3.4)、Monitor を kill → 再起動 (新コード反映)

## ハマり所と解決

### 起動時 `gh api user` 失敗時の挙動

- 期待: filter off + WARN ログ
- 実装: `gh api user --jq .login 2>/dev/null || true` で stderr 黙殺、空文字なら `[WARN] self login 取得失敗、self filter off で続行` を emit
- テストは `api-user.txt` を作らず stub gh が exit 1 する経路で検証

### `[pr:merge]` の扱い

- merge 直後の `[pr:merge]` を emit するべきか
- 決定: emit は suppress、`exit 0` は維持 (watcher を止めるトリガとして機能を残す)

### 無限 while ループの smoke test

- bats 未導入なので自前テストハーネス (`tests/run-tests.sh`) を bash で書いた
- script 側に `WATCH_PR_INTERVAL` / `WATCH_WORKFLOW_INTERVAL` env override を追加し、テストでは interval=1 + `timeout 3` で 2-3 ループだけ動かして出力を grep
- gh コマンドの stub は `tests/run-tests.sh` 内で `mktemp -d` 上に動的生成、PATH を最優先で差し込む

### dogfooding で気付いた filter スコープの過剰

- comment / review echo は emit 時点で「自分が今書いた内容」を知っているので情報量ゼロ
- workflow run 通知は emit までに数分の遅延があり、結果情報 (success / failure) は **自分の push 由来でも価値ある情報**
- 同じ "self-originated" でも扱いを揃えるのは雑だった → DR-0004 改定で watch-workflow を対象外に

### 改定後のコード反映

- Monitor は起動時のコード snapshot を実行し続けるので、コード修正のあとは TaskStop → 再 Monitor が必要
- 0.3.3 で動いていた Monitor (`bo37bux70`) を `TaskStop` してから 0.3.4 のコードで再起動

## 設定値・コマンド

```bash
# 自前テストハーネス
bash tests/run-tests.sh

# ポーリング間隔の上書き (テストとデバッグで有用)
WATCH_PR_INTERVAL=1 bash scripts/watch-pr.sh kawaz/test 1
WATCH_WORKFLOW_INTERVAL=1 bash scripts/watch-workflow.sh kawaz/test

# self filter を off (デバッグ用)
GH_MONITOR_INCLUDE_SELF=1 bash scripts/watch-pr.sh kawaz/test 1
```

## 議論の要点

「設計判断の即時覆し」は気持ちが悪いが、dogfooding で実害が出た瞬間に直すのは TDD 文化に合う。DR は版を切らずに「改定履歴」節を頭に追加し、なぜ初版で誤ったか / なぜ改定したかを残す形にした。これにより将来の reader が「workflow も filter したくなったら」同じ罠を踏まず、過去の検討経緯を辿れる。

「気付き」は実装直後の dogfooding で生まれる。「実装した瞬間に使ってみる」習慣が本件の救いになった。

## 次にやるべきこと

- Followup #1 (CI 中間遷移 suppress) は別 issue で起票済み。watch-workflow が `queued` / `in_progress` 連発で噛むことが観測できたら着手
- Followup #2 (bot 連投 suppress) は実害が出てから
- Followup #3 (self-merge 後の `[pr:merge]` 完全 silent) は Monitor の自然終了通知の挙動次第で必要性が決まる

## 関連

- [DR-0004](../decisions/DR-0004-suppress-self-originated-events.md) (改定済み)
- [docs/issue/2026-05-26-suppress-noise-followups.md](../issue/2026-05-26-suppress-noise-followups.md)
