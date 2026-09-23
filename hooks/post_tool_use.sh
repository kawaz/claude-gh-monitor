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
#   - tool_input.command に実行単位先頭の push command がない
#   - tool_response に push 完了の証拠がない、または background 起動通知である
#   - CLAUDE_PROJECT_DIR の origin remote から user/repo を解決できない
#   - push 元リポのローカル checkout に .github/workflows/*.yml|*.yaml が 1 つも無い
#   - 今の commit の変更 files に対し、どの workflow の on.push.paths / paths-ignore
#     フィルタも trigger しない (= CI が走らないと確定できる場合。yq 不在 / parse 失敗は
#     fail-open で nudge、= 誤抑制で本物の CI watch を失うより誤 nudge の方が害が軽微)

set -u

# plugin root の解決:
# additionalContext は plugin loader の ${CLAUDE_PLUGIN_ROOT} 置換対象外なので、
# Monitor 起動コマンドに埋める絶対パスを hook 内で resolve しておく。
# session_start.sh と同じ $0 ベース方式で env 依存を避ける。
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# repo root を backend 非依存で解決する。
# git bare + jj workspace 構成 (親に bare .git、各 workspace は .git を持たない) では
# `git -C <workspace> rev-parse --show-toplevel` が bare リポに当たって exit 128 になり
# root を解決できない。bump-semver があれば `vcs get root` (git/jj/bare+workspace 全対応)
# を使い、無ければ従来の git rev-parse に fallback する。
# bump-semver は optional (配布 plugin なので一般ユーザ環境に無くても動く)。
_resolve_root() {
    local dir="$1" root=""
    if command -v bump-semver >/dev/null 2>&1; then
        root=$( { cd "$dir" 2>/dev/null && bump-semver vcs get root 2>/dev/null; } || true)
    fi
    if [ -z "$root" ]; then
        root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
    fi
    printf '%s' "$root"
}

input=$(cat)
if [ -z "$input" ]; then
    exit 0
fi

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$command" ] || exit 0

# push command は shell の実行単位の先頭だけを認識する。shlex で引用符・comment を
# 除外し、行頭 / && / ; の直後にある対応 command と --branch を抽出する。
push_info=$(python3 - "$command" <<'PY_COMMAND' 2>/dev/null || true
import shlex
import sys

lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=";&")
lexer.whitespace_split = True
lexer.commenters = "#"
tokens = list(lexer)
starts = {0} | {i + 1 for i, token in enumerate(tokens) if token in {";", "&&"}}
commands = (("jj", "git", "push"), ("git", "push"), ("just", "push"), ("pkf", "run", "push"))
for start in sorted(starts):
    for prefix in commands:
        if tuple(tokens[start:start + len(prefix)]) != prefix:
            continue
        end = next((i for i in range(start + len(prefix), len(tokens)) if tokens[i] in {";", "&&", "&"}), len(tokens))
        args = tokens[start + len(prefix):end]
        branch = ""
        for i, arg in enumerate(args):
            if arg.startswith("--branch="):
                branch = arg.split("=", 1)[1]
            elif arg == "--branch" and i + 1 < len(args):
                branch = args[i + 1]
        print("MATCH\t" + branch)
        raise SystemExit
PY_COMMAND
)
case "$push_info" in
    MATCH$'\t'*) push_branch=${push_info#*$'\t'} ;;
    *) exit 0 ;;
esac

# PostToolUse は成功した tool にだけ発火するが、Bash の正常終了だけでは push 完了の
# 証明にならない。background 起動通知を除外し、各 push backend の完了出力を要求する。
tool_response=$(printf '%s' "$input" | jq -r '[.tool_response // {} | .. | strings] | join("\n")' 2>/dev/null)
if printf '%s' "$input" | jq -e '.tool_response.backgroundTaskId != null' >/dev/null 2>&1; then
    exit 0
fi
if ! printf '%s\n' "$tool_response" | grep -Eq 'Changes to push( to origin)?|(^|[[:space:]])[^[:space:]]+[[:space:]]+->[[:space:]]+[^[:space:]]+'; then
    exit 0
fi

