# pkf-tasks の release.yml が `vcs:latest-tag()` バグ残存 (横断調査結果)

gh-monitor 0.4.2 で修正した [release.yml の `vcs:latest-tag()` → `vcs tag latest` 移行 (DR-0020)](../journal/2026-06-02-sha-pinned-followup-and-release-guard-fix.md) を契機に、kawaz/* の release.yml 全 9 リポを横断 grep した。**`vcs:latest-tag()` の live 使用は kawaz/pkf-tasks の 1 リポのみ残存**。

> **Status**: 2026-06-02 発見、修正担当未確定。peer session (49bba385、cmux-msg リポ作業中) と coordinate 中。
> 起票ロケーション: 本 issue は gh-monitor リポに置いているが、修正は pkf-tasks 側で行う前提 (= durable 化のため一旦置く)。

## 横断調査結果

```bash
grep -rln 'vcs:latest-tag' ~/.local/share/repos/github.com/kawaz/*/main/.github/workflows/*.yml
```

| リポ | 状態 | 詳細 |
|---|---|---|
| kawaz/bump-semver | ✅ 健全 | canonical、live 部分は `vcs tag latest`、`vcs:latest-tag()` は説明コメントのみ |
| kawaz/claude-gh-monitor | ✅ 健全 | v0.4.2 で修正済 (= 本 journal の起点) |
| kawaz/pkf-tasks | ⚠️ **live バグ** | `.github/workflows/release.yml:63` で `vcs:latest-tag()` を guard に使用 |

その他 release.yml を持つ kawaz リポ (authsock-warden / hyoui / jj-worktree / port-peeker / stable-which / template-rust) は `vcs:latest-tag()` 不使用 (別パターンの release.yml、本 issue とは無関係)。

## pkf-tasks 固有の注意点

pkf-tasks の release.yml は **monorepo-style tag** `pkf-tasks@X.Y.Z` も release 対象に含めている (release.yml の comments line 61, 170):

```yaml
# vcs:latest-tag() は monorepo-style `pkf-tasks@X.Y.Z` も @ peel fallback で認識
set +e
bump-semver compare gt "$CURRENT_VERSION" 'vcs:latest-tag()' --vcs git
```

旧 `vcs:latest-tag()` は @ peel fallback でこの monorepo-style を拾うが、**新 `bump-semver vcs tag latest --include-prerelease` は SemVer 2.0.0 parse 必須**:

- `pkf-tasks@X.Y.Z` は `@` を含むため SemVer 2.0.0 として parse 不能 → drop される
- monorepo-style tag のみが存在する状態だと exit 3 (no semver tags) → first-release 扱いに流れる → guard が gh-monitor 修正前と同じく無効化

つまり **gh-monitor で使った canonical 単純コピーは pkf-tasks では動作差が出る**。

### 修正候補

1. **prefix strip オプション追加 (bump-semver 側)**: `bump-semver vcs tag latest --strip-prefix=pkf-tasks@` のように tag prefix を剥がしてから parse。bump-semver の DR が必要、影響範囲大
2. **pkf-tasks 側で peel 自前**: `git tag | sed 's/^pkf-tasks@//' | bump-semver vcs tag latest --vcs git --raw-input` 的な経路を新設 (= bump-semver 側に raw-input mode が必要)
3. **monorepo-style tag を主から外し PLAIN `v<version>` のみを guard 対象にする**: release.yml の運用変更。コメント (line 170-173) が「PLAIN こそが本来の基本形」と明記しているので方針整合性あり、guard としては PLAIN だけ見れば十分。最も小さい修正
4. **vcs:latest-tag() を残し bump-semver を旧構文互換に戻す**: NG (DR-0020 で削除済、戻すと bump-semver 設計の後退)

候補 3 が最も筋が良さそう (= release.yml の他コメントとも整合):

```yaml
- name: Check version & create release
  run: |
    ...
    # PLAIN tag (= v<version>) を対象に guard。monorepo-style pkf-tasks@X.Y.Z は
    # 別経路で push、guard 対象外 (PLAIN の方が canonical)
    set +e
    LATEST=$(bump-semver vcs tag latest --include-prerelease --vcs git 2>/dev/null)
    LATEST_EXIT=$?
    set -e
    if [ "$LATEST_EXIT" -ne 0 ]; then
      echo "::notice::no SemVer tags yet; assuming first release."
    else
      set +e
      bump-semver compare gt "$CURRENT_VERSION" "$LATEST"
      CMP_EXIT=$?
      set -e
      case "$CMP_EXIT" in
        0) ;;
        1) echo "changed=false" >> "$GITHUB_OUTPUT"; ...; exit 0 ;;
        *) echo "::error::compare error"; exit 1 ;;
      esac
    fi
```

ただし「monorepo-style tag が guard 対象から外れる」trade-off を pkf-tasks 関係者と合意する必要あり (= 同 version の重複 release は PLAIN tag の guard で防げるが、monorepo style だけが先に作られた状態は素通りする)。

## 実害

pkf-tasks も gh-monitor と同じく VERSION が正しく増加していれば二重 release は起きないが、**「VERSION を据え置きで再 push」したときの二重 release 防止 guard が動作していない**。release workflow は緑のまま、guard 無効化に気付けない (= gh-monitor で経験したのと同じ symptom)。

## 関連

- [docs/journal/2026-06-02-sha-pinned-followup-and-release-guard-fix.md](../journal/2026-06-02-sha-pinned-followup-and-release-guard-fix.md) — gh-monitor 側の修正記録、横断調査の起点
- kawaz/bump-semver の `bump-semver vcs tag latest` 仕様 (DR-0020)
- kawaz/bump-semver/main/.github/workflows/release.yml — canonical
- kawaz/pkf-tasks/main/.github/workflows/release.yml — 本 issue の対象
