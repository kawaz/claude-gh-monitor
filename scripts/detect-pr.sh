#!/usr/bin/env bash
# 現在のディレクトリのブランチ(bookmark)に紐づくオープン PR を検出する。
# 見つかれば "OWNER/REPO\tPR_NUMBER" を stdout に 1行出力して exit 0。
# 見つからなければ exit 1。
#
# git と jj workspace 方式の両方に対応。
#
# Usage:
#   detect-pr.sh              # カレントディレクトリで実行
#   detect-pr.sh <workdir>    # 指定ディレクトリで実行

set -u

workdir=${1:-.}
cd "$workdir" 2>/dev/null || { echo "[ERROR] cannot cd to $workdir" >&2; exit 1; }

# Git リポジトリか（jj workspace も内部的には git）
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    exit 1
fi

# ブランチ/bookmark 名を取得
# 1. git branch --show-current: 通常の git + jj workspace の両方で動くことが多い
# 2. jj log: jj workspace で @ 自身に bookmark が無く祖先にある場合のフォールバック
# 3. git rev-parse: 最後のフォールバック（古い git 向け）
branch=$(git branch --show-current 2>/dev/null || true)

if [ -z "$branch" ] && command -v jj >/dev/null 2>&1; then
    branch=$(jj log -r 'heads(bookmarks() & ::@)' --no-graph \
        -T 'bookmarks ++ "\n"' 2>/dev/null \
        | awk 'NF{print $1; exit}')
fi

if [ -z "$branch" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    exit 1
fi

# gh でブランチに紐づく open PR を探す
result=$(gh pr list --state open --head "$branch" --limit 1 \
    --json number,headRepository,headRepositoryOwner 2>/dev/null || true)

if [ -z "$result" ] || [ "$result" = "[]" ]; then
    exit 1
fi

owner=$(printf '%s' "$result" | jq -r '.[0].headRepositoryOwner.login // empty')
name=$(printf '%s' "$result" | jq -r '.[0].headRepository.name // empty')
number=$(printf '%s' "$result" | jq -r '.[0].number // empty')

if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$number" ]; then
    exit 1
fi

printf '%s/%s\t%s\n' "$owner" "$name" "$number"
