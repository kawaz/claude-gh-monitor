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
| 1 | 起動形態 | **SessionStart hook** で自動起動（手動 `/pr-watch` スキルも提供） |
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
[Monitor ツール] で [scripts/pr-watch.sh] を常駐起動
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
| `scripts/pr-watch.sh` | Monitor 対象本体。60s ごとに `gh pr view` し、変化時のみ 1 行 emit |
| `skills/pr-watch/SKILL.md` | 手動起動用のスキル定義。AI が判断して呼ぶ |
| `settings.json.sample` | `.claude/settings.json` への組み込みサンプル |

### スクリプト間の責任分担

- **hook は指示を出すだけ**。Monitor 起動は Claude Code 本体が SessionStart hook の出力を読んで実行する想定
  - 理由: hook が子プロセスとして Monitor を起動すると、hook 終了時にそのプロセスの寿命管理が曖昧になる
  - Monitor ツール経由で起動させることで「セッションの一部」として正しくライフサイクル管理される
- **pr-watch.sh は差分検出と emit だけ**。重複起動防止は上位層（Monitor）の責務

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

## 5. 未着手・検討が必要な点（新セッションで進める）

### (A) スキルの skill-creator プロセス完走

skill-creator の標準プロセスに従って評価する:
1. SKILL.md の draft（作成済み）の精査
2. テストケース 2-3 個を `evals/evals.json` に書く
3. 実運用でいくつかの PR で動かしてみて、emit 内容の過不足を確認
4. フィードバックを受けて iteration

現状の draft は実装ベース。実運用と乖離があれば修正する。

### (B) SessionStart hook の Claude 側受け取り挙動確認

hook の stdout 出力を Claude Code がどのように扱うかの仕様を確認:
- hook 出力は `<session-start-hook>` 的なタグで Claude のコンテキストに注入されるはず
- 「Monitor 起動指示を出しても Claude が確実に Monitor ツールで起動してくれるか」を検証
- 起動を確実にするため、hook 出力のフォーマットを調整する可能性あり

### (C) 既存 Monitor との重複起動防止

同一セッション内で複数回 `/pr-watch` を呼ばれた場合、同じ PR に対して複数 Monitor が起動しないようにしたい:
- Monitor ツールに「既存タスク一覧を取る」機能があるか確認
- あれば起動前にチェック、なければ SKILL.md 側で Claude に注意を促す

### (D) 複数 PR 対応

1セッションで複数 worktree/PR を触るケース（稀だが存在）:
- 現状は SessionStart で検出した 1 PR のみ監視
- 必要なら `/pr-watch <PR>` 形式で追加起動できるよう、SKILL.md を拡張

### (E) 設定ファイルの配布

現在 `settings.json.sample` を示すだけ。ユーザーが自分のプロジェクトごとに統合する必要がある:
- グローバル `.claude/settings.json` に入れるなら1回で全プロジェクト有効化可
- プロジェクト毎に入れるなら `.gitignore` で除外する運用か、逆に commit してチーム共有か
- 推奨を SKILL.md または README に明記

### (F) 実運用での検証

antenna プロジェクトの PR #2108 で現行スクリプトを動かし中（このセッションの Monitor で）。実際の変化が emit されるか、誤検知がないかを観察して、設計にフィードバック。

---

## 6. 参考情報

### このドキュメントが書かれた時点の状況

- 発案元セッション: antenna リポジトリで PR #2108 (`security(log): MONGO_URI ログ出力のパスワード漏洩対策`) のレビュー待ち
- そこで pr-watch.sh を antenna セッションの Monitor で稼働させて動作確認中
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
