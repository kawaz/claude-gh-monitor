# Claude Code Plugin: pr-monitor

default:
    @just --list

# shellcheck（scripts/ と hooks/ の .sh を検査）
lint:
    shellcheck scripts/*.sh hooks/*.sh

# プラグイン manifest の検証
validate:
    claude plugin validate .

# バージョン表示
version:
    @jq -r '.version' .claude-plugin/plugin.json

# @ が empty（未コミット変更なし）であることを検証
ensure-clean:
    test "$(jj log -r @ --no-graph -T 'empty')" = "true"

# plugin.json と marketplace.json のバージョン一致チェック
check-versions:
    @test "$(jq -r '.version' .claude-plugin/plugin.json)" = "$(jq -r '.metadata.version' .claude-plugin/marketplace.json)" \
        || { echo "ERROR: plugin.json と marketplace.json のバージョンが不一致です" >&2; exit 1; }

# main@origin との差分があればバージョン bump が必須
check-version-bump:
    #!/usr/bin/env bash
    set -euo pipefail
    remote_ver=$(jj file show .claude-plugin/plugin.json -r main@origin 2>/dev/null | jq -r '.version' 2>/dev/null || echo "")
    local_ver=$(jq -r '.version' .claude-plugin/plugin.json)
    if [ -z "$remote_ver" ]; then
        exit 0  # main@origin が無い（初回 push）ならスキップ
    fi
    # @- と main@origin の間に差分があるのに version が同じなら bump 必要
    diff_summary=$(jj diff --from main@origin --to @- --summary 2>/dev/null || echo "")
    if [ "$local_ver" = "$remote_ver" ] && [ -n "$diff_summary" ]; then
        echo "ERROR: 変更がありますがバージョンが未更新です ($local_ver)" >&2
        echo "  bump するなら: just bump-version [patch|minor|major]" >&2
        echo "  bump 不要なら: just push-without-bump" >&2
        exit 1
    fi

# バージョンバンプ（patch / minor / major）
bump-version level="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    CURRENT=$(jq -r '.version' .claude-plugin/plugin.json)
    IFS='.' read -r major minor patch <<< "$CURRENT"
    case "{{level}}" in
        major) major=$((major+1)); minor=0; patch=0 ;;
        minor) minor=$((minor+1)); patch=0 ;;
        patch) patch=$((patch+1)) ;;
        *) echo "ERROR: level must be patch|minor|major" >&2; exit 1 ;;
    esac
    NEW="$major.$minor.$patch"
    jq --arg v "$NEW" '.version = $v' .claude-plugin/plugin.json > tmp.$$.json && mv tmp.$$.json .claude-plugin/plugin.json
    jq --arg v "$NEW" '.metadata.version = $v' .claude-plugin/marketplace.json > tmp.$$.json && mv tmp.$$.json .claude-plugin/marketplace.json
    echo "Version bumped: $CURRENT -> $NEW"

# push（バージョン bump 済みを前提、全チェック後に @- を push）
push: ensure-clean lint validate check-versions check-version-bump
    jj bookmark set main -r @-
    jj git push --bookmark main

# push（ドキュメント更新等のみで bump 不要な場合）
push-without-bump: ensure-clean lint validate check-versions
    jj bookmark set main -r @-
    jj git push --bookmark main
