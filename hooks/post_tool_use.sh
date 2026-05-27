#!/usr/bin/env bash
# Claude Code PostToolUse hook.
# Bash tool で git/jj/just/pkf push が成功した直後に、watch-workflow Monitor の
# 起動を Claude に促す additionalContext を返す。
#
# 設計思想 (DR-0002):
#   - hook 自身では Monitor を起動しない (ライフサイクル管理は Claude 本体)
#   - 注入する文字列は最小 1 行 (履歴蓄積を抑制)
#   - PostToolUse の context 注入経路は JSON の hookSpecificOutput.additionalContext
#
# 入力 (stdin JSON):
#   session_id, transcript_path, cwd, hook_event_name,
#   tool_name, tool_input, tool_response
#
# 出力:
#   - 起動指示を出す場合: JSON で hookSpecificOutput.additionalContext を返す
#   - それ以外: 何も出力しない (exit 0)
#
# 起動指示を出さない条件 (= exit 0 で黙る):
#   - tool_name が Bash でない
#   - tool_input.command が push regex にマッチしない
#   - tool_response が失敗 (is_error == true / interrupted == true)
#   - CLAUDE_PROJECT_DIR の origin remote から user/repo を解決できない

set -u

# plugin root の解決:
# additionalContext は plugin loader の ${CLAUDE_PLUGIN_ROOT} 置換対象外なので、
# Monitor 起動コマンドに埋める絶対パスを hook 内で resolve しておく。
# session_start.sh と同じ $0 ベース方式で env 依存を避ける。
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

input=$(cat)
if [ -z "$input" ]; then
    exit 0
fi

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$command" ] || exit 0

# push regex (DR-0003 確定版)
#   コマンド区切り (行頭 / `(` / `;` / `&` / `|`) のあとに
#   `git push` / `jj git push` / `just push` / `pkf run push` のいずれかが現れる
if ! [[ "$command" =~ (^|[\(\;\&\|])[[:space:]]*((jj[[:space:]]+)?git|just|pkf[[:space:]]+run)[[:space:]]+push($|[^a-zA-Z0-9_-]) ]]; then
    exit 0
fi

# tool_response の成否判定
# - is_error == true → 失敗
# - interrupted == true → 中断 (失敗扱い)
# - それ以外 (フィールドなし含む) → 成功とみなす (誤マッチは害が軽微)
if printf '%s' "$input" | jq -e '.tool_response.is_error == true or .tool_response.interrupted == true' >/dev/null 2>&1; then
    exit 0
fi

# CLAUDE_PROJECT_DIR の origin remote から user/repo を解決
workdir=${CLAUDE_PROJECT_DIR:-$(printf '%s' "$input" | jq -r '.cwd // empty')}
[ -n "$workdir" ] || workdir=$(pwd)

url=$(git -C "$workdir" config --get remote.origin.url 2>/dev/null || true)
[ -n "$url" ] || exit 0
url=${url%.git}

repo=""
# URL の先頭から厳密にマッチさせる。`attacker.com/github.com/...` のような中間
# 詐称を防ぐため、ホスト部の前置プロトコル / ssh prefix を明示。
# 対応: https://github.com/o/r, http://github.com/o/r, ssh://git@github.com/o/r,
#       git@github.com:o/r
if [[ "$url" =~ ^(https?://|ssh://(git@)?|git@)github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then
    repo=${BASH_REMATCH[3]}
fi
[ -n "$repo" ] || exit 0

# additionalContext を JSON で返す
# Monitor 起動コマンドのパスは hook 内で解決した絶対パスを使う (literal
# ${CLAUDE_PLUGIN_ROOT} を埋めると Monitor 実行時に未定義で exit 127)
context="[gh-monitor] Monitor リストに 'watch-workflow: ${repo}' が無ければ、Monitor ツールで command=\`bash ${PLUGIN_ROOT}/scripts/watch-workflow.sh ${repo}\`, description=\`watch-workflow: ${repo}\`, persistent=true を起動せよ。"

jq -n --arg ctx "$context" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
    }
}'
