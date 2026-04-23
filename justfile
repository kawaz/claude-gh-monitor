# Claude Code Plugin: pr-monitor

default:
    @just --list

# プラグインの検証
validate:
    claude plugin validate .

# バージョン表示
version:
    @jq -r '.version' .claude-plugin/plugin.json

# shellcheck（scripts/ と hooks/ の .sh を検査）
lint:
    shellcheck scripts/*.sh hooks/*.sh

# バージョン一致チェック + push
push:
    #!/usr/bin/env bash
    set -euo pipefail
    plugin_ver=$(jq -r '.version' .claude-plugin/plugin.json)
    market_ver=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
    if [ "$plugin_ver" != "$market_ver" ]; then
        echo "ERROR: plugin.json ($plugin_ver) と marketplace.json ($market_ver) のバージョンが不一致です" >&2
        echo "両方を同じバージョンに更新してください" >&2
        exit 1
    fi
    shellcheck scripts/*.sh hooks/*.sh
    claude plugin validate .
    echo "Plugin v$plugin_ver validated. Pushing..."
    jj bookmark set main -r @
    jj git push

# push (バージョン bump なし、ドキュメント更新のみの場合)
push-without-bump:
    #!/usr/bin/env bash
    set -euo pipefail
    shellcheck scripts/*.sh hooks/*.sh
    claude plugin validate .
    jj bookmark set main -r @
    jj git push

# バージョンバンプ（patch / minor / major）
bump-version bump="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    CURRENT=$(jq -r '.version' .claude-plugin/plugin.json)
    IFS='.' read -r major minor patch <<< "$CURRENT"
    case "{{bump}}" in
        major) major=$((major+1)); minor=0; patch=0 ;;
        minor) minor=$((minor+1)); patch=0 ;;
        patch) patch=$((patch+1)) ;;
    esac
    NEW="$major.$minor.$patch"
    jq --arg v "$NEW" '.version = $v' .claude-plugin/plugin.json > tmp.$$.json && mv tmp.$$.json .claude-plugin/plugin.json
    jq --arg v "$NEW" '.metadata.version = $v' .claude-plugin/marketplace.json > tmp.$$.json && mv tmp.$$.json .claude-plugin/marketplace.json
    echo "Version bumped: $CURRENT -> $NEW"
