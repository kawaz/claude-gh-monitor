---
title: docs/issue の旧形式 3 件が INDEX 未反映 + 他リポ向け issue の混入
status: idea
category: task
created: 2026-07-03T13:49:53+09:00
last_read:
open_entered:
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

# docs/issue の旧形式 3 件が INDEX 未反映 + 他リポ向け issue の混入

## 概要

kawaz の個人リポ群を横断監査したところ、claude-gh-monitor の docs/issue/ 配下に、
frontmatter 欠落または INDEX 未反映と見られる旧形式の issue が 3 件見つかった。
local-issue plugin の migrate sub-command の適用を推奨する。

また、pkf-tasks 向けと思われる issue ファイルが docs/issue/ 内に混入しているように
見えた。pkf-tasks リポへの移送、または close の判断が必要と思われる。

## 背景

これは部外者 (claude-rules-personal セッション) からの観測であり、該当する 3 件が
どのファイルか・移送すべき混入ファイルがどれかの特定は裏取りできていない。migrate
適用の要否・混入ファイルの扱いは担当側で確認の上で判断してほしい。出所: 2026-07-03
の個人エコシステム横断監査 (claude-rules-personal セッション発) より。

## 受け入れ条件

- [ ] docs/issue/ 配下で frontmatter 欠落 or INDEX 未反映のファイルを特定する
- [ ] 特定したファイルに local-issue plugin の migrate sub-command 適用の要否を判断する
- [ ] pkf-tasks 向けと思われる混入ファイルを特定し、移送 or close を判断する
