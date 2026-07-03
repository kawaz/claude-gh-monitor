---
title: PostToolUse hook が別リポへの push 時に session cwd 側の repo/SHA を案内する (誤対象の watch 指示)
status: open
category: bug
created: 2026-07-03T14:25:34+09:00
last_read:
open_entered: 2026-07-03T14:25:34+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: claude-rules-personal
---

# PostToolUse hook が別リポへの push 時に session cwd 側の repo/SHA を案内する (誤対象の watch 指示)

## 概要

push 直後に watch-workflow 起動を促す PostToolUse hook が、Bash コマンド内で `cd` して session cwd と異なるリポへ push したケースで、**実際に push された repo/SHA ではなく session cwd 側の repo/SHA** を案内する。

案内どおり watch を起動すると誤対象を監視することになる。加えて、案内された repo が `.github/workflows` 自体を持たない場合、no-match-timeout まで待つだけの無駄な watcher になる。

クロスプロジェクト起票 (= claude-rules-personal 作業中のセッションによるフラグ起票)。部外者観測なので、採否・修正方針は本リポ担当側で裏取りの上判断してほしい。

## 背景

2026-07-03、claude-rules-personal をセッション cwd とする Claude Code セッションで実機観測。

### 観測した現象 (再現ログ付き)

1. セッション cwd は `claude-rules-personal/main` のまま、Bash で `cd .../claude-cmux-msg/main && just push` を実行し cmux-msg を push した
2. 直後の PostToolUse hook が案内した watch 対象は `kawaz/claude-rules-personal@4ee2551` だった
   - `4ee2551` は claude-rules-personal のローカル tip (当時未 push) の commit
   - 実際に push されたのは `kawaz/claude-cmux-msg` の `c326c238`
   - さらに claude-rules-personal は `.github/workflows` 自体が存在しないリポで、案内通り起動すると no-match-timeout まで待って終わるだけの watcher になる
3. その後 claude-rules-personal 自身を push した際の hook 案内 (`kawaz/claude-rules-personal@b4cc3af`) は正しかった (= cwd と push 対象が一致するケースは正常)

### 仮説 (未検証)

hook が repo/SHA を「セッションの cwd」または「hook 実行時の作業ディレクトリ」から解決しており、Bash コマンド内の `cd` で別リポへ移動して push したケースを追えていない可能性。一次資料はこの issue の再現ログと、hook 実装内の repo/SHA 解決部分。

## 受け入れ条件

- [ ] hook が repo/SHA をどこから解決しているか実装を確認し、上記仮説の裏取りをする
- [ ] `cd` 経由で session cwd と異なるリポへ push したケースでも正しい repo/SHA を案内できるよう修正 (または少なくとも不一致を検知して警告に倒す)

## 参考: ついでの気づき (別論点、採否お任せ)

workflow を 1 つも持たないリポ (例: claude-rules-personal) への push でも watch 起動が案内される。起動しても no-match 待ちで終わるだけなので、`.github/workflows` 不在を検出してスキップできると無駄がない。
