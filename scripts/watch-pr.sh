#!/usr/bin/env bash
# PR #N の状態をポーリングし、変化時に 1 行 stdout に出す。
# Claude Code の Monitor ツールで常駐させる前提。
#
# Usage:
#   watch-pr.sh <OWNER/REPO> <PR_NUMBER>
#
# 終了条件:
#   - PR が merged / closed → exit 0
#   - 外部から kill (Monitor の TaskStop / セッション終了)

set -u

repo=${1:-}
pr=${2:-}
interval=60       # ポーリング間隔(秒)
fail_warn=5       # 連続失敗通知閾値

if [ -z "$repo" ] || [ -z "$pr" ]; then
    echo "[ERROR] usage: $0 <OWNER/REPO> <PR_NUMBER>" >&2
    exit 2
fi

# OWNER/REPO の形式検証（GitHub の owner/repo は英数 / "_" / "-" / "." のみ）
if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "[ERROR] invalid OWNER/REPO: $repo" >&2
    exit 2
fi

# PR_NUMBER は正の整数
if ! printf '%s' "$pr" | grep -Eq '^[1-9][0-9]*$'; then
    echo "[ERROR] invalid PR_NUMBER: $pr" >&2
    exit 2
fi

max_comment_at=""           # 既出コメントの最大 createdAt
max_review_at=""            # 既出レビューの最大 submittedAt
declare -A ci_state         # check 名 -> 状態語彙 (前回値)
initialized=0               # 初回ループフラグ（初回は emit しない）
fail_count=0
warned_fail=0

# 値にスペース等を含む場合だけ double quote、それ以外は素のまま。
# 受信側 (Claude) が key=value を空白区切りで素朴に拾える形を保つ。
quote_value() {
    case "$1" in
        *[[:space:]\"]*) printf '"%s"' "${1//\"/\\\"}" ;;
        '') printf '""' ;;
        *) printf '%s' "$1" ;;
    esac
}

# skill 名 / repo / PR# は Monitor description (= 通知 summary) で識別される前提で
# emit からは省略。description 命名規約 (`watch-pr: <owner/repo>#<N>`) は SKILL.md で
# ロックしている。

echo "[INFO] watch-pr start: $repo#$pr (interval=${interval}s)"

while true; do
    cur=$(gh pr view "$pr" --repo "$repo" \
        --json state,mergedAt,mergedBy,mergeCommit,comments,reviews,statusCheckRollup 2>/dev/null || true)
    if [ -z "$cur" ]; then
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$fail_warn" ] && [ "$warned_fail" -eq 0 ]; then
            printf '[WARN] gh pr view が %d 回連続失敗\n' "$fail_count"
            warned_fail=1
        fi
        sleep "$interval"
        continue
    fi
    if [ "$warned_fail" -eq 1 ]; then
        printf '[INFO] gh pr view が復旧 (%d 回失敗のあと)\n' "$fail_count"
    fi
    fail_count=0
    warned_fail=0

    cur_max_comment_at=$(printf '%s' "$cur" | jq -r '[.comments[].createdAt] | max // ""' 2>/dev/null)
    cur_max_review_at=$(printf '%s' "$cur"  | jq -r '[.reviews[].submittedAt | select(. != null)] | max // ""' 2>/dev/null)

    # 新規コメント emit（2 周目以降のみ）
    if [ "$initialized" -eq 1 ] && [ -n "$cur_max_comment_at" ] && [ "$cur_max_comment_at" \> "$max_comment_at" ]; then
        while IFS=$'\t' read -r author url body; do
            [ -z "$author" ] && continue
            printf '[comment:add] user:%s url:%s body:%s\n' \
                "$(quote_value "$author")" \
                "$url" \
                "$(quote_value "$body")"
        done < <(printf '%s' "$cur" | jq -r --arg t "$max_comment_at" '
            .comments[] | select(.createdAt > $t) |
            [.author.login, (.url // ""), (.body | .[0:200] | gsub("\n"; " "))] | @tsv
        ' 2>/dev/null)
    fi

    # 新規レビュー emit（2 周目以降のみ）
    if [ "$initialized" -eq 1 ] && [ -n "$cur_max_review_at" ] && [ "$cur_max_review_at" \> "$max_review_at" ]; then
        while IFS=$'\t' read -r author state; do
            [ -z "$author" ] && continue
            printf '[review:submit] user:%s state:%s\n' \
                "$(quote_value "$author")" \
                "$state"
        done < <(printf '%s' "$cur" | jq -r --arg t "$max_review_at" '
            .reviews[] | select(.submittedAt != null) | select(.submittedAt > $t) |
            [.author.login, .state] | @tsv
        ' 2>/dev/null)
    fi

    # CI: check 単位で状態管理。変化のあった check のみ emit
    # CheckRun (name/status/conclusion/detailsUrl) と StatusContext (context/state/targetUrl) の混在を吸収
    while IFS=$'\t' read -r name state url; do
        [ -z "$name" ] && continue
        prev=${ci_state[$name]:-}
        ci_state[$name]=$state
        # initialized=0 (baseline) は emit しない
        if [ "$initialized" -eq 1 ] && [ "$prev" != "$state" ]; then
            if [ -n "$url" ]; then
                printf '[ci:change] check:%s status:%s url:%s\n' \
                    "$(quote_value "$name")" \
                    "$state" \
                    "$url"
            else
                printf '[ci:change] check:%s status:%s\n' \
                    "$(quote_value "$name")" \
                    "$state"
            fi
        fi
    done < <(printf '%s' "$cur" | jq -r '
        .statusCheckRollup[] |
        [
            (.name // .context // "unknown"),
            (
                if .status == "COMPLETED" or .status == "completed" then (.conclusion // "unknown")
                elif .conclusion then .conclusion
                elif .state then .state
                else (.status // "unknown")
                end
            ),
            (.detailsUrl // .targetUrl // "")
        ] | @tsv
    ' 2>/dev/null)

    # マージ / close 検出 → 最後のイベントを出して exit
    if printf '%s' "$cur" | jq -e '.mergedAt != null' > /dev/null 2>&1; then
        while IFS=$'\t' read -r merged_at merged_by merge_commit; do
            commit7=$(printf '%s' "$merge_commit" | cut -c1-7)
            if [ -n "$merged_by" ] && [ -n "$commit7" ]; then
                printf '[pr:merge] user:%s commit:%s at:%s\n' "$merged_by" "$commit7" "$merged_at"
            elif [ -n "$merged_by" ]; then
                printf '[pr:merge] user:%s at:%s\n' "$merged_by" "$merged_at"
            else
                printf '[pr:merge] at:%s\n' "$merged_at"
            fi
        done < <(printf '%s' "$cur" | jq -r '[.mergedAt, (.mergedBy.login // ""), (.mergeCommit.oid // "")] | @tsv')
        exit 0
    fi
    if printf '%s' "$cur" | jq -e '.state == "CLOSED"' > /dev/null 2>&1; then
        printf '[pr:close]\n'
        exit 0
    fi

    [ -n "$cur_max_comment_at" ] && max_comment_at="$cur_max_comment_at"
    [ -n "$cur_max_review_at" ]  && max_review_at="$cur_max_review_at"
    initialized=1
    sleep "$interval"
done