# push が実行された cwd を推測する。
#
# 問題: CLAUDE_PROJECT_DIR はセッション起点のプロジェクトディレクトリを指すが、
#   `cd /other/repo && just push` のような越境 push では push 対象が別リポになる。
#   CLAUDE_PROJECT_DIR 基準で repo/SHA を解決すると、別リポへの push を誤認する。
#
# 軽量対策: command に "cd <path>" が含まれる場合、最後の cd パスを解決基準に使う。
#   - "cd X && ... push" の形を想定、単純な 1 段 parse のみ
#   - 展開不能 (シェル変数 $HOME 等を含む) / 存在しないパス → フォールバック
#   - 多段 cd や複雑な構造は安全側 (CLAUDE_PROJECT_DIR) にフォールバック
#
# 安全原則: 解決に自信が持てないケースは nudge 側に倒す (過剰抑制で本物の CI watch を
#   失う方が損)。不正確でも「より正確に近い」方向に寄せるのみ。
_workdir_override=""
_last_cd=$(printf '%s' "$command" | grep -oE '(^|[;&|(])[[:space:]]*cd[[:space:]]+[^;&|()][^;&|()]*' | tail -1 | sed -E 's/^[[:space:]]*([;&|(])[[:space:]]*//' | sed -E 's/^cd[[:space:]]+//' | sed 's/[[:space:]]*$//')
if [ -n "$_last_cd" ]; then
    # チルダ展開のみ安全に処理 (シェル変数 $ を含む場合はスキップ)
    # shellcheck disable=SC2088  # command 文字列中の未展開リテラル '~' を意図的にマッチさせる case パターン
    case "$_last_cd" in
        *'$'*) ;;   # シェル変数あり → skip
        '~'|'~/'*) _last_cd_expanded="${HOME}${_last_cd#\~}" ;;
        *) _last_cd_expanded="$_last_cd" ;;
    esac
    if [ -n "${_last_cd_expanded:-}" ] && [ -d "$_last_cd_expanded" ]; then
        _wt=$(_resolve_root "$_last_cd_expanded")
        [ -n "$_wt" ] && _workdir_override="$_wt"
    fi
fi
unset _last_cd _last_cd_expanded _wt

workdir=${_workdir_override:-${CLAUDE_PROJECT_DIR:-$(printf '%s' "$input" | jq -r '.cwd // empty')}}
unset _workdir_override
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

# ローカル checkout に GitHub Actions workflow が 1 つも無ければ nudge 不要 → 黙って終了
# - 判定はローカルファイルのみ (hook は同期実行なのでネットワークコール禁止)
# - worktree / jj workspace 運用前提のため _resolve_root で toplevel を解決してからチェック
#   (git bare + jj workspace では git rev-parse --show-toplevel が失敗するので bump-semver
#   経由で解決する。解決不能時は従来通りチェックをスキップして nudge 側に倒す = 過剰抑制で
#   本物の CI watch を失うより誤 nudge の方が害が軽微、という既存方針を維持)
_repo_toplevel=$(_resolve_root "$workdir")
if [ -n "$_repo_toplevel" ]; then
    _wf_dir="$_repo_toplevel/.github/workflows"
    if [ ! -d "$_wf_dir" ] || ! find "$_wf_dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | grep -q .; then
        exit 0
    fi
fi
# _repo_toplevel / _wf_dir は下の paths matching check でも使うので unset は後段でまとめる

