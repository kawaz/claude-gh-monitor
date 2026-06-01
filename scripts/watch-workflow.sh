#!/usr/bin/env bash
# Repo の GitHub Actions workflow run を継続 poll し、状態変化を 1 行 stdout に出す。
# Claude Code の Monitor ツールで常駐させる前提。
#
# 2 モード (起動 mode 必須):
#   --sha <SHA>: SHA-pinned (推奨)。指定コミットの全 check が terminal + grace で自走 exit
#   --passive: Passive (オプトイン)。repo 全体を idle backoff で監視、--timeout で自走 exit
#
# Usage:
#   watch-workflow.sh --sha <SHA> [--grace=60s] [--timeout=24h] <OWNER/REPO>
#   watch-workflow.sh --passive [--max-interval=10m] [--timeout=24h] <OWNER/REPO>
#
# DR-0003 (= repo 単位 1 本) は Passive モードに限定。
# SHA-pinned は並列許可 (自然 exit 任せ、案 B)。
# DR-0004: workflow run は self filter 対象外。

set -u

#-----------------------------------------------------------------------------
# 引数パース
#-----------------------------------------------------------------------------

sha=""
passive=0
grace_input="60s"
timeout_input="24h"
max_interval_input="10m"
repo=""

usage() {
    cat <<'EOF' >&2
Usage:
  watch-workflow.sh --sha <SHA> [--grace=60s] [--timeout=24h] <OWNER/REPO>
  watch-workflow.sh --passive [--max-interval=10m] [--timeout=24h] <OWNER/REPO>

Mode (one required):
  --sha <SHA>              SHA-pinned: watch checks for the given commit, exit when all terminal + grace.
  --passive                Passive: repo-wide watch with idle backoff, exit at --timeout.

Common:
  --timeout=<duration>     Safety timeout (default 24h).

SHA-pinned only:
  --grace=<duration>       Quiet period after all-terminal before exit (default 60s).
  --exit-on-final          Accepted for compat (default in --sha mode).

Passive only:
  --max-interval=<duration>  Backoff upper bound (default 10m).

Durations: 30s / 5m / 1h / 1h30m
EOF
}

# 値必須オプションの値抜けチェック (codex review #2)
# 値が空 or `-` 始まりなら値抜け扱いで exit 2
_need_value() {
    local flag=$1 val=${2:-}
    if [ -z "$val" ] || [[ "$val" == -* ]]; then
        echo "[ERROR] $flag requires a value" >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sha)            _need_value "$1" "${2:-}"; sha=$2; shift 2 ;;
        --sha=*)          sha=${1#--sha=}; shift ;;
        --passive)        passive=1; shift ;;
        --grace)          _need_value "$1" "${2:-}"; grace_input=$2; shift 2 ;;
        --grace=*)        grace_input=${1#--grace=}; shift ;;
        --timeout)        _need_value "$1" "${2:-}"; timeout_input=$2; shift 2 ;;
        --timeout=*)      timeout_input=${1#--timeout=}; shift ;;
        --max-interval)   _need_value "$1" "${2:-}"; max_interval_input=$2; shift 2 ;;
        --max-interval=*) max_interval_input=${1#--max-interval=}; shift ;;
        --exit-on-final)  shift ;;
        -h|--help)        usage; exit 0 ;;
        --)               shift; break ;;
        -*)               echo "[ERROR] unknown flag: $1" >&2; usage; exit 2 ;;
        *) if [ -z "$repo" ]; then repo=$1; else echo "[ERROR] unexpected arg: $1" >&2; exit 2; fi; shift ;;
    esac
done

