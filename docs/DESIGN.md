# claude-pr-monitor 設計ドキュメント

## この文書の目的

新しく立ち上げる Claude Code セッションが、過去の議論を知らない状態でこのプロジェクトを引き継げるようにするための完全なコンテキスト共有ドキュメント。

---

## 1. 背景と動機

### 既存の痛み

- 複数 PR を並行で回していると、レビュー待ち・CI 待ちのまま長時間放置してしまう
- 手動で `gh pr view` / `gh pr checks` を繰り返すのは非効率で、Claude Code の会話コンテキストをそのぶん圧迫する
- PR が動いたタイミングで気付ける仕組みが欲しい

### 既存手段との比較

| 手段 | 気付ける粒度 | コスト |
|---|---|---|
| メール通知 | 大体全部（ノイジー） | メールソフト切替 |
| GitHub デスクトップ通知 | コメント/レビュー | OS 設定依存 |
| 手動 `gh pr view` を繰り返す | 狙った時だけ | 会話コンテキスト圧迫 |
| **本ツール** | **会話に必要な粒度のみ** | Bash プロセス 1本 (~2MB) |

### Claude Code の Monitor ツールの特性

- 長時間スクリプトの stdout 1行ごとに通知をチャットに届けられる
- `persistent: true` でセッション終了まで継続
- 複数セッションで独立に起動できる

これを活かして「PR 状態ポーリング → 変化時だけ 1 行 emit」の Bash スクリプトを常駐させる。

---

## 2. 決定事項（本プロジェクトの前提）

議論の結果ユーザーと合意済みの前提。

| # | 項目 | 決定内容 |
|---|---|---|
| 1 | 起動形態 | **SessionStart hook** で自動起動（手動 `/pr-monitor` スキルも提供） |
| 2 | 監視項目 | 新規コメント / レビュー state変化 / CI state変化 / PR state (open/closed/merged) |
| 3 | セッション間の干渉 | **(A) 各セッション独立**（Bash で 1プロセス ~2MB なのでロック機構は不要） |
| 4 | 終了条件 | **セッション終了時**（= 基本常時稼働）。PR merged / closed でもスクリプト側で exit 0 |
| 5 | 配置場所 | **`github.com/kawaz/claude-pr-monitor`** 新規リポジトリ（個人 OSS、MIT） |
| 6 | 実装言語 | **Bash + `gh` + `jq`**（メモリ効率重視。Bun/TS 検討もしたが 1PR=2MB 優位） |

### 議論の経緯（要点）

- 当初、hook 改善やシェル/TS 選定の議論があった
- 実測: Bash ~2MB / Bun ~22MB / Node ~46MB。多数セッション並走を想定して Bash 選択
- SessionStart hook は「ブランチ → PR 自動検出 → 監視起動指示を出す」責務のみに限定
- 実際の Monitor 起動は Claude Code harness 経由（hook 自身では起動しない）
- 数十セッション並走でも問題ない負荷、パーミッション問題が出るロック機構は不要

---

## 3. アーキテクチャ

```
[Claude Code Session 開始]
        │
        ▼
[SessionStart hook] ← settings.json の hooks.SessionStart で登録
        │
        ▼
[hooks/session_start.sh] ← bash ラッパー
        │
        ▼
[scripts/detect-pr.sh] ← 現 worktree のブランチ → PR 検出
        │
        │ (PR 見つかれば)
        ▼
[stdout に Monitor 起動指示を出す] ← Claude 本体が見て Monitor 起動
        │
        ▼
[Monitor ツール] で [scripts/pr-monitor.sh] を常駐起動
        │
        ▼ 60s ごと
[gh pr view ... --json] → [jq でハッシュ化して前回と比較]
        │
        │ (変化あり)
        ▼
[stdout に 1 行] → Monitor が [task-notification] として Claude に届ける
        │
        ▼
[Claude が必要ならユーザーに報告]
```

### コンポーネント

| ファイル | 責務 |
|---|---|
| `hooks/session_start.sh` | SessionStart hook。PR 検出 → Monitor 起動指示を stdout に出す |
| `scripts/detect-pr.sh` | カレントブランチから open PR を検出。`OWNER/REPO\tPR_NUMBER` を出す |
| `scripts/pr-monitor.sh` | Monitor 対象本体。60s ごとに `gh pr view` し、変化時のみ 1 行 emit |
| `skills/pr-monitor/SKILL.md` | 手動起動用のスキル定義。AI が判断して呼ぶ |
| `settings.json.sample` | `.claude/settings.json` への組み込みサンプル |

### スクリプト間の責任分担

- **hook は指示を出すだけ**。Monitor 起動は Claude Code 本体が SessionStart hook の出力を読んで実行する想定
  - 理由: hook が子プロセスとして Monitor を起動すると、hook 終了時にそのプロセスの寿命管理が曖昧になる
  - Monitor ツール経由で起動させることで「セッションの一部」として正しくライフサイクル管理される
