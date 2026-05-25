# DR-0001: `pr-monitor` → `gh-monitor` 改名 + スコープ拡大

- ステータス: Accepted
- 日付: 2026-05-25
- 関連: DR-0002 (hook 出力最小化), DR-0003 (workflow-watch 常駐 Monitor), `docs/DESIGN.md`

## 文脈

現 `pr-monitor` プラグインは branch に紐づく GitHub PR の状態変化 (コメント / レビュー / CI / マージ) を Monitor ツールで通知する 3-layer 構成 (SessionStart hook → skill → `scripts/pr-monitor.sh`)。

実運用してみて以下の乖離が見えた:

- **個人プロジェクトでは Issue/PR を立てずに進める**ことが多く、PR 監視はほとんど空振り
- 一方で **push 後の GitHub Actions workflow run の watch はほぼ毎回欲しい** (`push-workflow.md` ルールでも push 後の CI watch を必須化している)
- 既存 `pr-monitor` の名前と機能のままだと、workflow run 監視を追加しても名前と機能が乖離する

## 決定

**プラグインを `gh-monitor` に改名し、機能を 2 本立てに拡張する。**

| 機能 | 役割 |
|------|------|
| `pr-watch` | 旧 `pr-monitor` 相当 (PR の状態変化監視)。中身はほぼ流用 |
| `workflow-watch` | 新規。GitHub Actions の workflow run の start/success/failure 等を低コンテキストで通知 |

両機能の抽象は揃っており「GitHub の非同期イベントを Monitor で低コンテキスト通知する」で 1 つのプラグインに束ねられる。`gh-monitor` は 2 機能を束ねる中立名。

## 理由

1. **実需との整合**: 個人用途で `pr-monitor` が空振りする一方、workflow 監視は毎 push 欲しいニーズ。`gh-monitor` に拡張することで「実際に使われる最小コア」になる
2. **共通抽象**: 両機能とも「GitHub をポーリング → 状態変化を 1 行で emit → Monitor が拾って Claude に通知」のパターン。設計の重複コストが小さい
3. **改名のコストは初期化フェーズで吸収可能**: まだ採用ユーザは kawaz 個人のみ (alpha 段階)。後方互換を引きずる前に改名する方が筋が良い (`design-priority.md` の「後方互換性で設計を曲げない」と整合)

## 不採用案

### A. `pr-monitor` のまま workflow 監視を追加

プラグイン名と機能の乖離が発生する。skill / script / hook の命名も「monitor は PR を見るのか workflow を見るのか」が読み取れなくなる。

### B. `workflow-monitor` を別プラグインとして分離

3-layer 構成 (hook / skill / scripts) が完全に重複する。Monitor 起動の重複防止規約 (description = `<feature>: <key>`) も共通化されないため、運用面で 2 つのプラグインを別個に意識する必要が出る。

### C. PR 監視を捨てて `workflow-watch` 専用プラグインにする

業務リポ (Issue/PR を実際に立てる環境) では PR 監視も価値がある。個人専用に切り詰めると業務リポ共用の余地を失う。

## 移行ステップ (次セッションで実装)

1. リネーム後リポ (`claude-gh-monitor`) clone 済みを確認 (本コミット時点で完了)
2. クリーンアップ: `evals/` (skill-creator の eval 成果物) と `HANDOFF-PROMPT.md` (旧ハンズオフ) を削除
3. 改名作業 (`pr-monitor` 文字列は全体で 76 箇所程度):
   - `.claude-plugin/plugin.json` / `marketplace.json` の `name` / `homepage` / `repository`
   - `skills/pr-monitor/` → 改名 (skill 構成は未決論点、後述)
   - `scripts/pr-monitor.sh` → `scripts/pr-watch.sh`
   - `hooks/session_start.sh` の注入メッセージ・prefix `[claude-pr-monitor]` → `[gh-monitor]` 等
   - README / DESIGN / CLAUDE.md / CHANGELOG / findings/ の記述
4. `workflow-watch` 実装: `scripts/workflow-watch.sh` + workflow 監視 skill + PostToolUse hook (`hooks/hooks.json` に追加)
5. `docs/issue/` の 2 件 (justfile/CI/dependabot 移行、docs-structure 移行) を棚卸し

## 未決の論点

- **skill を何本にするか**: `pr-watch` と `workflow-watch` の skill を分けるか、`gh-monitor` skill 1 本にサブ機能としてまとめるか
- **手動起動用 invocable skill**: `/gh-monitor:watch-ci` のように明示起動できる skill を用意するか (push トリガとは別の手動起動経路)

いずれも次セッション冒頭で確定させる。

## 関連

- DR-0002: hook 出力を最小化する設計判断
- DR-0003: workflow-watch を repo 単位の常駐 Monitor 1 本にする判断
- `docs/DESIGN.md`: 3-layer 構成の説明 (改名時に同期更新)
- `~/.claude/rules/push-workflow.md`: push 後の CI watch を必須化する個人ルール (本 DR の動機の 1 つ)
