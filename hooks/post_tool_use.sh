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
#   - push 元リポのローカル checkout に .github/workflows/*.yml|*.yaml が 1 つも無い

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
        root=$(cd "$dir" 2>/dev/null && bump-semver vcs get root 2>/dev/null || true)
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
unset _repo_toplevel _wf_dir

# push 直後の head SHA を解決 (SHA-pinned 起動用)
# - 実際に push されたのは「最新の固定コミット」(jj では working-copy @ でなく @- 側の
#   非空/マージコミット、git では HEAD)。jj の @ は空のことが多く、これを pin すると
#   CI run が存在せず no-match-timeout まで無駄常駐する (jj 主体の環境では push のたびに発生)。
# - bump-semver があれば `vcs get commit-id` を使う。bump-semver DR-0040 で default が
#   backend-agnostic な「最新の固定コミット」(jj では heads((::@-) & (~empty() | merges()))
#   相当 = @ を除いた最新の非空/マージコミット、git では HEAD) に修正済み。
# - bump-semver 不在で jj リポなら同等の revset に直接 fallback。空マージも merges() で救済。
# - jj 不在 / 非 jj リポは `git rev-parse HEAD` で fallback。
# - hex 7..40 文字の SHA でなければ起動指示を出さない (= 不正な値での起動を避ける)
head_sha=""
if command -v bump-semver >/dev/null 2>&1; then
    head_sha=$(cd "$workdir" 2>/dev/null && bump-semver vcs get commit-id 2>/dev/null || true)
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
