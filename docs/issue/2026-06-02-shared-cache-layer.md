# 将来 issue: watch-workflow に共有 cache 層を入れる

DR-0005 (= SHA-pinned + Passive opt-in 化) の **次フェーズ** で扱う、共有 cache 層の設計案。RateLimit 抑制を「並列セッションが N あっても effective GH API 呼び回数を 1 セッション分に抑える」ところまで根治させる。

## 概要

同一 repo を見ている並列セッション (= 各セッションが SHA-pinned or Passive で独立に走る) が複数あるとき、各セッションが愚直に GH API を叩くと並列度に比例して呼び回数が増える。代表 fetcher が 1 つだけ叩いてキャッシュを共有することで、effective な API 呼び回数を抑える。

## 設計案

### キャッシュ (共有)

`XDG_CACHE_HOME/gh-monitor/api-cache/<repo-hash>.json` — GH API response with TTL

- 削除しても再 fetch するだけ (= regeneratable) なので CACHE_HOME が正しい
- `<repo-hash>` は `<OWNER/REPO>` の sha1 等で衝突回避

### state (セッション単位)

`XDG_STATE_HOME/gh-monitor/sessions/<session_id>.json` — そのセッションが最後に通知した run state 一覧

- 消えると **通知済みの state 変化を再通知する副作用**がある (= regeneratable じゃない)
- → STATE_HOME が正しい (= XDG spec の意図に合う)

### fetcher と observer を兼ねる

- 最初に poll したセッションが代表 fetcher、他は cache pickup
- 専用 fetcher プロセスは置かない (= シンプル)

### single-flight

- 進行中の fetch が見えたら待つ
- 実装手段: `flock` (advisory lock on cache file) または tmpfile + atomic rename
- TTL を過ぎたら新しい fetcher 候補が出現、`flock` で 1 つに絞る

### state GC

- セッション終了時に `<session_id>.json` を消す
- 実装手段: cmux-msg の `SessionEnd` hook 相当を `gh-monitor` 側にも用意 (= Claude Code の `SessionEnd` を使う)
- バックアップとして起動時に「孤児 state file の cleanup」(= 該当 session_id が既に死んでる) もする

### XDG 変数未設定時のフォールバック

- `XDG_CACHE_HOME` 未設定 → `~/.cache/gh-monitor/api-cache/`
- `XDG_STATE_HOME` 未設定 → `~/.local/state/gh-monitor/sessions/`
- XDG Base Directory Specification 通り

### ディレクトリ構造

```
XDG_CACHE_HOME/gh-monitor/
  api-cache/<repo-hash>.json       # GH API response cache
  (将来: workflow-list/<repo-hash>.json 等別カテゴリが生えても干渉しない)

XDG_STATE_HOME/gh-monitor/
  sessions/<session_id>.json       # 通知済み state
  (将来: subscriptions/ や locks/ を兄弟に並べられる)
```

カテゴリで 1 段ディレクトリを掘る理由: XDG_*_HOME 直下は他用途と共有される空間。`<repo-hash>.json` を直接並べると行儀が悪い。

`<repo-hash>` を 1 階層で並べる粒度なら fan-out も実用上問題ないので、git objects 風の 2 文字分割までは不要 (1 万 repo 並ぶ規模ではない)。

## 効果

並列セッション数が増えるほど effective な GH API 叩き回数が逓減 → RateLimit 問題の根本治療。
SHA-pinned 並列許可 (DR-0005 案 B) の一時的負荷も吸収できる。

## 派生する設計事項

- **ping reset (= passive interval を外部 signal で短間隔へ戻す)** を cache 層と同時に検討。「いま見たい」ユースケース (= 寝起きに状況確認等) でも遅延 0 で fetch できるよう
- repo 単位の TTL チューニング (= fast CI 中は短い TTL、idle 中は長い TTL)

## 開いた問い

- TTL のデフォルト値 (5s? 30s?)
- 複数 process の lock 競合 = lock 取得待ちの timeout 動作
- cache file の format (raw response そのまま? structured 抽出済?)
- 既存 session_id 検出方法 (= cmux-msg の `by-session` と類似の仕組みを内部に持つ vs Claude Code 側から取得)

## 関連

- [DR-0005](../decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md) — 本 issue の前段
- [2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md](2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md) — 元議論
