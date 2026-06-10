#!/usr/bin/env bash
# gh-monitor の self filter (DR-0004) 周りの smoke test。
# bats を導入していないので minimal な POSIX 寄り bash で書く。
# 各 test は gh コマンドを stub で差し替え、watch-pr.sh / watch-workflow.sh を
# 短い interval で数ループ動かし、出力に対して grep ベースの assert を行う。

set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0
failed_tests=()

# stub gh コマンドのテンプレ。$GH_STUB_DIR 配下の JSON ファイルを順番に返す。
write_stub() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
GH_STUB_DIR="${GH_STUB_DIR:?stub gh: GH_STUB_DIR not set}"

if [ "$1" = "api" ] && [ "$2" = "user" ]; then
    if [ -f "$GH_STUB_DIR/api-user.txt" ]; then
        cat "$GH_STUB_DIR/api-user.txt"
        exit 0
    fi
    exit 1
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    counter_file="$GH_STUB_DIR/counter-pr-view"
    n=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$counter_file"
    f="$GH_STUB_DIR/pr-view-${n}.json"
    if [ ! -f "$f" ]; then
        last=$(find "$GH_STUB_DIR" -maxdepth 1 -name 'pr-view-*.json' 2>/dev/null | sort -V | tail -1)
        [ -n "$last" ] && f="$last"
    fi
    cat "$f"
    exit 0
fi

