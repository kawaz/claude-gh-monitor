# 新セッション用ハンドオフプロンプト

下記をまるごとコピペして新しい Claude Code セッションに貼り付けてください。

---

```
あなたは kawaz/claude-pr-monitor という新規個人OSSリポジトリで、skill-creator スキルを使ってスキル開発を継続する役割です。

## リポジトリ情報

- パス: /Users/kawaz/.local/share/repos/github.com/kawaz/claude-pr-monitor
- git/jj 構成: git bare + jj workspace 方式（`.jj` が存在するので jj-workflow.md に従う）
- メイン作業 workspace: /Users/kawaz/.local/share/repos/github.com/kawaz/claude-pr-monitor/main
- GitHub リモート: 未作成（kawaz owner で作る予定だが認証が kawaz123 のみで未登録）

作業は `main/` workspace で実施してください。

## 最初に読むべきドキュメント

1. `main/README.md` — プロジェクト概要
2. **`main/docs/DESIGN.md` ← 完全なコンテキスト共有ドキュメント。必ず最初に通読すること**
3. `main/skills/pr-monitor/SKILL.md` — 現在の SKILL.md draft
4. `main/scripts/pr-monitor.sh`, `main/scripts/detect-pr.sh`, `main/hooks/session_start.sh` — 実装雛形
5. `main/evals/evals.json` — テストケース雛形
6. `main/settings.json.sample` — .claude/settings.json 統合例

## あなたのミッション

skill-creator の標準プロセスに従って `pr-monitor` スキルを本番品質まで仕上げる:

1. `docs/DESIGN.md` の「5. 未着手・検討が必要な点」を上から順に片付ける
   - (A) skill-creator プロセスの完走（draft の精査 → テストケース → iterate）
   - (B) SessionStart hook の Claude 側受け取り挙動の検証
   - (C) 既存 Monitor との重複起動防止
   - (D) 複数 PR 対応（必要なら）
   - (E) 設定ファイル配布方法の決定
   - (F) 実運用検証（下記参照）
2. skill-creator スキルを使い、テストケース（`main/evals/evals.json`）を実行してスキルの精度を評価
3. 必要に応じて iterate し、最後に skill description optimizer も走らせる

## 実運用検証中の PR（並行確認に使える）

- https://github.com/emeradaco/antenna/pull/2108 （`security(log): MONGO_URI ログ出力のパスワード漏洩対策`）
- このリポの `pr-monitor.sh` の素の版（ベタ打ち）が antenna セッションの Monitor で稼働中
- 実際に emit された通知内容を DESIGN.md のフィードバック材料として活用可

## 制約・前提

- **個人OSSなので License は MIT, Copyright は Yoshiaki Kawazu (@kawaz)**
- **GitHub リモートはまだ作られていない**。push 時は別途 `gh auth login` で kawaz アカウント追加が必要。それまではローカルのみで作業
- jj workflow: `jj describe -m` → `jj new` が基本サイクル。`jj git push` 時は `signing.behavior = "drop"` + `git.sign-on-push = true` 想定（kawaz 規約）
- Bash 実装が正（Bun/TS ではない。理由: 1プロセス 2MB 優先。DESIGN.md §2 参照）
- 絶対に破壊すべきでないもの: LICENSE, README, docs/DESIGN.md の「決定事項」テーブル

## 最初にやること

1. `main/docs/DESIGN.md` を通読し、文脈を把握する
2. 現状の雛形の品質を確認する（SKILL.md, scripts/*.sh）
3. skill-creator スキルを起動して、iteration-1 のテスト走行計画を立てる
4. ユーザーに「ここまで読んだ。次はこれをやる」と報告して承認を得てから実装に入る
```

---

## 備考

このリポジトリで作業を始める際は、セッションのベースディレクトリを `main/` 以下に切り替えると便利です（jj の default workspace は空の @ を保持する運用のため）。

新セッション側で `cd /Users/kawaz/.local/share/repos/github.com/kawaz/claude-pr-monitor/main` してから作業開始してください。
