# `docs/` 構造を kawaz/* 横断ルールに揃える (`~/.claude/rules/docs-structure.md`)

## 背景

kawaz/* 横断の `docs/` 構造ルール (`~/.claude/rules/docs-structure.md`) に従い、リポジトリの構造を整える依頼。本リポは `docs/issue/` ディレクトリが存在しないため、本 issue 自体は cmux-msg-impl ワーカーが暫定で起票した形になる (本 issue を保存するための `docs/issue/` 自体を新設する必要がある)。

## やること

1. `docs/issue/` ディレクトリを新設
2. 既存の `docs/` 配下のドキュメント命名を整える:
   - サブディレクトリ内のファイル名は `YYYY-MM-DD-<slug>.md`
   - 例外: `decisions/DR-NNNN-title.md`、`design/<topic>-<sub>.md`
3. リポジトリ直下の `DESIGN.md` `STRUCTURE.md` `ROADMAP.md` `MANUAL.md` 等は `docs/` 配下に移動
4. 必要なサブディレクトリを採用 (使う場合のみ):
   - `docs/decisions/` (DR、`INDEX.md` 必須)
   - `docs/findings/` (単発調査の確定事実)
   - `docs/journal/` (日々の生記録、ハマり所→解決策のペア)
   - `docs/runbooks/` (運用・復旧手順)
   - `docs/knowledge/` (時系列依存しない長期ナレッジ)
5. 言語ポリシー (公開リポは `README-ja.md` 原本 + `README.md` 英訳ペア、`check-translations` レシピで監視):
   - 英語版冒頭: `> English | [日本語](./README-ja.md)`
   - 日本語版冒頭: `> [English](./README.md) | 日本語`
   - 同様に `docs/DESIGN{,-ja}.md`、`docs/MANUAL{,-ja}.md` (作る場合)

## 参考

- ルール本体: `~/.claude/rules/docs-structure.md`
- 知識保存フロー: `~/.claude/rules/docs-knowledge-flow.md`
- 参考実装: kawaz/claude-cmux-msg
- `check-translations` テンプレ: kawaz/jj-worktree `justfile`

## 優先度

**中** (リポを触ったついでで揃える方針、一気に migration する必要はなし)。

ただし `docs/issue/` だけは「本 issue を保存している場所」なので、最初の commit の段階で必ず作成される。

報告者: kawaz/claude-cmux-msg `cmux-msg-impl` ワーカー (kawaz の指示で 2026-05-09 に横展開を実施)