# 残った位置引数 (-- 以降) — 1 つだけ拾う
while [ $# -gt 0 ]; do
    if [ -z "$repo" ]; then repo=$1; shift
    else echo "[ERROR] unexpected arg: $1" >&2; exit 2; fi
done

# mode 必須化 (codex review #4)
if [ -z "$sha" ] && [ "$passive" -eq 0 ]; then
    echo "[ERROR] mode required: --sha <SHA> (recommended for own work) or --passive (repo-wide watch)." >&2
    exit 2
fi
if [ -n "$sha" ] && [ "$passive" -eq 1 ]; then
    echo "[ERROR] --sha and --passive are mutually exclusive" >&2
    exit 2
fi

if [ -z "$repo" ]; then
    echo "[ERROR] OWNER/REPO required" >&2
    usage
    exit 2
fi

if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "[ERROR] invalid OWNER/REPO: $repo" >&2
    exit 2
fi

# SHA 形式チェック (7 文字以上の hex)
if [ -n "$sha" ]; then
    if ! printf '%s' "$sha" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
        echo "[ERROR] invalid --sha (need 7..40 hex chars): $sha" >&2
        exit 2
    fi
fi

#-----------------------------------------------------------------------------
# duration パーサ (30s / 5m / 1h / 1h30m 等)
#-----------------------------------------------------------------------------

parse_duration() {
    local input=$1
    local total=0
    local n u
    while [[ $input =~ ^([0-9]+)([smh])(.*)$ ]]; do
        n=${BASH_REMATCH[1]}
        u=${BASH_REMATCH[2]}
        case $u in
            s) total=$((total + n)) ;;
            m) total=$((total + n * 60)) ;;
            h) total=$((total + n * 3600)) ;;
        esac
        input=${BASH_REMATCH[3]}
    done
    if [ -n "$input" ]; then return 1; fi
    if [ "$total" -le 0 ]; then return 1; fi
    printf '%s' "$total"
}

if ! grace_sec=$(parse_duration "$grace_input"); then
    echo "[ERROR] invalid --grace: $grace_input" >&2; exit 2
fi
if ! timeout_sec=$(parse_duration "$timeout_input"); then
    echo "[ERROR] invalid --timeout: $timeout_input" >&2; exit 2
fi
if ! max_interval_sec=$(parse_duration "$max_interval_input"); then
    echo "[ERROR] invalid --max-interval: $max_interval_input" >&2; exit 2
fi

#-----------------------------------------------------------------------------
# 起動時パラメータ
#-----------------------------------------------------------------------------

start_epoch=$(date +%s)
# WATCH_WORKFLOW_INTERVAL は test 用の override (秒)。指定が無ければ 30s。
initial_interval=${WATCH_WORKFLOW_INTERVAL:-30}
fail_warn=5

# mode に応じた起動 ack + cutoff (dispatch は $sha の有無で行うので mode 変数は持たない)
if [ -n "$sha" ]; then
    sha7=$(printf '%s' "$sha" | cut -c1-7)
    echo "[INFO] watch-workflow start: $repo (mode=sha-pinned sha=$sha7 grace=${grace_input} timeout=${timeout_input})"
    # SHA-pinned は cutoff 不要 (filter で絞られる)
    cutoff_epoch=0
else
    lookback_min=5
    cutoff_epoch=$(( start_epoch - lookback_min * 60 ))
    echo "[INFO] watch-workflow start: $repo (mode=passive max-interval=${max_interval_input} timeout=${timeout_input})"
fi

#-----------------------------------------------------------------------------
# 状態
#-----------------------------------------------------------------------------

declare -A known_state
initialized=0
fail_count=0
warned_fail=0

# SHA-pinned 専用:
# matching_state: SHA filter にヒットした run の rid -> last seen state を保持。
# GC 対象外 (= run が per_page=100 から押し出されても last state を残す)。
# これにより「known non-terminal が現在ページから消えただけで exit」を防ぐ (codex review #1)
declare -A matching_state
observed_any_matching=0
last_event_epoch=$start_epoch
matching_warned=0
matching_warn_threshold=300   # 5 min

# Passive 専用 (interval は両者で使うが起点が違う)
interval=$initial_interval

#-----------------------------------------------------------------------------
# 出力ヘルパー
#-----------------------------------------------------------------------------

# 値にスペース・引用符・バックスラッシュ・改行を含む場合だけ double quote
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
    local sha7_local
    sha7_local=$(printf '%s' "$4" | cut -c1-7)
    printf '[run:change] workflow:%s id:%s status:%s commit:%s branch:%s user:%s event:%s\n' \
        "$(quote_value "$1")" "$2" "$3" "$sha7_local" \
        "$(quote_value "$5")" "$(quote_value "$6")" "$7"
}

#-----------------------------------------------------------------------------
# メインループ
#-----------------------------------------------------------------------------

