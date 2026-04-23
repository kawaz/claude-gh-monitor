#!/usr/bin/env bash
# Claude Code SessionStart hook.
# 現在の worktree に紐づく open PR を検出して pr-watch.sh の起動指示を stdout に出す。
#
# hook としての期待動作:
#   - PR が検出できれば、Monitor ツール起動を促す指示を stdout に出す
#     (Claude 本体が見て適切に Monitor を起動する)
#   - 検出できなければ sys.exit(0) 相当で終了（無害）
#
# ※ hook は Claude Code harness から呼ばれる前提。
#   単独で Monitor を起動することはしない（harness の責務を尊重）。

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT="$SCRIPT_DIR/.."

# 作業ディレクトリ (CLAUDE_PROJECT_DIR が設定されていればそれを使う)
workdir=${CLAUDE_PROJECT_DIR:-$(pwd)}

# PR 検出
result=$("$REPO_ROOT/scripts/detect-pr.sh" "$workdir" 2>/dev/null || true)
if [ -z "$result" ]; then
    # PR 無しなら何も出さずに exit 0
    exit 0
fi

repo=$(printf '%s' "$result" | cut -f1)
pr=$(printf '%s' "$result" | cut -f2)

# Claude に "この PR を監視してください" と指示するマーカー
# (SessionStart hook の出力は Claude のコンテキストに注入される)
cat <<EOF
[claude-pr-monitor] 現在のブランチは PR $repo#$pr に紐づいています。

Claude Code は以下のコマンドを Monitor ツールで起動してください（PR 状態の変化を通知するため）:

command: "$REPO_ROOT/scripts/pr-watch.sh" "$repo" "$pr"
description: "PR $repo#$pr 監視"
persistent: true
timeout_ms: 3600000

既に同じ PR を監視している Monitor があれば、重複起動は不要です。
EOF
