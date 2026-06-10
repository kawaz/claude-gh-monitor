# 2026-06-10 justfile を canonical / docs-structure 最新方針に追従

## 依頼の発端

「docs-structure や justfile のテンプレ的なものが更新されているので、確認して、こっちにも適用できるなら適用してほしい」(具体的な変更点までは未認識、とのこと)。

## 確認した結論

### docs/ 構造 — 変更不要 (準拠済み)

- 命名 (`DR-NNNN` 4桁 / `YYYY-MM-DD-<slug>`)、ja/en ペア + 相互リンクヘッダ (`> English | [日本語](...)`) すべて準拠
- STRUCTURE.md / MANUAL.md は任意で不在のままで OK

### justfile — canonical (kawaz/bump-semver) と照合して 3 点適用に合意 (#1+#2+#3)

| # | 内容 |
|---|---|
| #1 | `push-without-bump` recipe 削除。docs-only/workflow-only の変更は plugin 本体 paths に diff が無く `check-version-bumped` が自動 pass するので通常 `push` で通る。docs-structure skill も「不要」と明言。README.md / README-ja.md / CLAUDE.md の参照も除去済み |
| #2 | `bump-version` を atomic 化: `bump-semver vcs commit` を追加し write + commit を1コマンド完結に。従来は `--write` のみで working tree が dirty のまま残り、直後の `just push` が `ensure-clean` で失敗していた |
| #3 | just idiom 近代化: `set positional-arguments` / `set script-interpreter` / `[script]` recipe / `default: list` + `list --unsorted` (宣言順表示) を採用 |

### 維持した点 (古くない・意図的差分)

- `--no-hint`: v0.34.0 で現役 (`-q/-qq/--no-hint` エイリアス)。canonical の `--quiet` は未リリース版の別表記なので変更不要
- `check-versions` (multi-file 整合) / `check-version-bumped` の rc=3 防御 / `_post-push-hint`・`_on-release-success` 分離 = plugin multi-file + self-dogfood 固有事情

## 途中で直したバグ

`check-version-bumped` の exit-code コメントを最初 **逆** に書いた。正しくは git 慣習で `bump-semver vcs diff -q` は **0=diff なし / 1=diff あり / 3=VCS error**。case 文のロジックは原本踏襲で正しく、コメントのみ修正。

## ユーザーからの方針指摘 (作業途中・最重要の積み残し)

> **just 変数 (`bump-trigger-paths :=` / `version-files :=` 等) を使わない。**
> just 変数は文字列しか扱えず、`{{ }}` で shell に embed するとクオート/単語分割が壊れる。
> paths は各 recipe にリテラル直書き、引数は positional-arguments (`$1` / `$@`) で受ける。
> positional-arguments を基本に使うのも文字列 embed を極力避けるため。

→ これを受けて justfile を再書き換え中だった:
- `bump-trigger-paths` / `version-files` 変数を廃止 → 各 recipe に `.claude-plugin/plugin.json .claude-plugin/marketplace.json` 等をリテラル直書き
- `bump-version` の `{{ level }}` → `"$1"` (positional-arguments)
- variables セクションごと削除

**最後の Write は投げたが結果確認前に中断。次セッションで justfile の現状を確認し、fmt-clean / parse / `just ci` を通すこと。** (bump-version の `"$1"` は実行すると version を書き換えるので parse 確認まで。canonical bump-semver と同型なので構造は信頼できる)

## 未解決の謎 (要調査・ユーザー提起)

`justfile` を `Read` ツールで読むとトークン爆発して全文取得できず、`od` / `file` 等のコマンドも無反応になる現象が起きた。当初「ファイル破損」と誤検知したが:

- `iconv` / `python3` / jj committed 版との `cmp` で **valid UTF-8 かつ committed 版と完全一致** を確認 = **ファイルは壊れていない**
- 最初の「INVALID UTF-8」判定は、長い `&&` チェーン内で iconv にファイル名を引数渡しした際の誤判定だった
- 回避策: `tr -cd '\11\12\15\40-\176'` で非 ASCII を落として表示すれば内容を読める

**ユーザーの仮説「just 側がトークン数を制限しているのでは?」は未検証。** 実際には Read ツール / Bash 結果レンダリングが、日本語コメント (マルチバイト) 多めの justfile でトークン爆発するのが原因に見えるが、根本原因は未特定。次に同様の現象が出たら、まず `tr -cd` 濾過で読む。要すれば findings に切り出す。

## 現在のリポ状態

- 変更は working copy のみ、**未コミット・未 push** (justfile / README.md / README-ja.md / CLAUDE.md)
- これらは plugin 本体 paths 外なので push してもリリースは発生しない
- CHANGELOG / 旧 journal に残る `push-without-bump` 言及は履歴なので no-historical-noise 方針で温存

## 次アクション

1. justfile の現状を `tr -cd` 濾過で確認 (変数廃止・リテラル直書き・`"$1"` 化が反映されているか)
2. `just --unstable --fmt` で整形 → `just --list --unsorted` で parse 確認 → `just ci` で 15 tests pass 確認
3. 問題なければコミット (必要なら CHANGELOG 追記)。push 可否はユーザー確認
4. (任意) Read トークン爆発の根本原因を調査して findings 化

## 完了 (同セッション継続 — /clear せず続行)

積み残しを消化済み:

- **just 変数を全廃** (`bump-trigger-paths` / `version-files` 削除)。paths は各 recipe にリテラル直書き、`bump-version` の level は `{{ level }}` → `"$1"` (positional-arguments)
- **`_post-push-hint` を廃止** し push recipe に inline `@echo` 化 (canonical 寄せ)
- **`_on-release-success` → `on-success-release` にリネーム** (canonical 命名)。CLAUDE.md の参照 4 箇所も追従更新
- **コメント大幅削減** (多行説明 → 1 行)
- 検証: `just --fmt --check` clean / `just --summary` で全 recipe parse OK / `just list` / `just ci` 15 passed
- 変更ファイル: justfile / README.md / README-ja.md / CLAUDE.md (+ 本 journal)。未コミット・未 push

### Read トークン爆発の正体 (判明)

`Read` / `grep` / `od` が justfile で壊れる件は **ファイル破損ではない**。日本語コメント (マルチバイト) を含むテキストで、ツールの結果レンダリングがトークン超過する挙動。`just` 側のトークン制限ではない (just は正常に parse・実行できている)。回避策は確立済み: **`LC_ALL=C tr -cd '\11\12\15\40-\176'` で非 ASCII を落として読む**。`grep`/`tr` 自体も macOS では `LC_ALL=C` を付けないと "Illegal byte sequence" で落ちる。
