# gh-monitor 設計ドキュメント

> [English](./DESIGN.md) | 日本語

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
| 5 | workflow 監視の起動戦略 | 2 モード: **SHA-pinned** (自分作業の第一推奨、SHA 単位並列許可、全 check terminal + grace で自動 exit) と **Passive** (明示オプトイン、repo 全体、1 本制限、idle backoff)。PostToolUse hook が push 検知で SHA-pinned を自動起動。DR-0003 の「repo 単位 1 本」は Passive 限定と再解釈 | [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) / [DR-0005](decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md) |
| 6 | セッション間の干渉 | 各セッション独立（Bash で 1 プロセス ~2MB なのでロック機構は不要）| — |
| 7 | 実装言語 | Bash + `gh` + `jq`（メモリ効率重視。Bun/TS 検討もしたが 1 プロセス ~2MB 優位）| — |
| 8 | 自セッション起因イベントの扱い | watch-pr の comment / review / merge のみデフォルト suppress（`GH_MONITOR_INCLUDE_SELF=1` で off）。workflow run は対象外（改定）| [DR-0004](decisions/DR-0004-suppress-self-originated-events.md) |

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

### watch-workflow (実装済み)

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
[Monitor ツール] で [scripts/watch-workflow.sh] を常駐起動
        │       SHA-pinned (hook 経由のデフォルト): 1 commit を追跡、SHA 単位で並列許可
        │       Passive (オプトイン): repo 単位 1 本、idle backoff (DR-0003)
        ▼ 30s+ ごと
[gh run list ... --json] → [起動時刻 lookback で baseline 構築 → 状態変化のみ emit]
        │
        ▼
[stdout に 1 行] → Claude に通知
        │
        ▼ SHA-pinned: 指定 SHA の全 check が terminal + grace 経過
[自動 exit]   Passive: --timeout 経過
```

詳細は [DR-0002](decisions/DR-0002-hook-minimal-output.md) / [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) / [DR-0005](decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md)。

### コンポーネント

| ファイル | 責務 |
|---|---|
| `.claude-plugin/plugin.json` | plugin manifest (name / version / author / repository) |
| `.claude-plugin/marketplace.json` | marketplace manifest (install 用) |
| `hooks/hooks.json` | hook 登録 (SessionStart + PostToolUse) |
| `hooks/session_start.sh` | hook 本体。PR 検出 → skill 起動指示を stdout に出す |
| `hooks/post_tool_use.sh` | hook 本体。Bash tool の push 成功検出 → JSON で additionalContext を返す |
| `scripts/detect-pr.sh` | カレントブランチから open PR を検出。`OWNER/REPO\tPR_NUMBER` を出す |
| `scripts/watch-pr.sh` | Monitor 対象本体。60s ごとに `gh pr view` し、変化時のみ 1 行 emit |
| `scripts/watch-workflow.sh` | Monitor 対象本体。30s ごとに `gh api .../actions/runs` を poll し、状態変化のみ 1 行 emit |
| `skills/watch-pr/SKILL.md` | watch-pr skill 定義。Monitor 起動引数・通知行の意味・重複防止 |
| `skills/watch-workflow/SKILL.md` | watch-workflow skill 定義。同上 |
| `justfile` | validate / lint / version / push |

### スクリプト間の責任分担

- **hook は最小指示だけ**。Monitor 起動は Claude 本体が hook の出力を読んで実行する想定
  - 理由: hook が子プロセスとして Monitor を起動すると、hook 終了時にそのプロセスの寿命管理が曖昧になる
  - Monitor ツール経由で起動させることで「セッションの一部」として正しくライフサイクル管理される
  - hook 出力の context 注入経路は event 種別で異なる: SessionStart は plain stdout、PostToolUse は JSON の `hookSpecificOutput.additionalContext`。詳細は [DR-0002](decisions/DR-0002-hook-minimal-output.md)
- **`watch-pr.sh` / `watch-workflow.sh` は差分検出と emit だけ**。重複起動防止は上位層（Monitor description マッチ）の責務

---

## 4. 動作仕様

### 共通 emit 設計

全 skill の出力は 2 系統の形式に揃える:

#### (a) skill 固有のイベント — `[scope:action] key:value ...` 形式

- 先頭の `[scope:action]` がイベント種別 (verb:noun)。例: `[run:change]` `[comment:add]` `[review:submit]` `[ci:change]` `[pr:merge]` `[pr:close]`
- 残り payload は `key:value` を空白区切り
- 値にスペース等を含む場合のみ double quote
- skill 名 / repo / PR# などのスコープ識別は **Monitor description** (= `<task-notification>` の `<summary>`) に逃がし、emit 行からは省略する
- description は SKILL.md で命名規約をロック (`watch-pr: <owner/repo>#<N>`, `watch-workflow: <owner/repo>`)。重複防止 (TaskList grep) もこの命名に乗る

