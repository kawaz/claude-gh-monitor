# claude-gh-monitor justfile
# VCS 操作と翻訳 check は bump-semver vcs に委譲 (DR-0020 dogfood)。canonical: kawaz/bump-semver。
# just 変数は使わず paths はリテラル直書き、引数は positional-arguments ($1/$@) で受ける
# (just 変数値を {{ }} で shell に渡すとクオート/単語分割が壊れるため)。

set shell := ["bash", "-euo", "pipefail", "-c"]

set script-interpreter := ["bash", "-euo", "pipefail"]

set positional-arguments

default: list

# recipe 一覧 (宣言順)
list:
    @just --list --unsorted

# ---------- lint / validate / test ----------

# shellcheck + actionlint
lint:
    shellcheck scripts/*.sh hooks/*.sh
    @if command -v actionlint >/dev/null 2>&1; then \
        actionlint .github/workflows/*.yml; \
    else \
        echo "(actionlint not installed, skipping; install: brew install actionlint)" >&2; \
    fi

# plugin manifest の構造検証
validate:
    claude plugin validate .

# self filter (DR-0004) smoke test
test:
    bash tests/run-tests.sh

ci: lint validate test

# ---------- gates ----------

[private]
ensure-clean:
    bump-semver vcs is clean

# plugin.json と marketplace.json の version 整合 (不一致なら error exit)
[private]
check-versions:
    @bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json --no-hint >/dev/null

# 翻訳ペア鮮度 (ja が新しく en が古いと stale = exit 1)
[private]
check-outdated-translations: ensure-clean
    bump-semver vcs outdated 'glob:**/*-ja.md' '$1/$2.md'

# plugin 本体 paths に diff があるのに version 未 bump なら止める
# (vcs diff -q: 0=diff なし pass / 1=diff あり要検証 / 3=VCS error)
[private]
[script]
check-version-bumped:
    rc=0
    bump-semver vcs diff -q main@origin -- .claude-plugin/ scripts/ hooks/ skills/ || rc=$?
    case "$rc" in
      0) exit 0 ;;
      1) ;;
      *) echo "ERROR: bump-semver vcs diff failed (rc=$rc). 'jj git fetch' で main@origin を track" >&2; exit 1 ;;
    esac
    bump-semver compare gt .claude-plugin/plugin.json vcs:main@origin:.claude-plugin/plugin.json --no-hint && exit 0
    echo 'ERROR: plugin 本体に変更があるのに version 未 bump。"just bump-version" を実行' >&2
    exit 1

# ---------- release ----------

# version bump (default patch) + release commit (write + commit atomic)
bump-version level="patch": ensure-clean
    bump-semver "$1" .claude-plugin/plugin.json .claude-plugin/marketplace.json --write --no-hint
    bump-semver vcs commit --allow-nonexistent-path -m "Release v$(bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json --no-hint)" .claude-plugin/plugin.json .claude-plugin/marketplace.json
    @echo "Version: -> $(bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json --no-hint)"

# push (docs/workflow のみの変更は check-version-bumped が自動 pass)
push: ensure-clean ci check-outdated-translations check-versions check-version-bumped
    bump-semver vcs push --branch main --jj-bookmark-auto-advance
    @echo "[hint] self-dogfood: watch-workflow に --on-success Release 'just on-success-release' を付けて起動"

# Release workflow success 時の reload route (検証済み version を local plugin cache に反映)
on-success-release:
    claude plugin marketplace update gh-monitor
    claude plugin update gh-monitor@gh-monitor
    @echo "[hint] /reload-plugins to apply the verified release without restart"

# ---------- utility ----------

# version 表示 (multi-file 一致時 1 行)
version:
    @bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json --no-hint
