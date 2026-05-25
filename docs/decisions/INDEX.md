# Decision Records (DR) Index

gh-monitor の設計判断記録一覧。ファイル名は `DR-NNNN-title.md` (4 桁ゼロパディング)。`docs-structure.md` ルールに従い `## Active` / `## Archived` / `## Moved to research/` で区分する。

## Active

- [DR-0001](./DR-0001-rename-and-scope-expand.md) — `pr-monitor` → `gh-monitor` 改名 + スコープ拡大 (`pr-watch` + `workflow-watch` の 2 本立て)
- [DR-0002](./DR-0002-hook-minimal-output.md) — hook は「状態判定 + 1 行の Monitor 起動指示」に徹する (履歴蓄積抑制、重複防止は description マッチ)
- [DR-0003](./DR-0003-workflow-watch-persistent-per-repo.md) — `workflow-watch` は repo 単位の常駐 Monitor 1 本 (PostToolUse hook で push 検出をトリガに起動)

## Archived

(なし)

## Moved to research/

(なし)
