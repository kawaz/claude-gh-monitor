---
title: watch-pr が同一内容を繰り返し emit する (状態を永続化して直近との差分がなければ通知しない)
status: open
category: bug
created: 2026-08-13T19:55:00+09:00
last_read:
open_entered: 2026-08-13T19:55:00+09:00
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

# watch-pr が同一内容を繰り返し emit する (状態を永続化して直近との差分がなければ通知しない)

## 概要

`watch-pr.sh` で PR を監視中、**まったく同じ `[ci:change]` 行の塊が何度も繰り返し emit される**状態になった。CI の状態は確定済みで実際には何も変化していないのに、ポーリングのたびに同じ通知が飛ぶ。

監視対象の PR は「新しい push により先行 run が concurrency で CANCELLED され、後続 run が SUCCESS で確定した」という履歴を持っていた。CANCELLED と SUCCESS が混在した check 一覧が安定せず、比較に使っているハッシュが揺れ続けたのではないかと見ている (未確認の推測)。

通知が止まらないため、当該セッションでは watcher を TaskStop するしかなかった。監視を止めるということは以降のレビュー・CI・マージ検出も失うので、実質的にこの機能が使えなくなる。

クロスプロジェクト起票 (別環境の作業セッションによる観測)。部外者観測なので、採否・修正方針は本リポ担当側で裏取りの上判断してほしい。

## 観測した挙動

- 同一の 6〜9 行程度の `[ci:change]` ブロックが、内容も URL も完全に同じまま繰り返し通知される
- 通知の間に実際の状態変化 (新しい run / conclusion の変化) は無い
- CANCELLED の run が check 一覧に残り続けている

## 提案する方向性

### 1. 状態の永続化と差分判定

emit 前の状態をプロセス内変数だけでなく**ファイルに蓄積**し、直近と差分がなければ emit しない。

- 置き場所: `${XDG_CACHE_HOME:-~/.cache}/<name>/` または `$TMPDIR/<name>-$(id -u)/`
- ファイル名: `{repo-slug}-{id}.jsonl` (例: `owner-repo-1234.jsonl`)
- JSONL で追記していけば、履歴として後から差分の経緯も追える

現状のハッシュ比較だけだと「並び順の揺れ」「一時的に現れて消えるレコード」に弱い。永続化した直近レコードと**フィールド単位で比較**する形にすれば、同一内容の再 emit を確実に止められる。

### 2. 取得フィールドを絞りすぎない

蓄積する際は `gh` の取得フィールドを無駄に絞らず、取れるものは取っておく。

- 後から「もう少し詳細を見たい」となったときに、別フィールド指定で `gh` を叩き直す必要がなくなる
- API 呼び出し回数の削減にもつながる (下記の別 issue とも関係する)

## 関連

- 複数セッションが同じ PR を監視する場合の重複 API 呼び出しについては別 issue を参照 (`2026-08-13-watch-pr-shared-cache-across-sessions`)
