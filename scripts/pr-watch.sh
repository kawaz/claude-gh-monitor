#!/usr/bin/env bash
# PR #N の状態をポーリングし、変化時に 1 行 stdout に出す。
# Claude Code の Monitor ツールで常駐させる前提。
#
# Usage:
#   pr-watch.sh <OWNER/REPO> <PR_NUMBER>
#
# Env:
#   PR_WATCH_INTERVAL   ポーリング間隔(秒)  default=60
#   PR_WATCH_FAIL_WARN  連続失敗通知閾値    default=5
#
# 終了条件:
#   - PR が merged / closed → exit 0
#   - 外部から kill (Monitor の TaskStop / セッション終了)

set -u

repo=${1:-}
pr=${2:-}
interval=${PR_WATCH_INTERVAL:-60}
fail_warn=${PR_WATCH_FAIL_WARN:-5}

if [ -z "$repo" ] || [ -z "$pr" ]; then
    echo "[ERROR] usage: $0 <OWNER/REPO> <PR_NUMBER>" >&2
    exit 2
fi

pr_hash=""          # state / comments / reviews 用
ci_hash=""          # statusCheckRollup 用
last_check_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fail_count=0
warned_fail=0

echo "[WATCH-START] $repo #$pr (interval=${interval}s)"

while true; do
    cur=$(gh pr view "$pr" --repo "$repo" \
        --json state,mergedAt,comments,reviews,statusCheckRollup 2>/dev/null || true)
    if [ -z "$cur" ]; then
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$fail_warn" ] && [ "$warned_fail" -eq 0 ]; then
            echo "[WARN] gh pr view が $fail_count 回連続失敗 (repo=$repo pr=$pr). gh auth / network を確認してください"
            warned_fail=1
        fi
        sleep "$interval"
        continue
    fi
    if [ "$warned_fail" -eq 1 ]; then
        echo "[INFO] gh pr view が復旧 (過去 $fail_count 回の失敗後)"
    fi
    fail_count=0
    warned_fail=0

    # PR 本体側（state/comments/reviews）のハッシュ
    pr_cur_hash=$(printf '%s' "$cur" | jq -c '{
        state, mergedAt,
        comments: [.comments[] | {createdAt, a:.author.login}],
        reviews:  [.reviews[]  | {state, a:.author.login, submittedAt}]
    }' 2>/dev/null | sha256sum | cut -d" " -f1)

    # CI 側のハッシュ（独立管理）
    ci_cur_hash=$(printf '%s' "$cur" | jq -c '[.statusCheckRollup[] | {name, status, conclusion}]' \
        2>/dev/null | sha256sum | cut -d" " -f1)

    # 新規コメント / 新規レビューの emit（初回は pr_hash="" なので抑止）
    if [ "$pr_cur_hash" != "$pr_hash" ] && [ -n "$pr_hash" ]; then
        printf '%s' "$cur" | jq -r --arg t "$last_check_time" '
            .comments[] | select(.createdAt > $t) |
            "[COMMENT by \(.author.login)] " +
            (.body | .[0:200] | gsub("\n"; " "))
        ' 2>/dev/null

        printf '%s' "$cur" | jq -r --arg t "$last_check_time" '
            .reviews[] | select(.submittedAt != null) | select(.submittedAt > $t) |
            "[REVIEW \(.state) by \(.author.login)]"
        ' 2>/dev/null
    fi

    # CI 変化時だけ [CI] を emit（初回は ci_hash="" なので抑止）
    if [ "$ci_cur_hash" != "$ci_hash" ] && [ -n "$ci_hash" ]; then
        printf '%s' "$cur" | jq -r '
            "[CI] " + ([.statusCheckRollup[] | "\(.name)=\(.conclusion // .status)"] | join(", "))
        ' 2>/dev/null
    fi

    # マージ / close 検出 → 最後の [MERGED] を出して exit
    if printf '%s' "$cur" | jq -e '.mergedAt != null' > /dev/null 2>&1; then
        printf '%s' "$cur" | jq -r '"[MERGED] at \(.mergedAt) - watch ends"'
        exit 0
    fi
    if printf '%s' "$cur" | jq -e '.state == "CLOSED"' > /dev/null 2>&1; then
        echo "[CLOSED] $repo#$pr - watch ends"
        exit 0
    fi

    pr_hash="$pr_cur_hash"
    ci_hash="$ci_cur_hash"
    last_check_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sleep "$interval"
done
