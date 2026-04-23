#!/usr/bin/env bash
# PR #N の状態をポーリングし、変化時に 1 行 stdout に出す。
# Claude Code の Monitor ツールで常駐させる前提。
#
# Usage:
#   pr-monitor.sh <OWNER/REPO> <PR_NUMBER>
#
# Env:
#   PR_MONITOR_INTERVAL   ポーリング間隔(秒)  default=60
#   PR_MONITOR_FAIL_WARN  連続失敗通知閾値    default=5
#
# 終了条件:
#   - PR が merged / closed → exit 0
#   - 外部から kill (Monitor の TaskStop / セッション終了)

set -u

repo=${1:-}
pr=${2:-}
interval=${PR_MONITOR_INTERVAL:-60}
fail_warn=${PR_MONITOR_FAIL_WARN:-5}

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

# interval / fail_warn が正の整数でなければ既定値にフォールバック
if ! printf '%s' "$interval" | grep -Eq '^[1-9][0-9]*$'; then
    echo "[WARN] invalid PR_MONITOR_INTERVAL='$interval' → fallback to 60"
    interval=60
fi
if ! printf '%s' "$fail_warn" | grep -Eq '^[1-9][0-9]*$'; then
    echo "[WARN] invalid PR_MONITOR_FAIL_WARN='$fail_warn' → fallback to 5"
    fail_warn=5
fi

ci_hash=""                  # statusCheckRollup 用ハッシュ
max_comment_at=""           # 既出コメントの最大 createdAt
max_review_at=""            # 既出レビューの最大 submittedAt
initialized=0               # 初回ループフラグ（初回は emit しない）
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

    # 今回取得データの最大 createdAt / submittedAt
    cur_max_comment_at=$(printf '%s' "$cur" | jq -r '[.comments[].createdAt] | max // ""' 2>/dev/null)
    cur_max_review_at=$(printf '%s' "$cur"  | jq -r '[.reviews[].submittedAt | select(. != null)] | max // ""' 2>/dev/null)

    # CI 側のハッシュ（独立管理）
    ci_cur_hash=$(printf '%s' "$cur" | jq -c '[.statusCheckRollup[] | {name, status, conclusion}]' \
        2>/dev/null | sha256sum | cut -d" " -f1)

    # 新規コメント emit（2 周目以降のみ）
    if [ "$initialized" -eq 1 ] && [ -n "$cur_max_comment_at" ] && [ "$cur_max_comment_at" \> "$max_comment_at" ]; then
        printf '%s' "$cur" | jq -r --arg t "$max_comment_at" '
            .comments[] | select(.createdAt > $t) |
            "[COMMENT by \(.author.login)] " +
            (.body | .[0:200] | gsub("\n"; " "))
        ' 2>/dev/null
    fi

    # 新規レビュー emit（2 周目以降のみ）
    if [ "$initialized" -eq 1 ] && [ -n "$cur_max_review_at" ] && [ "$cur_max_review_at" \> "$max_review_at" ]; then
        printf '%s' "$cur" | jq -r --arg t "$max_review_at" '
            .reviews[] | select(.submittedAt != null) | select(.submittedAt > $t) |
            "[REVIEW \(.state) by \(.author.login)]"
        ' 2>/dev/null
    fi

    # CI 変化時だけ [CI] emit（初回は ci_hash="" で抑止）
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

    ci_hash="$ci_cur_hash"
    # 最大値は「増加したら更新」。同値/空のままで維持されるケースもある
    [ -n "$cur_max_comment_at" ] && max_comment_at="$cur_max_comment_at"
    [ -n "$cur_max_review_at" ]  && max_review_at="$cur_max_review_at"
    initialized=1
    sleep "$interval"
done
