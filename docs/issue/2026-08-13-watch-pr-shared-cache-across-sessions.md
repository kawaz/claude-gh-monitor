---
title: 同一 PR を複数セッションで監視すると gh API を重複で叩く (蓄積ファイルを共有キャッシュとして使う)
status: open
category: design
created: 2026-08-13T19:56:00+09:00
last_read:
open_entered: 2026-08-13T19:56:00+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: 別環境の作業セッションからのクロス起票
---

# 同一 PR を複数セッションで監視すると gh API を重複で叩く (蓄積ファイルを共有キャッシュとして使う)

## 概要

同じ PR を複数の Claude セッション (= 複数の Monitor) が監視することは実運用でよくある。現状は watcher ごとに独立して `gh` を叩くため、**同じ情報を取りに行く API 呼び出しが監視数ぶん重複**する。これが積み重なると gh の API rate 制限に引っかかることがある。

クロスプロジェクト起票 (別環境の作業セッションによる観測)。採否・方針は本リポ担当側で判断してほしい。

## 提案する方向性

別 issue (`2026-08-13-watch-pr-duplicate-emission-needs-state-persistence`) で提案している**状態の永続化ファイルを、そのまま共有キャッシュとして使う**。

- 置き場所は同じ `${XDG_CACHE_HOME:-~/.cache}/<name>/` または `$TMPDIR/<name>-$(id -u)/`、ファイル名も同じ `{repo-slug}-{id}.jsonl`
- 取得前に「直近レコードの取得時刻が閾値内か」を確認し、閾値内なら `gh` を叩かずキャッシュを読む
- 実際に取得したセッションだけが追記し、他セッションは読むだけ
- 各セッションの emit 判定 (どこまで通知済みか) はセッション個別に持つ必要があるので、**キャッシュ (共有) と emit カーソル (セッション個別)** は分けて持つ

## 補足

取得時にフィールドを絞りすぎない方針 (別 issue に記載) は、この共有キャッシュとも相性が良い。1 回の取得で得た情報が厚いほど、他セッションがキャッシュで済ませられる範囲が広がる。

## 注意点 (実装時に詰めるべきこと)

- 複数プロセスの同時追記に対する排他 (flock 等)
- キャッシュの鮮度閾値をどう決めるか (ポーリング間隔との関係)
- 古いエントリの掃除 (無限に伸びる JSONL の扱い)