- **pr-monitor.sh は差分検出と emit だけ**。重複起動防止は上位層（Monitor）の責務

---

## 4. 動作仕様

### 起動時

```
[WATCH-START] OWNER/REPO #N (interval=60s)
```

### 変化検出時に出る行

| 行頭パターン | 意味 | 例 |
|---|---|---|
| `[COMMENT by <login>] <body 先頭200字>` | 新規コメント | `[COMMENT by shintaroino] LGTM with a small suggestion…` |
| `[REVIEW <STATE> by <login>]` | レビュー提出 | `[REVIEW APPROVED by shintaroino]` |
| `[CI] <name>=<state>, ...` | CI check 状態サマリ（変化時のみ） | `[CI] Test=success, Detect parallel changes=failure` |
| `[MERGED] at <timestamp> - watch ends` | マージ検出 → 直後 exit | `[MERGED] at 2026-04-23T02:00:00Z - watch ends` |

### ハッシュ比較で同一視するフィールド

```jq
{
    state, mergedAt,
    comments: [.comments[] | {createdAt, a:.author.login}],
    reviews:  [.reviews[]  | {state, a:.author.login, submittedAt}],
    checks:   [.statusCheckRollup[] | {name, status, conclusion}]
}
```

本文の細かい編集（既存コメントのタイポ修正等）では emit しない。リアクション追加でも emit しない。「誰がいつ行動したか」を追う設計。

---

## 5. 進捗と残課題

### (A) skill-creator プロセス ✅ 完走

- SKILL.md を draft から実装整合版に更新（2026-04-23）
- `evals/evals.json` を 3 → 7 ケースに拡充（dup-avoidance, multi-PR, stop, closed 追加）
- skill description optimizer 未実施（GitHub 公開後に iterate 予定）

### (B) SessionStart hook ✅ 改修済み

- hook 出力は「pr-monitor スキルを起動してほしい」という明示指示に構造化
- 起動引数・重複防止方法を箇条書きで提示し Claude が読み取りやすい形に
- 実際の Claude 受け取り挙動は実運用セッションで継続観察

### (C) 重複起動防止 ✅ 対応済み

- SKILL.md に TaskList での確認手順を明文化
- description `PR owner/repo#N 監視` をキーにして重複判定

### (D) 複数 PR 対応 ✅ 対応済み

- SKILL.md に「PR ごとに個別 Monitor を起動してよい」ルールを追記
- description で区別すれば重複判定もそのまま動作

### (E) 設定ファイル配布 ✅ ドキュメント化

- README.md に 推奨(グローバル) / プロジェクト毎 の両方を明記
- 前提（gh / jq / gh auth）も README 冒頭に記述

### (F) 実運用検証 ⏳ 継続

- antenna #2108 Monitor は別セッション所属のため本セッションから直接観察不可
- 代わりに emit 部を jq 単体で dry-run し、DESIGN.md §4 仕様に沿うことを確認
  （[docs/findings/2026-04-23-emit-dry-run.md](findings/2026-04-23-emit-dry-run.md)）
- GitHub 公開後、実運用セッションで観察される emit を基に必要な調整を行う

### 追加の改善候補（将来）

- `[CI]` 行で PR check の URL まで含める（failure 時に深堀りが速い）
- `--watch-own` / `--watch-assigned` 等の CLI 引数で対象を切り替え
- ChangeLog / `--version` 追加（公開時）

---

## 6. 参考情報

### このドキュメントが書かれた時点の状況

- 発案元セッション: antenna リポジトリで PR #2108 (`security(log): MONGO_URI ログ出力のパスワード漏洩対策`) のレビュー待ち
- そこで pr-monitor.sh を antenna セッションの Monitor で稼働させて動作確認中
- 同じ仕組みを汎用化して本プロジェクトに切り出す流れ

### 本プロジェクトの由来 PR (動作検証中)

- https://github.com/emeradaco/antenna/pull/2108
- 監視 Monitor Task ID: `bzrlv2xnb` (antenna セッション)

### 関連リポジトリ

- antenna: https://github.com/emeradaco/antenna （社内）

### 新規リポジトリ作成時の経緯

- owner は `kawaz`（個人 OSS）、`kawaz123` は仕事用 private 原則のため除外
- `gh` 認証が kawaz123 のみだったため GitHub 側へのリモート作成は保留、ローカルのみ先行構築
- jj workflow 採用（`.jj` ありのため jj-workflow.md に従う）

### jj workspace 構成

```
github.com/kawaz/claude-pr-monitor/
├── .git/         # git bare
├── .jj/          # jj default workspace (空の @ を保持して上位 .git/.jj 探索のガードを兼ねる)
└── main/         # メイン作業 workspace（ここで開発）
```