# push 後の remote SHA を解決する。明示 --branch を優先し、未指定なら origin/HEAD、
# remote branch が 1 本だけならその名前、最後に Git の既定 branch 設定を使う。
if [ -z "$push_branch" ]; then
    push_branch=$(git -C "$workdir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
fi
if [ -z "$push_branch" ]; then
    _remote_branches=$(git -C "$workdir" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin 2>/dev/null | grep -v '^HEAD$' || true)
    if [ "$(printf '%s\n' "$_remote_branches" | grep -c .)" -eq 1 ]; then
        push_branch=$_remote_branches
    fi
fi
if [ -z "$push_branch" ]; then
    push_branch=$(git -C "$workdir" config init.defaultBranch 2>/dev/null || true)
fi
[ -n "$push_branch" ] || push_branch=main
unset _remote_branches

head_sha=""
if [ -d "$workdir/.jj" ] && command -v jj >/dev/null 2>&1; then
    head_sha=$(jj -R "$workdir" log -r "${push_branch}@origin" --no-graph -T 'commit_id' 2>/dev/null | head -1 || true)
fi
if [ -z "$head_sha" ]; then
    head_sha=$(git -C "$workdir" rev-parse --verify "refs/remotes/origin/${push_branch}^{commit}" 2>/dev/null || true)
fi

# remote ref が取得できない環境だけ、最新の固定 local commit に fallback する。
if [ -z "$head_sha" ] && command -v bump-semver >/dev/null 2>&1; then
    head_sha=$( { cd "$workdir" 2>/dev/null && bump-semver vcs get commit-id 2>/dev/null; } || true)
fi
if [ -z "$head_sha" ] && [ -d "$workdir/.jj" ] && command -v jj >/dev/null 2>&1; then
    head_sha=$(jj -R "$workdir" log -r 'heads((::@-) & (~empty() | merges()))' --no-graph -T 'commit_id' 2>/dev/null | head -1 || true)
fi
if [ -z "$head_sha" ]; then
    head_sha=$(git -C "$workdir" rev-parse HEAD 2>/dev/null || true)
fi
if ! printf '%s' "$head_sha" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
    exit 0
fi
sha7=$(printf '%s' "$head_sha" | cut -c1-7)

# 今の commit で trigger される workflow が 1 つも無ければ黙る (kawaz 指示 2026-07-19)。
# - 判定は yq でローカル workflow の on.push.paths / paths-ignore を parse
# - 変更 files との glob 判定は python fnmatch (macOS 標準 /usr/bin/python3)
# - GitHub Actions の paths glob 記法との差 (**/*.md の階層深さ等) は fnmatch 近似で
#   最善努力、判別不能なら fail-open で nudge (既存方針: 過剰抑制で本物の CI watch を
#   失うより、誤 nudge の方が害が軽微)
# - yq / python 不在は fail-open (nudge)
# - repo_toplevel / wf_dir は上のワークフロー存在チェックで既に解決済み
if [ -n "${_repo_toplevel:-}" ] && [ -n "${_wf_dir:-}" ] && command -v yq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    _changed_files=$(git -C "$workdir" show --name-only --pretty=format: "$head_sha" 2>/dev/null | grep -v '^$' || true)
    if [ -n "$_changed_files" ]; then
        _any_triggered=0
        _any_undecidable=0
        for _wf in "$_wf_dir"/*.yml "$_wf_dir"/*.yaml; do
            [ -f "$_wf" ] || continue
            _on_push=$(yq -r '.["on"].push // "-"' "$_wf" 2>/dev/null || echo "-")
            if [ "$_on_push" = "-" ] || [ "$_on_push" = "null" ]; then
                continue  # この workflow は push trigger を持たない (tag / workflow_dispatch / schedule 等)
            fi
            _paths=$(yq -o=json '.["on"].push.paths // []' "$_wf" 2>/dev/null || echo "[]")
            _paths_ignore=$(yq -o=json '.["on"].push["paths-ignore"] // []' "$_wf" 2>/dev/null || echo "[]")
            if [ "$_paths" = "[]" ] && [ "$_paths_ignore" = "[]" ]; then
                _any_triggered=1
                break
            fi
            # python fnmatch で trigger 判定 (exit 0 = triggered, 1 = not, 2 = fail)
            python3 -c '
import fnmatch, json, sys
paths = json.loads(sys.argv[1])
paths_ignore = json.loads(sys.argv[2])
changed = [f for f in sys.argv[3].split("\n") if f]
def matches(path, patterns):
    for p in patterns:
        # GitHub Actions では ** は 0+ ディレクトリ。fnmatch は ** を認識しないので
        # ** を * に潰した pattern も併用して近似 (**/*.md → */*.md → *.md 相当)
        if fnmatch.fnmatchcase(path, p):
            return True
        p2 = p.replace("**/", "").replace("/**", "").replace("**", "*")
        if p2 != p and fnmatch.fnmatchcase(path, p2):
            return True
    return False
for f in changed:
    if paths_ignore and matches(f, paths_ignore):
        continue
    if not paths or matches(f, paths):
        sys.exit(0)  # triggered
sys.exit(1)  # not triggered by this workflow
' "$_paths" "$_paths_ignore" "$_changed_files"
            case $? in
                0) _any_triggered=1; break ;;
                1) : ;;  # not triggered by this workflow, continue
                *) _any_undecidable=1 ;;  # python 内エラー等
            esac
        done
        if [ "$_any_triggered" -eq 0 ] && [ "$_any_undecidable" -eq 0 ]; then
            # どの workflow も trigger されないと確定 → 黙る
            exit 0
        fi
    fi
    unset _changed_files _any_triggered _any_undecidable _on_push _paths _paths_ignore _wf
fi
unset _repo_toplevel _wf_dir

# additionalContext を JSON で返す
# Monitor 起動コマンドのパスは hook 内で解決した絶対パスを使う (literal
# ${CLAUDE_PLUGIN_ROOT} を埋めると Monitor 実行時に未定義で exit 127)
# SHA-pinned モードで起動 (= 指定 SHA の check が全 terminal + grace で自走 exit)。
# 同 repo に SHA 違いが既に走っていても並列起動 OK (案 B、自然 exit 任せ)。
context="[gh-monitor] Monitor リストに 'watch-workflow: ${repo}@${sha7}' が無ければ、Monitor ツールで command=\`bash ${PLUGIN_ROOT}/scripts/watch-workflow.sh --sha ${head_sha} ${repo}\`, description=\`watch-workflow: ${repo}@${sha7}\`, persistent=true を起動せよ。"

jq -n --arg ctx "$context" '{
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
    }
}'
