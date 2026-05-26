# Claude Code Plugin: gh-monitor

default:
    @just --list

# shellcheck（scripts/ と hooks/ の .sh を検査）+ actionlint (.github/workflows/*.yml)
# actionlint が未インストールでも lint 自体は失敗させない (warning 表示のみ)
lint:
    shellcheck scripts/*.sh hooks/*.sh
    @if command -v actionlint >/dev/null 2>&1; then \
        actionlint .github/workflows/*.yml; \
    else \
        echo "(actionlint not installed, skipping; install: brew install actionlint)" >&2; \
    fi

# プラグイン manifest の検証
validate:
    claude plugin validate .

# バージョン表示（multi-file: 全ファイル一致時のみ成功）
version:
    @bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json

# CI とローカルの検査範囲を完全一致させる単一エントリ
ci: lint validate

# @ が empty（未コミット変更なし）であることを検証
ensure-clean:
    test "$(jj log -r @ --no-graph -T 'empty')" = "true"

# plugin.json と marketplace.json のバージョン一致チェック
# bump-semver get は multi-file 時に内部で整合チェック (不一致は error 表示で exit 非 0)
check-versions:
    @bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json >/dev/null

# main@origin との差分があればバージョン bump が必須
check-version-bump:
    #!/usr/bin/env bash
    set -euo pipefail
    remote_ver=$(jj file show .claude-plugin/plugin.json -r main@origin 2>/dev/null | jq -r '.version' 2>/dev/null || echo "")
    local_ver=$(bump-semver get .claude-plugin/plugin.json)
    if [ -z "$remote_ver" ]; then
        exit 0  # main@origin が無い（初回 push）ならスキップ
    fi
    # @- と main@origin の間に差分があるのに version が同じなら bump 必要
    diff_summary=$(jj diff --from main@origin --to @- --summary 2>/dev/null || echo "")
    if [ "$local_ver" = "$remote_ver" ] && [ -n "$diff_summary" ]; then
        echo "ERROR: 変更がありますがバージョンが未更新です ($local_ver)" >&2
        echo "  bump するなら: just bump-semver [patch|minor|major]" >&2
        echo "  bump 不要なら: just push-without-bump" >&2
        exit 1
    fi

# バージョンバンプ（patch / minor / major）。multi-file 1 行で plugin.json / marketplace.json 一括更新
bump-semver level="patch":
    bump-semver "{{level}}" .claude-plugin/plugin.json .claude-plugin/marketplace.json --write
    @echo "Version: -> $(bump-semver get .claude-plugin/plugin.json .claude-plugin/marketplace.json)"

# push（バージョン bump 済みを前提、全チェック後に @- を push）
push: ensure-clean ci check-versions check-version-bump
    jj bookmark set main -r @-
    jj git push --bookmark main

# push（ドキュメント更新等のみで bump 不要な場合）
push-without-bump: ensure-clean ci check-versions
    jj bookmark set main -r @-
    jj git push --bookmark main
