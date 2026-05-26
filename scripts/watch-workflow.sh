#!/usr/bin/env bash
# Repo の GitHub Actions workflow run を継続 poll し、状態変化を 1 行 stdout に出す。
# Claude Code の Monitor ツールで常駐させる前提 (repo 単位 1 本)。
#
# Usage:
#   watch-workflow.sh <OWNER/REPO>
#
# 終了条件:
#   - 外部 kill (Monitor の TaskStop / セッション終了) のみ
#   - repo 単位の常駐なので自分で exit はしない (transient な失敗でも継続)

set -u

repo=${1:-}
interval=30          # poll 間隔(秒)
lookback_min=5       # 起動時刻からの lookback (DR-0003)
fail_warn=5          # 連続失敗通知閾値

if [ -z "$repo" ]; then
    echo "[ERROR] usage: $0 <OWNER/REPO>" >&2
    exit 2
fi

if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "[ERROR] invalid OWNER/REPO: $repo" >&2
    exit 2
fi

cutoff_epoch=$(( $(date +%s) - lookback_min * 60 ))

# run_id -> 状態語彙 (status / conclusion フラット化)
declare -A known_state
initialized=0
fail_count=0
warned_fail=0

echo "[INFO] watch-workflow start: $repo (interval=${interval}s, lookback=${lookback_min}m)"

# 値にスペース・引用符・バックスラッシュ・改行を含む場合だけ double quote、
# それ以外は素のまま。受信側 (Claude) が key:value を空白区切りで素朴に拾える形を保つ。
# backslash は先に escape する (順序重要: " より前)。
quote_value() {
    case "$1" in
        *[[:space:]\"\\]*|*$'\n'*)
            local v="${1//\\/\\\\}"
            v="${v//\"/\\\"}"
            v="${v//$'\n'/\\n}"
            printf '"%s"' "$v"
            ;;
        '') printf '""' ;;
        *) printf '%s' "$1" ;;
    esac
}

emit_run() {
    # $1=name $2=id $3=state $4=sha $5=branch $6=actor $7=event
    local sha7
    sha7=$(printf '%s' "$4" | cut -c1-7)
    # skill 名と repo は Monitor description (= 通知 summary) で識別される前提で省略
    printf '[run:change] workflow:%s id:%s status:%s commit:%s branch:%s user:%s event:%s\n' \
        "$(quote_value "$1")" "$2" "$3" "$sha7" \
        "$(quote_value "$5")" "$(quote_value "$6")" "$7"
}

while true; do
    json=$(gh api "/repos/$repo/actions/runs?per_page=100" 2>/dev/null || true)
    if [ -z "$json" ] || ! printf '%s' "$json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$fail_warn" ] && [ "$warned_fail" -eq 0 ]; then
            printf '[WARN] gh api が %d 回連続失敗\n' "$fail_count"
            warned_fail=1
        fi
        sleep "$interval"
        continue
    fi
    if [ "$warned_fail" -eq 1 ]; then
        printf '[INFO] gh api が復旧 (%d 回失敗のあと)\n' "$fail_count"
    fi
    fail_count=0
    warned_fail=0

    # 各 run を tsv で 1 行ずつ取り出す
    # フィールド: id, state, name, sha, branch, actor, event, updated_at_epoch
    while IFS=$'\t' read -r rid rstate rname rsha rbranch ractor revent rupd_epoch; do
        [ -z "$rid" ] && continue

        if [ "$initialized" -eq 0 ]; then
            # baseline 構築
            if [ -z "${known_state[$rid]:-}" ]; then
                known_state[$rid]=$rstate
                # completed かつ cutoff より新しい run は即 emit (fast CI 救済)
                if [ "$rupd_epoch" -ge "$cutoff_epoch" ] \
                    && [ "$rstate" != "queued" ] \
                    && [ "$rstate" != "in_progress" ]; then
                    emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
                fi
            fi
        else
            prev=${known_state[$rid]:-}
            if [ -z "$prev" ]; then
                # 新規 run
                known_state[$rid]=$rstate
                emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
            elif [ "$prev" != "$rstate" ]; then
                known_state[$rid]=$rstate
                emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
            fi
        fi
    done < <(printf '%s' "$json" | jq -r '
        .workflow_runs[] |
        [
            (.id | tostring),
            (if .status == "completed" then (.conclusion // "unknown") else .status end),
            (.name // .display_title // ""),
            (.head_sha // ""),
            (.head_branch // ""),
            (.actor.login // .triggering_actor.login // ""),
            (.event // ""),
            ((.updated_at // .created_at) | fromdateiso8601)
        ] | @tsv
    ' 2>/dev/null)

    # GC: 現 poll で見えなかった run_id (= per_page=100 から押し出された古い run) は
    # API から再取得不能なので known_state から落として良い。
    # poll の TSV に登場した id 集合を作って、known_state から不在分を unset する。
    if [ "$initialized" -eq 1 ]; then
        declare -A seen_ids=()
        while IFS=$'\t' read -r seen_rid _; do
            [ -n "$seen_rid" ] && seen_ids[$seen_rid]=1
        done < <(printf '%s' "$json" | jq -r '.workflow_runs[] | [.id | tostring, ""] | @tsv' 2>/dev/null)
        for k in "${!known_state[@]}"; do
            [ -z "${seen_ids[$k]:-}" ] && unset 'known_state[$k]'
        done
        unset seen_ids
    fi

    initialized=1
    sleep "$interval"
done
