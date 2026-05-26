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
# Test 4: watch-workflow.sh actor=self-bot の run は emit されない
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

test_watch_workflow_self_filter_on() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    echo 'self-bot' > "$stub_dir/api-user.txt"
    fixture_runs_with_self_and_other > "$stub_dir/runs-1.json"
    fixture_runs_with_self_and_other > "$stub_dir/runs-2.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        timeout 3 bash "$repo_root/scripts/watch-workflow.sh" kawaz/test 2>&1 || true)

    assert_output "watch-workflow: self filter ON suppresses self runs" "$out" \
        "$(printf 'self filter: login=self-bot\nuser:bob\n')" \
        "$(printf 'user:self-bot\n')"
}

# ============================================================
# Test 5: watch-workflow.sh GH_MONITOR_INCLUDE_SELF=1 で self も emit
# ============================================================
test_watch_workflow_self_filter_off_by_env() {
    local stub_dir; stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' RETURN
    write_stub "$stub_dir/bin"
    echo 'self-bot' > "$stub_dir/api-user.txt"
    fixture_runs_with_self_and_other > "$stub_dir/runs-1.json"
    fixture_runs_with_self_and_other > "$stub_dir/runs-2.json"

    local out
    out=$(PATH="$stub_dir/bin:$PATH" GH_STUB_DIR="$stub_dir" WATCH_WORKFLOW_INTERVAL=1 \
        GH_MONITOR_INCLUDE_SELF=1 \
        timeout 3 bash "$repo_root/scripts/watch-workflow.sh" kawaz/test 2>&1 || true)

    assert_output "watch-workflow: GH_MONITOR_INCLUDE_SELF=1 emits self runs" "$out" \
        "$(printf 'user:self-bot\nuser:bob\n')" \
        ""
}

# ============================================================
# 実行
# ============================================================

echo "Running gh-monitor tests..."
test_watch_pr_self_filter_on
test_watch_pr_self_filter_off_by_env
test_watch_pr_self_login_unavailable
test_watch_workflow_self_filter_on
test_watch_workflow_self_filter_off_by_env

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