while true; do
    now=$(date +%s)

    # timeout (両モード共通)
    if [ $((now - start_epoch)) -ge "$timeout_sec" ]; then
        echo "[INFO] timeout reached (${timeout_input}), exiting"
        exit 0
    fi

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

    # この iter の集計
    transitions_this_iter=0

    while IFS=$'\t' read -r rid rstate rname rsha rbranch ractor revent rupd_epoch; do
        [ -z "$rid" ] && continue

        # SHA-pinned: filter + last seen state を matching_state に記録
        if [ -n "$sha" ]; then
            case $rsha in
                ${sha}*) ;;
                *) continue ;;
            esac
            matching_state[$rid]=$rstate
            observed_any_matching=1
        fi

        if [ "$initialized" -eq 0 ]; then
            if [ -z "${known_state[$rid]:-}" ]; then
                known_state[$rid]=$rstate
                # SHA-pinned: baseline で全 matching を emit (= 状態把握)
                # Passive: cutoff より新しい完了 run のみ emit (fast CI 救済、DR-0003)
                if [ -n "$sha" ]; then
                    emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
                    transitions_this_iter=$((transitions_this_iter + 1))
                elif [ "$rupd_epoch" -ge "$cutoff_epoch" ] \
                    && [ "$rstate" != "queued" ] \
                    && [ "$rstate" != "in_progress" ]; then
                    emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
                    transitions_this_iter=$((transitions_this_iter + 1))
                fi
            fi
        else
            prev=${known_state[$rid]:-}
            if [ -z "$prev" ]; then
                known_state[$rid]=$rstate
                emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
                transitions_this_iter=$((transitions_this_iter + 1))
            elif [ "$prev" != "$rstate" ]; then
                known_state[$rid]=$rstate
                emit_run "$rname" "$rid" "$rstate" "$rsha" "$rbranch" "$ractor" "$revent"
                transitions_this_iter=$((transitions_this_iter + 1))
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

    # GC: per_page=100 から押し出された古い run_id を known_state から落とす
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

    # event 発生があれば last_event_epoch を更新
    if [ "$transitions_this_iter" -gt 0 ]; then
        last_event_epoch=$now
    fi

    if [ -n "$sha" ]; then
        # SHA-pinned: 一致 run が無いまま閾値超え → WARN (1 回だけ)
        if [ "$observed_any_matching" -eq 0 ] \
            && [ "$matching_warned" -eq 0 ] \
            && [ $((now - start_epoch)) -ge "$matching_warn_threshold" ]; then
            printf '[WARN] no matching run for SHA %s after %ds. Check that the SHA is correct.\n' "$sha7" "$matching_warn_threshold"
            matching_warned=1
        fi

        # exit 条件 (codex review #1 反映、High-1 修正版):
        #   observed_any_matching AND
        #   matching_state の全 entry が terminal AND
        #   (now - last_event_epoch) >= grace
        #
        # 「matching_count_this_iter == 0」を成功扱いしない (= 過去 known な non-terminal が
        # 現在 page から見えなくなっただけで exit してしまうのを防ぐ)。
        # 一度 observed したら matching_state が空になることはない。
        if [ "$observed_any_matching" -eq 1 ]; then
            all_known_matching_terminal=1
            for mid in "${!matching_state[@]}"; do
                case ${matching_state[$mid]} in
                    queued|in_progress|waiting|requested|pending)
                        all_known_matching_terminal=0
                        break
                        ;;
                esac
            done
            if [ "$all_known_matching_terminal" -eq 1 ]; then
                if [ $((now - last_event_epoch)) -ge "$grace_sec" ]; then
                    echo "[INFO] all checks reached terminal state, grace window elapsed, exiting"
                    exit 0
                fi
            fi
        fi

        # SHA-pinned は固定 interval
        sleep "$initial_interval"
    else
        # Passive: idle backoff
        if [ "$transitions_this_iter" -gt 0 ]; then
            interval=$initial_interval
        else
            interval=$(( interval * 3 / 2 ))
            if [ "$interval" -gt "$max_interval_sec" ]; then
                interval=$max_interval_sec
            fi
        fi
        sleep "$interval"
    fi
done
