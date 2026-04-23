#!/usr/bin/env bash
# PR #N の状態を 60s 間隔でポーリングし、変化時に 1 行 stdout に出す。
# Claude Code の Monitor ツールで常駐させる前提。
#
# Usage:
#   pr-watch.sh <OWNER/REPO> <PR_NUMBER>
#
# 終了条件:
#   - PR が merged / closed → exit 0
#   - 外部から kill (Monitor の TaskStop / セッション終了)

set -u

repo=${1:-}
pr=${2:-}
interval=${PR_WATCH_INTERVAL:-60}

if [ -z "$repo" ] || [ -z "$pr" ]; then
    echo "[ERROR] usage: $0 <OWNER/REPO> <PR_NUMBER>" >&2
    exit 2
fi

prev_hash=""
last_check_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "[WATCH-START] $repo #$pr (interval=${interval}s)"

while true; do
    cur=$(gh pr view "$pr" --repo "$repo" \
        --json state,mergedAt,comments,reviews,statusCheckRollup 2>/dev/null || true)
    if [ -z "$cur" ]; then
        sleep "$interval"
        continue
    fi

    cur_hash=$(printf '%s' "$cur" | jq -c '{
        state, mergedAt,
        comments: [.comments[] | {createdAt, a:.author.login}],
        reviews:  [.reviews[]  | {state, a:.author.login, submittedAt}],
        checks:   [.statusCheckRollup[] | {name, status, conclusion}]
    }' 2>/dev/null | sha256sum | cut -d" " -f1)

    if [ "$cur_hash" != "$prev_hash" ] && [ -n "$prev_hash" ]; then
        # 新規コメント
        printf '%s' "$cur" | jq -r --arg t "$last_check_time" '
            .comments[] | select(.createdAt > $t) |
            "[COMMENT by \(.author.login)] " +
            (.body | .[0:200] | gsub("\n"; " "))
        ' 2>/dev/null

        # 新規レビュー
        printf '%s' "$cur" | jq -r --arg t "$last_check_time" '
            .reviews[] | select(.submittedAt > $t) |
            "[REVIEW \(.state) by \(.author.login)]"
        ' 2>/dev/null

        # CI 状態（1行サマリ）
        printf '%s' "$cur" | jq -r '
            "[CI] " + ([.statusCheckRollup[] | "\(.name)=\(.conclusion // .status)"] | join(", "))
        ' 2>/dev/null

        # マージ検出
        printf '%s' "$cur" | jq -r '
            select(.mergedAt != null) | "[MERGED] at \(.mergedAt) - watch ends"
        ' 2>/dev/null

        # close / merged で終了
        if printf '%s' "$cur" | jq -e '.mergedAt != null or .state == "CLOSED"' > /dev/null 2>&1; then
            exit 0
        fi
    fi

    prev_hash="$cur_hash"
    last_check_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep "$interval"
done