#### (b) severity メッセージ — `[INFO|WARN|ERROR] <自由文>` 形式

- skill 固有イベントの構造化方式とは異質に保つ（payload は自然文 OK、KV 縛りを緩める）
- 起動 ack (`[INFO] <skill> start: <repo> (interval=...)`) はここに含める。description には乗らない設定値 (interval / lookback) も書ける
- 障害通知も `[WARN] gh ... が N 回連続失敗` のような自然文
- スクリプトの致命的な usage error 等は stderr に出す (stdout の通知経路に乗せない)

### watch-pr

#### 変化検出時に出る行

| イベント | 後続フィールド | 意味 |
|---|---|---|
| `[comment:add]` | `user:<login> url:<url> body:"..."` | 新規コメント、本文先頭 200 字、URL は深堀用 |
| `[review:submit]` | `user:<login> state:<STATE>` | レビュー提出 (url は gh CLI の json schema に無いため省略) |
| `[ci:change]` | `check:"<name>" status:<status> url:<url>` | CI check の状態変化（check 1 つにつき 1 行）、url は detailsUrl/targetUrl |
| `[pr:merge]` | `user:<login> commit:<sha7> at:<timestamp>` | マージ検出 → 直後 exit、mergedBy / mergeCommit が無い場合は該当 field を省略 |
| `[pr:close]` | (なし) | クローズ検出 → 直後 exit |
| `[INFO]` / `[WARN]` | (自然文) | 起動 ack / 復旧 / gh コマンド連続失敗 等 |

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

### watch-workflow

#### 起動 ack

```
[INFO] watch-workflow start: kawaz/foo (mode=sha-pinned sha=abc1234 grace=60s no-match-timeout=10m timeout=24h)
[INFO] watch-workflow start: kawaz/foo (mode=passive max-interval=10m timeout=24h)
```

#### 変化検出時に出る行

```
[run:change] workflow:ci.yml id:12345678 status:failure commit:abc1234 branch:main user:kawaz event:push
```

#### 障害通知

```
[WARN] gh api が 5 回連続失敗
[INFO] gh api が復旧 (5 回失敗のあと)
```

`status` の語彙は gh 準拠（`queued` / `in_progress` / `success` / `failure` / `cancelled` / `skipped` / `timed_out` / `action_required` 等をフラット化）。詳細は [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) / [DR-0005](decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md)。

---

## 5. 進捗

### watch-pr ✅ 実装済み

- SKILL.md / hook / script / detect-pr.sh は実装済み
- skill description optimizer 未実施（実運用 iterate で詰める）
- 実運用検証: [docs/findings/](findings/) 参照

### watch-workflow ✅ 実装済み

- 設計判断は [DR-0001](decisions/DR-0001-rename-and-scope-expand.md) / [DR-0002](decisions/DR-0002-hook-minimal-output.md) / [DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) / [DR-0005](decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md)
- DR-0003 の emit format からの差分: gh 2.92.0 の `gh run list --json` に `actor` field が無いため `gh api /repos/<owner>/<repo>/actions/runs?per_page=100` 経路に切り替え、`actor.login` と `event` の両方を emit に含める形に確定 (2026-05-26 実装時調整)
- SHA-pinned + Passive mode 必須化 (DR-0005): v0.4.0 で追加。matching run を一度も観測しないまま終わる場合の `--no-match-timeout` (デフォルト 10m) は v0.4.1 で追加。PostToolUse hook の jj-aware SHA 解決 (= empty working-copy commit を pin しない) は v0.4.2 で追加

### 追加の改善候補（将来）

- `[CI]` 行で PR check の URL まで含める（failure 時に深堀りが速い）
- 同一 repo を見る並列セッション間で API キャッシュを共有 (effective gh API 呼び回数を抑制): [docs/issue/2026-06-02-shared-cache-layer.md](issue/2026-06-02-shared-cache-layer.md)
- ノイジーな bot 連投 / CI 中間遷移を任意で suppress: [docs/issue/2026-05-26-suppress-noise-followups.md](issue/2026-05-26-suppress-noise-followups.md)
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