if [ "$1" = "api" ] && [[ "$2" == /repos/*/actions/workflows* ]]; then
    # workflow 一覧 (total_count): workflows-response.json があれば返す、なければデフォルト (workflows あり)
    if [ -f "$GH_STUB_DIR/workflows-response.json" ]; then
        cat "$GH_STUB_DIR/workflows-response.json"
    else
        printf '{"total_count":1,"workflows":[]}'
    fi
    exit 0
fi

if [ "$1" = "api" ] && [[ "$2" == /repos/* ]]; then
    counter_file="$GH_STUB_DIR/counter-runs"
    n=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$counter_file"
    f="$GH_STUB_DIR/runs-${n}.json"
    if [ ! -f "$f" ]; then
        last=$(find "$GH_STUB_DIR" -maxdepth 1 -name 'runs-*.json' 2>/dev/null | sort -V | tail -1)
        [ -n "$last" ] && f="$last"
    fi
    cat "$f"
    exit 0
fi

echo "[stub gh] unhandled: $*" >&2
exit 1
STUB
    chmod +x "$bin_dir/gh"
}

# 1 つの test を実行する。expected/unexpected substring の grep で判定。
# $1=name $2=output $3=expected (改行区切り; 全部必要) $4=unexpected (改行区切り; 1 つでも出たら fail)
assert_output() {
    local name="$1" out="$2" expected="$3" unexpected="$4"
    local ok=1 reason=""
    while IFS= read -r needle; do
        [ -z "$needle" ] && continue
        if ! grep -F -- "$needle" <<<"$out" > /dev/null; then
            ok=0
            reason="${reason}\n  expected substring missing: $needle"
        fi
    done <<<"$expected"
    while IFS= read -r needle; do
        [ -z "$needle" ] && continue
        if grep -F -- "$needle" <<<"$out" > /dev/null; then
            ok=0
            reason="${reason}\n  unexpected substring present: $needle"
        fi
    done <<<"$unexpected"
    if [ "$ok" -eq 1 ]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s%b\n' "$name" "$reason"
        printf '  --- output ---\n%s\n  --------------\n' "$out"
        fail=$((fail + 1))
        failed_tests+=("$name")
    fi
}

# 共通 PR fixture: ベースライン (1 周目) と新規イベント (2 周目以降)
fixture_pr_baseline() {
    cat <<'JSON'
{"state":"OPEN","mergedAt":null,"mergedBy":null,"mergeCommit":null,
 "comments":[
   {"createdAt":"2026-05-26T00:00:00Z","author":{"login":"alice"},"url":"https://x/1","body":"baseline comment"}
 ],
 "reviews":[],
 "statusCheckRollup":[]}
JSON
}

fixture_pr_after_mixed_comments() {
    cat <<'JSON'
{"state":"OPEN","mergedAt":null,"mergedBy":null,"mergeCommit":null,
 "comments":[
   {"createdAt":"2026-05-26T00:00:00Z","author":{"login":"alice"},"url":"https://x/1","body":"baseline comment"},
   {"createdAt":"2026-05-26T00:01:00Z","author":{"login":"self-bot"},"url":"https://x/2","body":"my own comment"},
   {"createdAt":"2026-05-26T00:02:00Z","author":{"login":"bob"},"url":"https://x/3","body":"others comment"}
 ],
 "reviews":[
   {"submittedAt":"2026-05-26T00:03:00Z","author":{"login":"self-bot"},"state":"APPROVED"},
   {"submittedAt":"2026-05-26T00:04:00Z","author":{"login":"carol"},"state":"CHANGES_REQUESTED"}
 ],
 "statusCheckRollup":[]}
JSON
}

# ============================================================
# Test 1: watch-pr.sh は self-bot の comment / review を suppress、他者は emit
# ============================================================
test_watch_pr_self_filter_on() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    echo 'self-bot' > "$stub_dir/api-user.txt"
    fixture_pr_baseline           > "$stub_dir/pr-view-1.json"
    fixture_pr_after_mixed_comments > "$stub_dir/pr-view-2.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_PR_INTERVAL=1 \
        timeout 3 bash "$repo_root/scripts/watch-pr.sh" kawaz/test 1 2>&1 || true)

    assert_output "watch-pr: self filter ON suppresses self / keeps others" "$out" \
        "$(printf 'self filter: login=self-bot\nuser:bob\nuser:carol\n')" \
        "$(printf 'user:self-bot\n')"
}

# ============================================================
# Test 2: GH_MONITOR_INCLUDE_SELF=1 で self も emit される
# ============================================================
test_watch_pr_self_filter_off_by_env() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    echo 'self-bot' > "$stub_dir/api-user.txt"
    fixture_pr_baseline           > "$stub_dir/pr-view-1.json"
    fixture_pr_after_mixed_comments > "$stub_dir/pr-view-2.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_PR_INTERVAL=1 \
        GH_MONITOR_INCLUDE_SELF=1 \
        timeout 3 bash "$repo_root/scripts/watch-pr.sh" kawaz/test 1 2>&1 || true)

    assert_output "watch-pr: GH_MONITOR_INCLUDE_SELF=1 emits self comments too" "$out" \
        "$(printf 'user:self-bot\nuser:bob\n')" \
        "$(printf 'self filter: login=\n')"
}

# ============================================================
# Test 3: gh api user 失敗時 (api-user.txt が無い) は WARN + filter off
# ============================================================
test_watch_pr_self_login_unavailable() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # api-user.txt 無し → stub の `gh api user` は exit 1
    fixture_pr_baseline           > "$stub_dir/pr-view-1.json"
    fixture_pr_after_mixed_comments > "$stub_dir/pr-view-2.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_PR_INTERVAL=1 \
        timeout 3 bash "$repo_root/scripts/watch-pr.sh" kawaz/test 1 2>&1 || true)

    assert_output "watch-pr: gh api user 失敗 → WARN + filter off" "$out" \
        "$(printf 'self login 取得失敗\nuser:self-bot\nuser:bob\n')" \
        "$(printf 'self filter: login=\n')"
}

# ============================================================
# Test 4: watch-workflow.sh は actor に関わらず全 run を emit (DR-0004 改定)
# ============================================================
fixture_runs_with_self_and_other() {
    # updated_at は十分新しい (=今) にして cutoff にひっかからないように。
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":1001,"status":"completed","conclusion":"success","name":"ci","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"feature/x","actor":{"login":"self-bot"},"event":"push","updated_at":"$nowiso"},
  {"id":1002,"status":"completed","conclusion":"failure","name":"ci","head_sha":"abc1234567890abc1234567890abc1234567890a","head_branch":"feature/y","actor":{"login":"bob"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

test_watch_workflow_emits_all_actors() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # workflow 側は self filter なし (DR-0004 改定) なので api-user.txt 不要
    fixture_runs_with_self_and_other > "$stub_dir/runs-1.json"
    fixture_runs_with_self_and_other > "$stub_dir/runs-2.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 3 bash "$repo_root/scripts/watch-workflow.sh" --passive kawaz/test 2>&1 || true)

    assert_output "watch-workflow: emits all runs regardless of actor (DR-0004 改定)" "$out" \
        "$(printf 'user:self-bot\nuser:bob\n')" \
        "$(printf '[INFO] self filter:\n')"
}

# ============================================================
# Test 5: watch-workflow.sh は mode 必須 (--sha も --passive も無い → exit 2)
# ============================================================
test_watch_workflow_mode_required() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" \
        bash "$repo_root/scripts/watch-workflow.sh" kawaz/test 2>&1 || true)

    assert_output "watch-workflow: mode required (no --sha and no --passive)" "$out" \
        "$(printf '[ERROR] mode required\n')" \
        "$(printf '[INFO] watch-workflow start\n')"
}

# ============================================================
# Test 6: watch-workflow.sh --sha は指定 SHA のみ emit、grace 後 exit
# ============================================================
fixture_runs_for_sha() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":2001,"status":"completed","conclusion":"success","name":"ci","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"feature/x","actor":{"login":"alice"},"event":"push","updated_at":"$nowiso"},
  {"id":2002,"status":"completed","conclusion":"success","name":"ci","head_sha":"1111111111111111111111111111111111111111","head_branch":"feature/y","actor":{"login":"bob"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

test_watch_workflow_sha_pinned_filter_and_exit() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    fixture_runs_for_sha > "$stub_dir/runs-1.json"
    fixture_runs_for_sha > "$stub_dir/runs-2.json"
    fixture_runs_for_sha > "$stub_dir/runs-3.json"

    local out
    # grace=2s, interval=1s → 2 周後に grace 経過 → exit
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 8 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe --grace=2s kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --sha filters to matching commit + grace exit" "$out" \
        "$(printf 'commit:deadbee\ngrace window elapsed, exiting\n')" \
        "$(printf 'commit:1111111\n')"
}

# ============================================================
# Test (no-match): matching run を一度も観測しなければ no-match-timeout で exit
#   (issue 2026-06-02: 未 push SHA / 誤検出 repo / workflow 不在で 24h 張り付くのを防ぐ)
# ============================================================
fixture_runs_no_match() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":9001,"status":"completed","conclusion":"success","name":"ci","head_sha":"ffffffffffffffffffffffffffffffffffffffff","head_branch":"other","actor":{"login":"bob"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

test_watch_workflow_sha_pinned_no_match_timeout() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # 指定 SHA に一致する run が存在しない (= 別 SHA の run しかない)
    fixture_runs_no_match > "$stub_dir/runs-1.json"
    fixture_runs_no_match > "$stub_dir/runs-2.json"
    fixture_runs_no_match > "$stub_dir/runs-3.json"
    fixture_runs_no_match > "$stub_dir/runs-4.json"

    local out
    # no-match-timeout=2s → matching 0 のまま 2s 経過で exit。timeout(safety)=20s より先に発火すること
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 10 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe --no-match-timeout=2s --timeout=20s kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --sha exits via no-match-timeout when SHA never appears" "$out" \
        "$(printf 'no run found for SHA deadbee')" \
        "$(printf 'timeout reached')"
}

# ============================================================
# Test 7: codex review High-1 regression
#   matching run が in_progress で観測 → 次 poll で page から消える (= per_page から押し出された
#   想定) → exit してはいけない。matching_state に non-terminal が残ってる限り exit blocked
# ============================================================
fixture_runs_in_progress_sha() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":3001,"status":"in_progress","conclusion":null,"name":"ci","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"feature/x","actor":{"login":"alice"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

fixture_runs_empty() {
    cat <<'JSON'
{"workflow_runs":[]}
JSON
}

test_watch_workflow_sha_pinned_no_exit_when_known_non_terminal_disappears() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # 1 周目: in_progress 観測 → matching_state[3001]=in_progress
    fixture_runs_in_progress_sha > "$stub_dir/runs-1.json"
    # 2 周目以降: 空 (= 押し出された想定)
    fixture_runs_empty > "$stub_dir/runs-2.json"
    fixture_runs_empty > "$stub_dir/runs-3.json"
    fixture_runs_empty > "$stub_dir/runs-4.json"
    fixture_runs_empty > "$stub_dir/runs-5.json"

    local out
    # grace=1s, interval=1s, timeout=5s。in_progress が消えても exit すべきでない (= timeout で終わる)
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 8 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe --grace=1s --timeout=5s kawaz/test 2>&1 || true)

    # in_progress を observed したが grace exit ではなく timeout で終わる
    assert_output "watch-workflow: --sha does NOT exit when known non-terminal disappears from API window" "$out" \
        "$(printf 'timeout reached')" \
        "$(printf 'grace window elapsed, exiting\n')"
}

# ============================================================
# Test 8: in_progress → success の state transition で grace 経過 → exit
# ============================================================
fixture_runs_completed_sha() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":3001,"status":"completed","conclusion":"success","name":"ci","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"feature/x","actor":{"login":"alice"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

test_watch_workflow_sha_pinned_state_transition_then_exit() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # 1 周目: in_progress
    fixture_runs_in_progress_sha > "$stub_dir/runs-1.json"
    # 2 周目以降: success → 以降 grace 待ち
    fixture_runs_completed_sha > "$stub_dir/runs-2.json"
    fixture_runs_completed_sha > "$stub_dir/runs-3.json"
    fixture_runs_completed_sha > "$stub_dir/runs-4.json"
    fixture_runs_completed_sha > "$stub_dir/runs-5.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 10 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe --grace=2s --timeout=10s kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --sha in_progress -> success -> grace exit" "$out" \
        "$(printf 'status:in_progress\nstatus:success\ngrace window elapsed, exiting\n')" \
        ""
}

# ============================================================
# Test 9: 値必須オプションの値抜けで exit 2 (codex review #2 regression)
# ============================================================
test_watch_workflow_flag_value_missing() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" \
        bash "$repo_root/scripts/watch-workflow.sh" --sha 2>&1 || true)

    assert_output "watch-workflow: --sha without value exits 2" "$out" \
        "$(printf '%s' '--sha requires a value')" \
        ""

    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" \
        bash "$repo_root/scripts/watch-workflow.sh" --grace --passive kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --grace followed by --passive is value missing" "$out" \
        "$(printf '%s' '--grace requires a value')" \
        ""
}

# ============================================================
# Test 10/11/12: --on-success / --on-failure action hooks
# ============================================================
fixture_runs_release_in_progress() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":4001,"status":"in_progress","conclusion":null,"name":"Release","path":".github/workflows/release.yml","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"main","actor":{"login":"kawaz"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

fixture_runs_release_success() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":4001,"status":"completed","conclusion":"success","name":"Release","path":".github/workflows/release.yml","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"main","actor":{"login":"kawaz"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

fixture_runs_release_failure() {
    local nowiso
    nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"workflow_runs":[
  {"id":4001,"status":"completed","conclusion":"failure","name":"Release","path":".github/workflows/release.yml","head_sha":"deadbeefcafebabedeadbeefcafebabedeadbeef","head_branch":"main","actor":{"login":"kawaz"},"event":"push","updated_at":"$nowiso"}
]}
JSON
}

test_watch_workflow_on_success_emits_action() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    fixture_runs_release_in_progress > "$stub_dir/runs-1.json"
    fixture_runs_release_success     > "$stub_dir/runs-2.json"
    fixture_runs_release_success     > "$stub_dir/runs-3.json"
    fixture_runs_release_success     > "$stub_dir/runs-4.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 10 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe \
            --on-success Release "brew upgrade kawaz/tap/foo" \
            --grace=2s --timeout=10s kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --on-success emits [ACTION:<key>] on success transition" "$out" \
        "$(printf 'status:success\n[ACTION:Release] brew upgrade kawaz/tap/foo\n')" \
        ""
}

test_watch_workflow_on_failure_emits_action() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    fixture_runs_release_in_progress > "$stub_dir/runs-1.json"
    fixture_runs_release_failure     > "$stub_dir/runs-2.json"
    fixture_runs_release_failure     > "$stub_dir/runs-3.json"
    fixture_runs_release_failure     > "$stub_dir/runs-4.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 10 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe \
            --on-failure Release "say release failed" \
            --on-success Release "echo should-not-fire" \
            --grace=2s --timeout=10s kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --on-failure emits [ACTION:<key>] on failure transition" "$out" \
        "$(printf 'status:failure\n[ACTION:Release] say release failed\n')" \
        "$(printf 'echo should-not-fire\n')"
}

test_watch_workflow_on_success_matching_axes() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    fixture_runs_release_in_progress > "$stub_dir/runs-1.json"
    fixture_runs_release_success     > "$stub_dir/runs-2.json"
    fixture_runs_release_success     > "$stub_dir/runs-3.json"
    fixture_runs_release_success     > "$stub_dir/runs-4.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 10 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe \
            --on-success Release      "msg-name" \
            --on-success release.yml  "msg-basename" \
            --on-success release      "msg-stem" \
            --on-success NoMatch      "msg-skip" \
            --grace=2s --timeout=10s kawaz/test 2>&1 || true)

    assert_output "watch-workflow: --on-success matches name / basename / stem (no NoMatch leakage)" "$out" \
        "$(printf '[ACTION:Release] msg-name\n[ACTION:release.yml] msg-basename\n[ACTION:release] msg-stem\n')" \
        "$(printf '[ACTION:NoMatch] msg-skip\n')"
}

test_watch_workflow_on_success_missing_value() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" \
        bash "$repo_root/scripts/watch-workflow.sh" --on-success 2>&1 || true)

    assert_output "watch-workflow: --on-success without value exits 2" "$out" \
        "$(printf '%s' '--on-success requires a value')" \
        ""
}

# ============================================================
# Test: watch-workflow.sh — workflow 不在リポは即 exit 0
# ============================================================

# total_count=0 → "[INFO] no workflows in ..." を emit して exit 0
test_watch_workflow_no_workflows_exits_immediately() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    printf '{"total_count":0,"workflows":[]}' > "$stub_dir/workflows-response.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 5 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe kawaz/no-ci 2>&1 || true)

    assert_output "watch-workflow: total_count=0 → no workflows message + exit without watch" "$out" \
        "$(printf 'no workflows in kawaz/no-ci')" \
        "$(printf 'no matching run\n[WARN]\n')"
}

# total_count=1 → 通常通り watch 継続 (= start ack が出る)
test_watch_workflow_has_workflows_continues() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # workflows-response.json を用意しない → stub デフォルト (total_count=1)
    fixture_runs_no_match > "$stub_dir/runs-1.json"
    fixture_runs_no_match > "$stub_dir/runs-2.json"

    local out
    # no-match-timeout=2s → matching 0 のまま 2s で exit
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 8 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe \
            --no-match-timeout=2s --timeout=20s kawaz/with-ci 2>&1 || true)

    assert_output "watch-workflow: total_count=1 → watch starts (start ack present)" "$out" \
        "$(printf '[INFO] watch-workflow start')" \
        "$(printf 'no workflows in\n')"
}

# gh api 失敗 (exit 1) → fail-open: start ack が出て watch 継続
test_watch_workflow_api_failure_fail_open() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    # workflows-response.json を作らず、かつ runs-*.json も置かない
    # → workflows endpoint は stub デフォルト (total_count=1) なので fail 不能
    # → 別 stub を上書きして workflows endpoint を exit 1 させる
    mkdir -p "$stub_dir/bin2"
    cat > "$stub_dir/bin2/gh" <<'FAILSTUB'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [[ "$2" == /repos/*/actions/workflows* ]]; then
    echo "[stub] simulated api failure" >&2
    exit 1
