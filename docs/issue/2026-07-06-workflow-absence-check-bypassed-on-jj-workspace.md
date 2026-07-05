---
title: post_tool_use hook の workflow 不在チェックが git bare + jj workspace 構成で素通りし、workflow を持たないリポでも push のたびに watch nudge が出る
status: open
category: bug
created: 2026-07-06T07:13:51+09:00
last_read:
open_entered: 2026-07-06T07:13:51+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: kawaz/kuu
---

# post_tool_use hook の workflow 不在チェックが git bare + jj workspace 構成で素通りし、workflow を持たないリポでも push のたびに watch nudge が出る

## 概要

`hooks/post_tool_use.sh` (v0.5.2) には「ローカル checkout に `.github/workflows/*.yml` が
1 つも無ければ黙って終了」というブロックがあるが、toplevel 解決が
`git -C "$workdir" rev-parse --show-toplevel` のみに依存している。git bare + jj workspace
構成 (repo 親ディレクトリに bare `.git`、各 workspace は独自の `.git` を持たず jj workspace
としてぶら下がる) ではこの解決が bare リポに当たって
`fatal: this operation must be run in a work tree` (exit 128) を返し、`_repo_toplevel` が
空になる。結果として workflow 不在チェックのブロック全体がスキップされ、workflow を持たない
リポでも push のたびに watch nudge が無条件に出続ける。

## 背景

kawaz/kuu (git bare + jj workspace 構成: repo 親に bare `.git`、`main/` は jj workspace で
独自 `.git` を持たない) で実機確認 (2026-07-06):

- `main/` で `git rev-parse --show-toplevel` が exit 128
- 当該リポに `.github/workflows` は存在しない
- それでも PostToolUse hook は watch 起動指示を出し、起動した `watch-workflow.sh` は
  「no workflows in kawaz/kuu — nothing to watch」で即終了 → 毎 push で AI コンテキスト
  消費と Monitor 起動が無駄になる

同じ hook 内の head SHA 解決 (`hooks/post_tool_use.sh` 126〜133 行目付近) は `.jj` の存在を
検知して `jj log -r 'latest(::@ & ~empty())'` へフォールバックする実装が既にあり、jj
workspace 構成への対応自体は同 hook 内に前例がある。workflow 不在チェック側
(112〜119 行目) だけこの対応が抜けている。

一次資料 (該当箇所): `hooks/post_tool_use.sh` 112〜119 行目 (toplevel 解決 + workflow
存在チェック)、126〜133 行目付近 (head SHA の jj-aware フォールバック、対比参考実装)。

### 修正観点のフラグ (部外者からの提示。採否・実装方針は当事者判断、裏取りしてから)

- (a) toplevel 解決に jj workspace 向け fallback を追加する (`.jj` があれば workdir
  自身、または `jj workspace root` 相当のディレクトリで `.github/workflows` を見る等)
- (b) 解決不能時のデフォルト方向をどちらに倒すか — 現状は「判定不能 → nudge を出す」
  (誤 nudge 側)。逆 (判定不能 → 出さない) に倒すと、colocate されていない他構成で
  watch 起動そのものが死ぬ懸念があり、トレードオフの整理が必要

## 受け入れ条件

- [ ] git bare + jj workspace 構成でも workflow 不在チェックが正しく機能する (toplevel を
      正しく解決できる、または jj workspace 向けの妥当な fallback がある)
- [ ] (a)(b) のトレードオフを踏まえた修正方針が決定・実装される
