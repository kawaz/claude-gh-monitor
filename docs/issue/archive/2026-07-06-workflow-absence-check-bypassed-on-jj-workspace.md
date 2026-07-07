---
title: post_tool_use hook の workflow 不在チェックが git bare + jj workspace 構成で素通りし、workflow を持たないリポでも push のたびに watch nudge が出る
status: resolved
category: bug
created: 2026-07-06T07:13:51+09:00
last_read:
open_entered: 2026-07-06T07:13:51+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered: 2026-07-07T21:27:10+09:00
discard_reason:
pending_reason:
close_reason: ["implemented:commit 3d9b3940 で _resolve_root ヘルパーに統一(bump-semver vcs get root優先、git rev-parse --show-toplevel fallback)、workflow不在チェックとcd overrideの2箇所に適用。head SHA解決もbump-semver vcs get commit-id優先(DR-0040でdefaultが最新固定コミット=@除外・空マージ救済に修正済)に更新、jj fallbackもheads((::@-)&(~empty()|merges()))に。git bare+jj workspace fixture+bump-semver stubのTDDテスト2件追加(RED→GREEN)。実機(gh-monitor=workflow有/kuu=workflow無)で動作確認済み。追加観測の「workdir選択の並行セッション誤認」仮説は本fixのスコープ外(別途必要なら再起票)"]
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

### 追加観測 (2026-07-06 同日): push 対象と異なるリポの commit を解決する事例

kawaz/claude-rules-personal (main worktree、workflow なし、remote は
`git@github.com:kawaz/claude-rules-personal.git`) で `just push` を実行した直後の
PostToolUse nudge が (a) repo を kawaz/kuu (= そのセッションの起動 dir のリポ) と解決し、
(b) SHA `88f288a30eb5` を指示した。

起票時点では「この SHA はどちらの jj log にも存在しない」としたが、これは検証ミス:
検証コマンドが 2 回とも claude-rules-personal の cwd で実行されており、kuu 側は
未検証だった。実際には `88f288a30eb5` は kawaz/kuu に並行セッション (workflow agent)
が直前に land させた実在 commit で、kuu の jj log 上の最新 non-empty commit と一致する。

したがって正しい観測は: **push 対象 (claude-rules-personal) でなく、セッション起動
dir のリポ (kawaz/kuu) の最新 non-empty commit を正しく解決して nudge を出した**。SHA
解決自体は正常動作しており、誤っているのは workdir (対象リポ) の選択のみ。

この事実は下記の workdir 仮説を弱めず、むしろ補強する: hook ででたらめな SHA が出た
のではなく、**kuu の最新 commit を正確に拾えている** = hook が (push 対象でなく) kuu を
スキャンしている証拠。

仮説フラグ (部外者からの提示。裏取り・採否は当事者判断):

- hook の workdir 解決が Bash tool の実行時 cwd (compound command 内の `cd`) でなく
  セッション起動 dir を拾っている可能性 (= 上記観測により裏付けが強まった)
- SHA 解決自体は正常 (誤りは repo/workdir 選択のみ)

再現条件: セッション起動 dir と push 対象リポが異なる + 両方 git bare + jj workspace 構成

## 受け入れ条件

- [ ] git bare + jj workspace 構成でも workflow 不在チェックが正しく機能する (toplevel を
      正しく解決できる、または jj workspace 向けの妥当な fallback がある)
- [ ] (a)(b) のトレードオフを踏まえた修正方針が決定・実装される
