#!/usr/bin/env bash
# 現在のディレクトリのブランチに紐づくオープン PR を検出する。
# 見つかれば "OWNER/REPO\tPR_NUMBER" を stdout に 1行出力して exit 0。
# 見つからなければ exit 1。
#
# Usage:
#   detect-pr.sh              # カレントディレクトリで実行
#   detect-pr.sh <workdir>    # 指定ディレクトリで実行

set -u

workdir=${1:-.}
cd "$workdir" 2>/dev/null || { echo "[ERROR] cannot cd to $workdir" >&2; exit 1; }

# Git リポジトリか
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    exit 1
fi

# 現在のブランチ名
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    # detached HEAD やブランチ未決定
    exit 1
fi

# gh でブランチに紐づく PR を探す (repo と number を JSON で取る)
result=$(gh pr list --state open --head "$branch" --limit 1 --json number,headRepository,headRepositoryOwner 2>/dev/null || true)

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
