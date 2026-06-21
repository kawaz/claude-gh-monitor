---
title: release.yml semver gate に latest-release 並列 check 追加 (DR-0039 canonical 同期)
status: open
category: request
created: 2026-06-28T20:02:33+09:00
last_read:
open_entered: 2026-06-28T20:02:33+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: 自リポ TODO
---

# release.yml semver gate に latest-release 並列 check 追加 (DR-0039 canonical 同期)

## 概要

bump-semver canonical (DR-0039) で更新された release.yml の semver gate pattern に追従する。本リポは `latest-tag` 単独 + `gh release view` の B 型で gap があるため、`latest-release` 並列 check を追加して完全 gate にする。

## 背景

bump-semver canonical (DR-0039) で release.yml の semver gate pattern が更新された。本リポは `latest-tag` 単独 + `gh release view` の B 型で、`gh release create` が origin に git tag を push しない仕様で gap がある (= GH の最新 release より古い tag を返すケース)。

## 現状 (release.yml L51-77 該当)

`vcs tag latest` (旧 verb) + `gh release view` のみ、`latest-release` 並列 check 無し。kawaz/die 実機事故 (v0.1.x の上に後発 v0.0.2 が Latest 取った GH の罠) で`--latest=automatic` の date-priority 罠も判明したため、release.yml 側で完全 gate するのが正解。

## 修正方針

```yaml
FAIL=0
if LATEST_REL=$(bump-semver vcs get latest-release --repository "$REPO" 2>/dev/null); then
  bump-semver compare gt "$CURRENT" "$LATEST_REL" -qq || { echo "::error::..."; FAIL=1; }
fi
if LATEST_TAG=$(bump-semver vcs get latest-tag --include-prerelease --vcs git 2>/dev/null); then
  bump-semver compare gt "$CURRENT" "$LATEST_TAG" -qq || { echo "::error::..."; FAIL=1; }
fi
[ "$FAIL" = "1" ] && exit 1
gh release view "v${CURRENT}" --repo "$REPO" >/dev/null 2>&1 || echo "changed=true" >> "$GITHUB_OUTPUT"
```

また DR-0032 の verb 整理 (`vcs tag latest` → `vcs get latest-tag` / `vcs get latest-release`) にも追従。

## 参考

- bump-semver の `.github/workflows/release.yml` (canonical 実装)
- bump-semver の docs/decisions/DR-0039-release-yml-semver-gate-pattern.md
- kawaz/die dogfood 報告: session 911732b3、2026-06-28

## 優先度

中 (= B 型 = `latest-tag` 単独で gap あり)。bump-semver v0.43.0 release 後に着手推奨。

## 受け入れ条件

- [ ] `latest-release` 並列 check が release.yml に追加されている
- [ ] `vcs tag latest` → `vcs get latest-tag` / `vcs get latest-release` に verb 更新済み
- [ ] bump-semver canonical (DR-0039) の gate pattern と整合している
