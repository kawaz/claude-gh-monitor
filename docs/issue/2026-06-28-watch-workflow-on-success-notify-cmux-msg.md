---
title: watch-workflow に --on-success-notify API を追加して cmux-msg notify --self に統合
status: open
category: design
created: 2026-06-28T22:04:19+09:00
last_read:
open_entered: 2026-06-28T22:04:19+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: kawaz/die
---

# watch-workflow に --on-success-notify API を追加して cmux-msg notify --self に統合

## 概要

`gh-monitor:watch-workflow` に `--on-success-notify <command>` / `--on-failure-notify <command>` を追加し、cmux-msg の `notify --self` 経由で AI セッションへ自動通知する仕組みを実装する。

## 背景

`gh-monitor:watch-workflow` の `--on-success <key> <msg>` は workflow success 時に通知に `[ACTION:<key>] <msg>` を emit する設計だが、AI (= Claude) が **3 引数 (`<key> <msg> <repo>`) を覚えてフルコピーする必要があり**、引数省略すると ACTION 通知が emit されない → 連鎖する自動化が止まる、という事故が起きやすい。

## 観測した事故 (kawaz/die 2026-06-28)

- die session が `just push` 後、push hint の `gh-monitor:watch-workflow --sha XXX --on-success release.yml 'just on-success-release' kawaz/die` を引数省略して `--sha XXX kawaz/die` だけで起動
- Release success 通知に `[ACTION:release.yml] just on-success-release` が **emit されず**、AI が brew upgrade trigger を読み取れなかった
- 結果として kawaz が手動で `brew upgrade die` を実行することに (= 完全自動化が破れた)

詳細は kawaz/die session log 911732b3-2e6b-4733-b035-5974e5f3f67f 周辺、本日 9 時頃の v0.0.2 → v0.2.0 修復の文脈参照。

## 提案 (= cmux-msg session 19801e54 と議論済)

cmux-msg の `notify --self` (v0.30.13+, DR-0017/0018) を経由する高レベル wrapper API を gh-monitor に追加:

```
--on-success-notify <command>
--on-failure-notify <command>
```

挙動:

1. workflow success / failure を検知
2. `cmux-msg notify --self --text "Bash で <command>"` を自動投入
3. die セッション側は既存の subscribe stream で受信、SKILL.md ルール (= 自 sid 由来の notify は即実行) に従って Bash で <command> を実行

利点:

- 引数が 1 つに減る (= AI 操作ミス耐性)
- cmux-msg の既存 self-notify 仕組みに自然に乗る (= 新規 communication 経路を作らない)
- 既存 `--on-success <key> <msg>` も併存可 (= 後方互換)

## 想定構成

```
[die セッション] push → release.yml 完了
                ↓
[ローカル host] gh-monitor watch-workflow が release.yml success を検知
                ↓
gh-monitor が --on-success-notify の引数を cmux-msg notify --self に変換して投げる
                ↓
[die セッション] subscribe stream で event_type=notify を受信、from===自 sid なので即実行
                ↓
just on-success-release → brew upgrade 完了
```

## die 側 push hint の併合例

```yaml
# justfile push recipe
push: ...
    bump-semver vcs push --branch main ...
    @echo "[hint] gh-monitor:watch-workflow --sha $(...) --on-success-notify 'just on-success-release' kawaz/die"
```

= 3 引数 → 1 引数で完結、AI が省略する余地が減る。

## 関連

- cmux-msg session 19801e54-8db7-4108-95be-9721d10a51ff からの reply (20260628T215326-c682eb30.md) で同案を提示
- cmux-msg SKILL.md の "self notify の典型パターン" 節 (DR-0017/0018)
- kawaz/die session 911732b3 のフロー再構築一連 (本日 21 時頃の v0.2.0 → v0.3.0 push)

## 推奨優先度

中。現状の `--on-success <key> <msg>` でも回せる (= AI が引数フルコピーすれば良い)。本 issue は **AI 操作ミス耐性を構造的に上げる** ための design 改善であって、機能的な穴塞ぎではない。die 以外の kawaz/* repo (= cache-warden, bump-semver, …) も同じ pattern を使うので、改善の波及範囲は広い。

## 受け入れ条件

- [ ] `watch-workflow --on-success-notify '<cmd>' <repo>` が動作する
- [ ] workflow success 時に cmux-msg notify --self 経由で AI セッションに通知が届く
- [ ] 既存 `--on-success <key> <msg>` との後方互換が保たれる
- [ ] SKILL.md の hint 例が新 API に更新されている
