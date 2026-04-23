#!/usr/bin/env bash
# Claude Code SessionStart hook.
# 現在の worktree に紐づく open PR を検出して pr-watch スキルの起動を促す。
#
# 設計思想:
#   - hook 自身では Monitor を起動しない（Monitor のライフサイクルは Claude 本体が管理すべき）
#   - hook は "pr-watch スキルを起動してほしい" というメッセージを stdout に出すだけ
#   - stdout は Claude Code のコンテキストに注入されるので、Claude が読んで判断する
#
# hook の exit code は 0 固定（PR 無しでも "何も出力しない exit 0"）

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# 作業ディレクトリ (CLAUDE_PROJECT_DIR 優先)
workdir=${CLAUDE_PROJECT_DIR:-$(pwd)}

# PR 検出
result=$("$REPO_ROOT/scripts/detect-pr.sh" "$workdir" 2>/dev/null || true)
if [ -z "$result" ]; then
    # PR 無しなら何も出さずに終了
    exit 0
fi

repo=$(printf '%s' "$result" | cut -f1)
pr=$(printf '%s' "$result" | cut -f2)

# Claude への指示（構造化メッセージ）
# "[claude-pr-monitor]" プレフィックスで目印を付ける
cat <<EOF
[claude-pr-monitor] SessionStart hook: このセッションの worktree は PR ${repo}#${pr} に紐づいています。

pr-watch スキルを起動して、この PR の状態変化（新規コメント・レビュー・CI・マージ状態）を Monitor で継続監視してください。

起動引数:
- OWNER/REPO: ${repo}
- PR_NUMBER:  ${pr}

重複防止: 既に同じ PR を監視している Monitor タスクがある場合（description に "PR ${repo}#${pr} 監視" が含まれる）、追加起動は不要です。
EOF