fi
GH_STUB_DIR="${GH_STUB_DIR:?stub gh: GH_STUB_DIR not set}"
if [ "$1" = "api" ] && [[ "$2" == /repos/* ]]; then
    counter_file="$GH_STUB_DIR/counter-runs"
    n=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$counter_file"
    f="$GH_STUB_DIR/runs-${n}.json"
    if [ ! -f "$f" ]; then
        last=$(find "$GH_STUB_DIR" -maxdepth 1 -name 'runs-*.json' 2>/dev/null | sort -V | tail -1)
        [ -n "$last" ] && f="$last"
    fi
    cat "$f"
    exit 0
fi
echo "[stub] unhandled: $*" >&2; exit 1
FAILSTUB
    chmod +x "$stub_dir/bin2/gh"
    fixture_runs_no_match > "$stub_dir/runs-1.json"
    fixture_runs_no_match > "$stub_dir/runs-2.json"

    local out
    # no-match-timeout=2s → api 失敗後も watch が継続して no-match で exit
    out=$(PATH="$stub_dir/bin2:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 8 bash "$repo_root/scripts/watch-workflow.sh" --sha deadbeefcafebabe \
            --no-match-timeout=2s --timeout=20s kawaz/fail-api 2>&1 || true)

    assert_output "watch-workflow: gh api workflows failure → fail-open, watch continues" "$out" \
        "$(printf '[INFO] watch-workflow start')" \
        "$(printf 'no workflows in\n')"
}

# ============================================================
# Test: post_tool_use.sh — workflow 不在リポは nudge を出さない
# ============================================================

# helper: post_tool_use.sh に push JSON を stdin で流して出力を返す
run_hook() {
    local project_dir="$1"
    local extra_env="${2:-}"
    local push_cmd='git push origin main'
    local json
    json=$(jq -n \
        --arg cmd "$push_cmd" \
        --arg cwd "$project_dir" \
        '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{output:""},cwd:$cwd}')
    env -i PATH="$PATH" HOME="$HOME" \
        CLAUDE_PROJECT_DIR="$project_dir" \
        $extra_env \
        bash "$repo_root/hooks/post_tool_use.sh" <<< "$json" 2>&1 || true
}

# workflow ディレクトリ無しの場合 → additionalContext は出ない
test_hook_no_workflow_dir_no_nudge() {
    local tmp_repo; tmp_repo=$(mktemp -d)
    trap 'rm -rf "$tmp_repo"' RETURN
    git init -q "$tmp_repo"
    git -C "$tmp_repo" remote add origin "https://github.com/kawaz/no-ci-repo.git"
    # .github/workflows/ を作らない

    local out
    out=$(run_hook "$tmp_repo")

    assert_output "hook: no .github/workflows dir → no nudge" "$out" \
        "" \
        "$(printf 'additionalContext\nwatch-workflow\n')"
}

# .github/workflows/ が空ディレクトリの場合 → nudge を出さない
test_hook_empty_workflow_dir_no_nudge() {
    local tmp_repo; tmp_repo=$(mktemp -d)
    trap 'rm -rf "$tmp_repo"' RETURN
    git init -q "$tmp_repo"
    git -C "$tmp_repo" remote add origin "https://github.com/kawaz/no-ci-repo.git"
    mkdir -p "$tmp_repo/.github/workflows"
    # workflows/ は空 (yml ファイルなし)

    local out
    out=$(run_hook "$tmp_repo")

    assert_output "hook: empty .github/workflows dir → no nudge" "$out" \
        "" \
        "$(printf 'additionalContext\nwatch-workflow\n')"
}

# cd <path> && push の形で越境 push した場合、cd 先リポを基準にする
# - CLAUDE_PROJECT_DIR は workflow 無しリポ、cd 先は workflow ありリポ → nudge が出る
test_hook_cd_push_uses_cd_repo() {
    local tmp_project; tmp_project=$(mktemp -d)
    local tmp_cd_repo; tmp_cd_repo=$(mktemp -d)
    trap 'rm -rf "$tmp_project" "$tmp_cd_repo"' RETURN

    # CLAUDE_PROJECT_DIR: workflow 無しリポ
    git init -q "$tmp_project"
    git -C "$tmp_project" remote add origin "https://github.com/kawaz/no-ci-repo.git"

    # cd 先: workflow ありリポ
    git init -q "$tmp_cd_repo"
    git -C "$tmp_cd_repo" remote add origin "https://github.com/kawaz/has-ci-repo.git"
    mkdir -p "$tmp_cd_repo/.github/workflows"
    echo 'name: CI' > "$tmp_cd_repo/.github/workflows/ci.yml"
    git -C "$tmp_cd_repo" config user.email "test@example.com"
    git -C "$tmp_cd_repo" config user.name "test"
    touch "$tmp_cd_repo/README.md"
    git -C "$tmp_cd_repo" add README.md
    git -C "$tmp_cd_repo" commit -q -m "init"

    local cmd="cd $tmp_cd_repo && just push"
    local json
    json=$(jq -n --arg cmd "$cmd" --arg cwd "$tmp_project" \
        '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{output:""},cwd:$cwd}')
    local out
    out=$(env -i PATH="$PATH" HOME="$HOME" \
        CLAUDE_PROJECT_DIR="$tmp_project" \
        bash "$repo_root/hooks/post_tool_use.sh" <<< "$json" 2>&1 || true)

    assert_output "hook: cd <path> && push → cd 先リポで repo/workflow 判定" "$out" \
        "$(printf 'additionalContext\nwatch-workflow\n')" \
        ""
}

# cd <path> && push で cd 先リポに workflow 無し → nudge なし
test_hook_cd_push_no_workflow_in_cd_repo() {
    local tmp_project; tmp_project=$(mktemp -d)
    local tmp_cd_repo; tmp_cd_repo=$(mktemp -d)
    trap 'rm -rf "$tmp_project" "$tmp_cd_repo"' RETURN

    # CLAUDE_PROJECT_DIR: workflow ありリポ
    git init -q "$tmp_project"
    git -C "$tmp_project" remote add origin "https://github.com/kawaz/has-ci-repo.git"
    mkdir -p "$tmp_project/.github/workflows"
    echo 'name: CI' > "$tmp_project/.github/workflows/ci.yml"

    # cd 先: workflow 無しリポ
    git init -q "$tmp_cd_repo"
    git -C "$tmp_cd_repo" remote add origin "https://github.com/kawaz/no-ci-repo.git"

    local cmd="cd $tmp_cd_repo && git push"
    local json
    json=$(jq -n --arg cmd "$cmd" --arg cwd "$tmp_project" \
        '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{output:""},cwd:$cwd}')
    local out
    out=$(env -i PATH="$PATH" HOME="$HOME" \
        CLAUDE_PROJECT_DIR="$tmp_project" \
        bash "$repo_root/hooks/post_tool_use.sh" <<< "$json" 2>&1 || true)

    assert_output "hook: cd <path> && push, cd 先に workflow 無し → nudge なし" "$out" \
        "" \
        "$(printf 'additionalContext\nwatch-workflow\n')"
}

# .yml ファイルがある場合 → additionalContext が出る (nudge あり)
test_hook_has_workflow_yml_nudge() {
    local tmp_repo; tmp_repo=$(mktemp -d)
    trap 'rm -rf "$tmp_repo"' RETURN
    git init -q "$tmp_repo"
    git -C "$tmp_repo" remote add origin "https://github.com/kawaz/has-ci-repo.git"
    mkdir -p "$tmp_repo/.github/workflows"
    echo 'name: CI' > "$tmp_repo/.github/workflows/ci.yml"
    # HEAD が必要 (sha 解決用)
    git -C "$tmp_repo" config user.email "test@example.com"
    git -C "$tmp_repo" config user.name "test"
    touch "$tmp_repo/README.md"
    git -C "$tmp_repo" add README.md
    git -C "$tmp_repo" commit -q -m "init"

    local out
    out=$(run_hook "$tmp_repo")

    assert_output "hook: .yml present → additionalContext with watch-workflow nudge" "$out" \
        "$(printf 'additionalContext\nwatch-workflow\n')" \
        ""
}

# ============================================================
# 実行
# ============================================================

echo "Running gh-monitor tests..."
test_watch_pr_self_filter_on
test_watch_pr_self_filter_off_by_env
test_watch_pr_self_login_unavailable
test_watch_workflow_emits_all_actors
test_watch_workflow_mode_required
test_watch_workflow_sha_pinned_filter_and_exit
test_watch_workflow_sha_pinned_no_match_timeout
test_watch_workflow_sha_pinned_no_exit_when_known_non_terminal_disappears
test_watch_workflow_sha_pinned_state_transition_then_exit
test_watch_workflow_flag_value_missing
test_watch_workflow_on_success_emits_action
test_watch_workflow_on_failure_emits_action
test_watch_workflow_on_success_matching_axes
test_watch_workflow_on_success_missing_value
test_watch_workflow_no_workflows_exits_immediately
test_watch_workflow_has_workflows_continues
test_watch_workflow_api_failure_fail_open
test_hook_no_workflow_dir_no_nudge
test_hook_empty_workflow_dir_no_nudge
test_hook_cd_push_uses_cd_repo
test_hook_cd_push_no_workflow_in_cd_repo
test_hook_has_workflow_yml_nudge

echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    printf 'Failed tests:\n'
    for t in "${failed_tests[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
