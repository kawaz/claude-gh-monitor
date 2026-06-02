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
