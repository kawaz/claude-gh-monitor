# claude-pr-monitor

Claude Code skill for PR state monitoring via SessionStart hook.

現在作業中のブランチに紐づく GitHub PR の状態変化（新規コメント / レビュー / CI / マージ状態）を、Claude Code の Monitor ツール経由で監視し、変化があった時だけメインコンテキストに通知する軽量スキル。

## 動機

- PR を出した後、レビュー待ち・CI 待ちの間に別作業をしているとき、通知が来ないと気付けない
- 手動で `gh pr view` を繰り返すのはコンテキストを圧迫する
- Claude Code の Monitor ツール + bash + gh CLI で、変化時だけ通知する軽量常駐プロセスが作れる

## 設計のポイント

- **hook で自動起動**: SessionStart hook が、開いているブランチに紐づく PR を検出し Monitor 起動を提案
- **変化時のみ emit**: ハッシュ比較（PR 全体用 / CI 用を独立管理）で前回状態と差分がある時だけ stdout に出す
- **軽量**: Bash + `gh` + `jq` のみ。1プロセス ~2MB 程度
- **終了条件**: PR が merged / closed、またはセッション終了時

## 前提

- [GitHub CLI (`gh`)](https://cli.github.com/) と `jq` がインストール済み
- `gh auth login` で対象リポジトリを読める権限で認証済み
- Claude Code 本体が Monitor ツールを利用可能（特にバージョン制約なし）
- git もしくは jj workspace 方式のリポジトリ配下で作業

## インストール

### 1. リポジトリを取得（公開後）

```bash
mkdir -p ~/.local/share/repos/github.com/kawaz
cd ~/.local/share/repos/github.com/kawaz
git clone https://github.com/kawaz/claude-pr-monitor.git
```

※ 現状はリモート未公開のためローカルで直接利用している状態。

### 2. `~/.claude/settings.json` にグローバル統合（推奨）

全プロジェクト共通で有効化する場合、`~/.claude/settings.json` に以下を merge:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "bash ${HOME}/.local/share/repos/github.com/kawaz/claude-pr-monitor/main/hooks/session_start.sh"
      }
    ]
  }
}
```

### 3. プロジェクト毎に有効化したい場合

プロジェクトの `.claude/settings.json` に同じ内容を入れる。チーム共有したければコミット、個人運用なら `.gitignore` に `.claude/settings.json` を追加する運用。`settings.json.sample` を参考に。

### 4. スキルを有効化

`~/.claude/skills/` からシンボリックリンクを張るか、Claude Code の skill 設定でスキル検索パスに `skills/` を追加。

```bash
mkdir -p ~/.claude/skills
ln -sf ~/.local/share/repos/github.com/kawaz/claude-pr-monitor/main/skills/pr-watch ~/.claude/skills/pr-watch
```

## 使い方

### 自動起動

PR に紐づいたブランチ（bookmark）で Claude Code を起動すると、SessionStart hook が PR を検出し、Claude が `pr-watch` スキル経由で Monitor を起動します。

### 手動起動

Claude との会話で「PR 監視して」「CI 通ったら教えて」等と伝えると、Claude が判断して起動します。PR 番号を明示的に指定することも可能:

```
"PR #2108 emeradaco/antenna を監視して"
```

## スキル/hook 配置

```
skills/
└── pr-watch/
    └── SKILL.md         # スキル定義
hooks/
└── session_start.sh     # SessionStart hook ラッパー
scripts/
├── pr-watch.sh          # Monitor 対象の Bash 本体
└── detect-pr.sh         # 現ブランチから PR 番号を検出
settings.json.sample     # .claude/settings.json への統合サンプル
```

## ドキュメント

- [docs/DESIGN.md](docs/DESIGN.md) — 設計ドキュメント（完全なコンテキスト共有用）
- [docs/findings/](docs/findings/) — 検証ログ
- [HANDOFF-PROMPT.md](HANDOFF-PROMPT.md) — 新セッションに渡すプロンプト

## License

MIT License, Yoshiaki Kawazu (@kawaz)
