---
title: post_tool_use.sh の --sha 案内が push 前 / push 失敗時 / background 起動時に誤る
status: open
category: bug
created: 2026-09-23T16:43:15+09:00
last_read:
open_entered: 2026-09-23T16:43:15+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: llm-gateway 統括セッション
---

# post_tool_use.sh の --sha 案内が push 前 / push 失敗時 / background 起動時に誤る

## 概要

`hooks/post_tool_use.sh` が案内する `--sha` が、実際に push された commit と違うことがある(署名で id が変わる jj リポ、`git.sign-on-push`)。

## 背景

実測 2026-09-23(llm-gateway、`just push`):

1. Bash ツールの `run_in_background` で `just push` を起動すると、hook は起動直後(push 完了前)に発火し、`bump-semver vcs get commit-id` がローカル head `4557e1b` を返す。その後 `bump-semver vcs push` が `Updated signatures of 5 commits` で id を書き換え、実際に push されたのは `1cb91e0`。Monitor は `no matching run for SHA 4557e1b after 300s` で空振りした。
2. push が `ensure-clean` 等の deps で失敗した時も、hook は exit code や push の実行有無を見ずに sha を案内する。
3. コマンド文字列に `just push` が含まれるだけで発火する(push を含む grep や cat の実行でも案内が出る)。

改善案(裏取りして採否を決めて):

- push 完了を示す出力(`Changes to push to origin` / `pushed`)と exit code 0 を条件に発火する
- sha は push 後の remote 側(`main@origin` = `jj log -r 'main@origin' -T commit_id` / `git rev-parse origin/main`)から取る
- background 起動(tool 出力が `Command running in background`)では発火せず、完了通知側で案内する
- コマンド文字列判定を `^just push` / `jj git push` のトークン境界に絞る

## 受け入れ条件

- [ ] push 完了(exit 0 かつ push 実行済み)を確認してから `--sha` を案内する
- [ ] sha は push 後の remote 側から取得する(署名で id が変わるケースで正しい値になる)
- [ ] background 起動時は起動直後に発火しない
- [ ] コマンド文字列判定がトークン境界で絞られている(grep/cat 等の誤爆がない)
