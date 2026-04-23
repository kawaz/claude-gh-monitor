# claude-pr-monitor

Claude Code skill for PR state monitoring via SessionStart hook.

現在作業中のブランチに紐づく GitHub PR の状態変化（新規コメント / レビュー / CI / マージ状態）を、Claude Code の Monitor ツール経由で監視し、変化があった時だけメインコンテキストに通知する。

## 動機

- PR を出した後、レビュー待ち・CI待ちの間に別作業をしている最中、通知が来ないと気付けない
- 手動で `gh pr view` を繰り返すのはコンテキストを圧迫する
- Claude Code の Monitor ツール + bash + gh CLI で、変化時だけ通知する軽量常駐プロセスが作れる

## 設計のポイント

- **hook で自動起動**: SessionStart hook が、開いているブランチに紐づく PR を検出し Monitor を起動
- **変化時のみ emit**: ハッシュ比較で前回状態と差分がある時だけ stdout に出し、Claude のコンテキストを圧迫しない
- **軽量**: Bash + `gh` + `jq` のみ。1プロセス ~2MB 程度
- **終了条件**: PR が merged / closed、またはセッション終了時

## スキル/hook 配置

```
.claude/
├── hooks/
│   └── session_start.sh     # SessionStart hook ラッパー
├── scripts/
│   ├── pr-watch.sh          # Monitor 対象の Bash 本体
│   └── detect-pr.sh         # 現ブランチから PR 番号を検出
└── skills/
    └── pr-watch/
        └── SKILL.md         # 手動起動もできるスキル定義
```

## ドキュメント

- [docs/DESIGN.md](docs/DESIGN.md) — 設計ドキュメント（完全なコンテキスト共有用）
- [HANDOFF-PROMPT.md](HANDOFF-PROMPT.md) — 新セッションに渡すプロンプト

## License

MIT License, Yoshiaki Kawazu (@kawaz)
