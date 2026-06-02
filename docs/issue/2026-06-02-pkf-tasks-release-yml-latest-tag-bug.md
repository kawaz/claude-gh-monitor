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

## pkf-tasks 固有の懸念 → 実機検証で解消 (= canonical 単純コピーで動く)

pkf-tasks の release.yml は **monorepo-style tag** `pkf-tasks@X.Y.Z` も release 対象に含めている (release.yml の comments line 61, 170)。当初「新 `vcs tag latest` は SemVer 2.0.0 parse 必須なので `@` を含む tag は drop されるのでは」と懸念したが、**実機検証で否定された**。

### 実機検証結果 (2026-06-02、pkf-tasks/main 上で)

| 経路 | 出力 | exit |
|---|---|---|
| `bump-semver vcs tag latest --include-prerelease --vcs git` (git tag list) | `3.0.3` | 0 |
| `bump-semver vcs tag latest --source release --include-prerelease --vcs git` | `3.0.3` | 0 |
| `bump-semver vcs tag latest --source release --include-prerelease --repository kawaz/pkf-tasks` | `3.0.3` | 0 |

ローカル checkout の git tag 状況:
- PLAIN tag (`v3.0.3` / `v3.0.2`): 2 件 (= 最近の release で並行 push 開始)
- MONO tag (`pkf-tasks@X.Y.Z`): 32 件

**新 `vcs tag latest` は MONO tag も SemVer parse 成功** (= prefix `pkf-tasks@` を peel して `X.Y.Z` 部を SemVer として認識)。PLAIN tag があれば PLAIN、無くても MONO から最大を取れる。つまり gh-monitor で使った **canonical 単純コピー (`vcs tag latest` + `compare gt` の 2 段構え) でそのまま動く**。

### 修正方針 (= gh-monitor 0.4.2 と完全同一パターン)

```yaml
# 既存 tag より大きいか (二重リリース防止)
# bump-semver v0.29.0 (DR-0020) で vcs:latest-tag() 削除済 → vcs tag latest へ移行
# pkf-tasks の monorepo-style tag (pkf-tasks@X.Y.Z) も SemVer parse 成功する
# ことを 2026-06-02 実機検証済 (docs/issue/2026-06-02-pkf-tasks-release-yml-latest-tag-bug.md)
set +e
LATEST=$(bump-semver vcs tag latest --include-prerelease --vcs git 2>/dev/null)
LATEST_EXIT=$?
set -e
if [ "$LATEST_EXIT" -ne 0 ]; then
  echo "::notice::vcs tag latest exited ${LATEST_EXIT} (no SemVer tags yet); assuming first release."
else
  set +e
  bump-semver compare gt "$CURRENT_VERSION" "$LATEST"
  CMP_EXIT=$?
  set -e
  case "$CMP_EXIT" in
    0) ;;
    1) echo "changed=false" >> "$GITHUB_OUTPUT"
       echo "Version v${CURRENT_VERSION} is not greater than latest tag ${LATEST}; skipping release."
       exit 0 ;;
    *) echo "::error::Unexpected exit code from bump-semver compare: ${CMP_EXIT}"
       exit 1 ;;
  esac
fi
```

`--include-prerelease` は旧構文との byte-identical 互換のため明示 (旧実装は prerelease を含めていた)。fetch-depth: 0 は既存維持。release.yml の comments (line 61, 170) も合わせて更新 (= 旧 `vcs:latest-tag()` の言及を削除 / `vcs tag latest` で全 tag を SemVer parse する旨に変更)。

## 実害

pkf-tasks も gh-monitor と同じく VERSION が正しく増加していれば二重 release は起きないが、**「VERSION を据え置きで再 push」したときの二重 release 防止 guard が動作していない**。release workflow は緑のまま、guard 無効化に気付けない (= gh-monitor で経験したのと同じ symptom)。

## 関連

- [docs/journal/2026-06-02-sha-pinned-followup-and-release-guard-fix.md](../journal/2026-06-02-sha-pinned-followup-and-release-guard-fix.md) — gh-monitor 側の修正記録、横断調査の起点
- kawaz/bump-semver の `bump-semver vcs tag latest` 仕様 (DR-0020)
- kawaz/bump-semver/main/.github/workflows/release.yml — canonical
- kawaz/pkf-tasks/main/.github/workflows/release.yml — 本 issue の対象
