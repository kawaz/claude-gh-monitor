# Claude Code Plugin: gh-monitor
# Canonical task runner. VCS 操作は `bump-semver vcs` サブコマンド (DR-0020)
# 経由で jj/git 透過化。claude-plugin-reference / bump-semver の justfile と
# 同じ流儀。

set shell := ["bash", "-euo", "pipefail", "-c"]

# ---------- variables ----------

# bump trigger 対象 = plugin 配布物の変更
# = これらが変わったら version bump 必須 (docs/ 等のメタは除外)
bump-trigger-paths := ".claude-plugin/ scripts/ hooks/ skills/"

# version を持つ manifest ファイル (multi-file = 整合性チェック対象)
version-files := ".claude-plugin/plugin.json .claude-plugin/marketplace.json"

# ---------- main tasks ----------

default:
    @just --list

# shellcheck (scripts/ + hooks/) + actionlint (.github/workflows/)
lint:
    shellcheck scripts/*.sh hooks/*.sh
    @if command -v actionlint >/dev/null 2>&1; then \
        actionlint .github/workflows/*.yml; \
    else \
        echo "(actionlint not installed, skipping; install: brew install actionlint)" >&2; \
    fi

# plugin manifest を検証
validate:
    claude plugin validate .

# 現在の version を表示 (multi-file 整合性チェック付き)
version:
    @bump-semver get {{ version-files }} --no-hint

# self filter (DR-0004) ほかの smoke test
test:
    bash tests/run-tests.sh

# CI とローカルの検査範囲を一致 (単一エントリ)
ci: lint validate test

# version を bump (default: patch)
bump-version level="patch": ensure-clean
    bump-semver {{ level }} {{ version-files }} --write --no-hint
    @echo "Version: -> $(bump-semver get {{ version-files }} --no-hint)"

# push (バージョン bump 済みを前提、全 gate 通過後に push)
push: ensure-clean ci check-outdated-translations check-versions check-version-bumped
    bump-semver vcs push --branch main --jj-bookmark-auto-advance
    @just _local-plugin-reload

# push (ドキュメント更新等のみで bump 不要な場合)
push-without-bump: ensure-clean ci check-outdated-translations check-versions
    bump-semver vcs push --branch main --jj-bookmark-auto-advance
    @just _local-plugin-reload

# ---------- internal recipes (push の依存) ----------

# working copy が clean (= @ が empty change) であることを検証
[private]
ensure-clean:
    bump-semver vcs is clean

# plugin.json と marketplace.json の version 一致を保証 (multi-file 整合性)
# bump-semver get は multi-file 時に内部で整合チェック (不一致は error 表示で exit 非 0)
[private]
check-versions:
    @bump-semver get {{ version-files }} --no-hint >/dev/null

# 翻訳ペア (README-ja.md ↔ README.md, DESIGN-ja.md ↔ DESIGN.md 等) の鮮度チェック
# FROM = ja 版 (= source、日本語で先に書く)、TO = $1/$2.md (= en 版、derived)
# en 版が ja 版より古いと exit 1 (stale)。canonical (bump-semver / claude-plugin-reference)
# と同じ glob 規約。
[private]
check-outdated-translations: ensure-clean
    bump-semver vcs outdated 'glob:**/*-ja.md' '$1/$2.md'

# push 成功直後の local 反映: 現セッションの marketplace + plugin を update し
# kawaz に /reload-plugins 依頼まで出す。push して終わりだと local Claude は
# 古い plugin で動き続けるため、push task に embed して仕組みで強制する。
[private]
_local-plugin-reload:
    claude plugin marketplace update gh-monitor
    claude plugin update gh-monitor@gh-monitor
    @echo ""
    @echo "[hint] kawaz, /reload-plugins で本セッションに反映してください (再起動なしで効きます)"

# bump-trigger-paths に変更があるなら version も bump されているか検証
# bump-semver vcs diff の exit code:
#   0 = bump-trigger-paths に変更なし → bump 不要
#   1 = 変更あり → version bump 済みかチェックに進む
#   3 = VCS error (main@origin 未 track 等)
[private]
check-version-bumped:
    #!/usr/bin/env bash
    set -euo pipefail
    rc=0
    bump-semver vcs diff -q main@origin -- {{ bump-trigger-paths }} || rc=$?
    case "$rc" in
      0) exit 0 ;;
      1) ;;
      *) echo "ERROR: bump-semver vcs diff failed (rc=$rc). main@origin が track されていない可能性。先に 'jj git fetch' / 'git fetch' を試してください" >&2; exit 1 ;;
    esac
    bump-semver compare gt .claude-plugin/plugin.json vcs:main@origin:.claude-plugin/plugin.json --no-hint && exit 0
    echo 'ERROR: bump-trigger-paths が変わってるが version 未 bump。"just bump-version" を実行してください' >&2
    exit 1
