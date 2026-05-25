# gh-monitor 設計ドキュメント

## この文書の目的

新しく立ち上げる Claude Code セッションが、過去の議論を知らない状態でこのプロジェクトを引き継げるようにするための完全なコンテキスト共有ドキュメント。設計判断の詳細は [docs/decisions/](decisions/) を参照。

---

## 1. 背景と動機

### 既存の痛み

- 複数 PR を並行で回していると、レビュー待ち・CI 待ちのまま長時間放置してしまう
- 手動で `gh pr view` / `gh pr checks` / `gh run watch` を繰り返すのは非効率で、Claude Code の会話コンテキストをそのぶん圧迫する
- PR や workflow run が動いたタイミングで気付ける仕組みが欲しい

### 既存手段との比較

| 手段 | 気付ける粒度 | コスト |
|---|---|---|
| メール通知 | 大体全部（ノイジー） | メールソフト切替 |
| GitHub デスクトップ通知 | コメント/レビュー | OS 設定依存 |
| 手動 `gh pr view` / `gh run watch` を繰り返す | 狙った時だけ | 会話コンテキスト圧迫 |
| **本ツール** | **会話に必要な粒度のみ** | Bash プロセス 1本 (~2MB) |

### Claude Code の Monitor ツールの特性

- 長時間スクリプトの stdout 1行ごとに通知をチャットに届けられる
- `persistent: true` でセッション終了まで継続
- 複数セッションで独立に起動できる

これを活かして「GitHub をポーリング → 状態変化を 1 行 emit」の Bash スクリプトを常駐させる。

---

## 2. 決定事項

設計判断の正本は [docs/decisions/INDEX.md](decisions/INDEX.md)。本セクションは概要のみ。

| # | 項目 | 決定内容 | 参照 |
|---|---|---|---|
| 1 | スコープ | GitHub の非同期イベント（PR / workflow run）を低コンテキスト通知する | [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) |
| 2 | 配布形態 | Claude Code Plugin（`.claude-plugin/` + `marketplace.json`）| — |
| 3 | 機能構成 | `watch-pr` + `watch-workflow` の 2 本立て | [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) |
| 4 | hook の責務 | 「状態判定 + 1 行の Monitor 起動指示」に徹する | [DR-0002](decisions/DR-0002-hook-minimal-output.md) |
| 5 | workflow 監視の起動戦略 | repo 単位の常駐 Monitor 1 本（PostToolUse hook で push 検出をトリガに起動）| [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) |
| 6 | セッション間の干渉 | 各セッション独立（Bash で 1 プロセス ~2MB なのでロック機構は不要）| — |
| 7 | 実装言語 | Bash + `gh` + `jq`（メモリ効率重視。Bun/TS 検討もしたが 1 プロセス ~2MB 優位）| — |

### Bash 選択の経緯

実測: Bash ~2MB / Bun ~22MB / Node ~46MB。多数セッション並走を想定して Bash 選択。

---

## 3. アーキテクチャ

### watch-pr (実装済み)

```
[Claude Code Session 開始]
        │
        ▼
[SessionStart hook] ← plugin の hooks/hooks.json (matcher=startup|resume)
        │
        ▼
[hooks/session_start.sh] ← ${CLAUDE_PLUGIN_ROOT}/hooks/ 配下
        │
        ▼
[scripts/detect-pr.sh] ← 現 worktree のブランチ → PR 検出
        │
        │ (PR 見つかれば)
        ▼
[stdout に Monitor 起動指示を出す] ← Claude 本体が見て Monitor 起動
        │
        ▼
[Monitor ツール] で [scripts/watch-pr.sh] を常駐起動
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

### watch-workflow (実装予定、設計のみ)

```
[Claude が Bash ツールで git/jj/just/pkf push を実行]
        │
        ▼
[PostToolUse hook] ← push 検出 regex (緩い) + tool_response の成否判定
        │
        │ (push 成功時のみ)
        ▼
[JSON で hookSpecificOutput.additionalContext を返す]
        │
        │ Claude が context を読む
        ▼
[Monitor リストに `watch-workflow: <user/repo>` が無ければ起動]
        │
        ▼
[Monitor ツール] で [scripts/watch-workflow.sh] を repo 単位で 1 本常駐起動
        │
        ▼ 30s+ ごと
[gh run list ... --json] → [起動時刻 lookback で baseline 構築 → 状態変化のみ emit]
        │
        ▼
[stdout に 1 行] → Claude に通知
```

詳細は [DR-0002](decisions/DR-0002-hook-minimal-output.md) / [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md)。

### コンポーネント

| ファイル | 責務 |
|---|---|
| `.claude-plugin/plugin.json` | plugin manifest (name / version / author / repository) |
| `.claude-plugin/marketplace.json` | marketplace manifest (install 用) |
| `hooks/hooks.json` | hook 登録 (SessionStart 実装済 + PostToolUse 予定) |
| `hooks/session_start.sh` | hook 本体。PR 検出 → skill 起動指示を stdout に出す |
| `scripts/detect-pr.sh` | カレントブランチから open PR を検出。`OWNER/REPO\tPR_NUMBER` を出す |
| `scripts/watch-pr.sh` | Monitor 対象本体。60s ごとに `gh pr view` し、変化時のみ 1 行 emit |
| `scripts/watch-workflow.sh` | (未実装) repo の workflow run を継続 poll し、状態変化を 1 行 emit |
| `skills/watch-pr/SKILL.md` | skill 定義。Monitor 起動引数・通知行の意味・重複防止 |
| `justfile` | validate / lint / version / push |

### スクリプト間の責任分担

- **hook は最小指示だけ**。Monitor 起動は Claude 本体が hook の出力を読んで実行する想定
  - 理由: hook が子プロセスとして Monitor を起動すると、hook 終了時にそのプロセスの寿命管理が曖昧になる
  - Monitor ツール経由で起動させることで「セッションの一部」として正しくライフサイクル管理される
  - hook 出力の context 注入経路は event 種別で異なる: SessionStart は plain stdout、PostToolUse は JSON の `hookSpecificOutput.additionalContext`。詳細は [DR-0002](decisions/DR-0002-hook-minimal-output.md)
- **`watch-pr.sh` / `watch-workflow.sh` は差分検出と emit だけ**。重複起動防止は上位層（Monitor description マッチ）の責務

---

## 4. 動作仕様

### watch-pr

#### 起動時

```
[WATCH-START] OWNER/REPO #N (interval=60s)
```

#### 変化検出時に出る行

| 行頭パターン | 意味 | 例 |
|---|---|---|
| `[COMMENT by <login>] <body 先頭200字>` | 新規コメント | `[COMMENT by alice] LGTM with a small suggestion…` |
| `[REVIEW <STATE> by <login>]` | レビュー提出 | `[REVIEW APPROVED by alice]` |
| `[CI] <name>=<state>, ...` | CI check 状態サマリ（変化時のみ） | `[CI] Test=success, Detect parallel changes=failure` |
| `[MERGED] at <timestamp> - watch ends` | マージ検出 → 直後 exit | `[MERGED] at 2026-04-23T02:00:00Z - watch ends` |

#### ハッシュ比較で同一視するフィールド

```jq
{
    state, mergedAt,
    comments: [.comments[] | {createdAt, a:.author.login}],
    reviews:  [.reviews[]  | {state, a:.author.login, submittedAt}],
    checks:   [.statusCheckRollup[] | {name, status, conclusion}]
}
```

本文の細かい編集（既存コメントのタイポ修正等）では emit しない。リアクション追加でも emit しない。「誰がいつ行動したか」を追う設計。

### watch-workflow (実装予定)

#### 起動時

(初回 poll の baseline 構築まで無出力)

#### 変化検出時に出る行

軽量 1 行:

```
[watch-workflow] workflow:ci.yml id:12345678 status:failure commit:abc1234 user:kawaz branch:main
```

`status` の語彙は gh 準拠（`queued` / `in_progress` / `success` / `failure` / `cancelled` / `skipped` / `timed_out` / `action_required` 等をフラット化）。詳細は [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md)。

---

## 5. 進捗

### watch-pr ✅ 実装済み

- SKILL.md / hook / script / detect-pr.sh は実装済み
- skill description optimizer 未実施（実運用 iterate で詰める）
- 実運用検証: [docs/findings/](findings/) 参照

### watch-workflow ⏳ 設計のみ、実装はこれから

- 設計判断は [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) / [DR-0002](decisions/DR-0002-hook-minimal-output.md) / [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md)
- 残作業: `scripts/watch-workflow.sh` + PostToolUse hook + skill (skill 構成は 1 本にまとめるか分けるか未決)

### 追加の改善候補（将来）

- `[CI]` 行で PR check の URL まで含める（failure 時に深堀りが速い）
- `watch-workflow.sh` のオプション (`--only-mine` / `--workflow` / `--events`)。[DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) の「将来の拡張余地」参照
- 手動起動用 invocable skill (`/gh-monitor:watch-ci` 等)

---

## 6. 参考情報

### jj workspace 構成

```
github.com/kawaz/claude-gh-monitor/
├── .git/         # git bare
├── .jj/          # jj default workspace (空の @ を保持して上位 .git/.jj 探索のガードを兼ねる)
└── main/         # メイン作業 workspace（ここで開発）
```

owner は `kawaz`（個人 OSS、MIT）。jj workflow 採用（`.jj` ありのため jj-workflow.md に従う）。
