# SHA-pinned follow-up (no-match-timeout / jj HEAD ズレ) + release.yml guard 修正

DR-0005 (SHA-pinned + Passive opt-in) の実機運用で出た 3 つの問題を順に解決した記録 + 同セッションで発覚した release.yml の semver guard 無効化バグの修正記録。期間: 2026-06-01〜2026-06-02。複数セッション (49bba385 = cmux-msg リポ側 / 6de0cefa = gh-monitor 側) が cmux-msg 経由で連携。

## 経緯まとめ

### Phase 1: SHA-pinned no-match-timeout (= v0.4.1)

DR-0005 (v0.4.0) で SHA-pinned モードを追加した直後の dogfood で「存在しない / 未 push の SHA を pin すると safety timeout (24h) まで張り付く」問題が顕在化。`docs/issue/2026-06-02-sha-pinned-no-match-timeout-and-wrong-repo.md` で問題 1-3 として整理:

- 問題 1: matching run が現れない → 24h 無駄常駐
- 問題 2: CLAUDE_PROJECT_DIR が別 repo を指す → 別 repo の HEAD SHA を pin
- 問題 3: jj 環境で `git rev-parse HEAD` が working-copy の empty commit を指す → 存在しない SHA を pin

問題 1 に対する `--no-match-timeout=<dur>` (default 10m) を v0.4.1 として実装。問題 2 は問題 1 で実害が緩和されるため YAGNI 保留。問題 3 は kawaz 環境 (全リポ jj) で push のたびに常時発生のため要対応 (Phase 3 へ)。

### Phase 2: release.yml の semver guard 無効化バグ (= 0.4.2 一括解決)

別セッション (49bba385) が cmux-msg 作業中に release.yml の `vcs:latest-tag()` 構文を踏み、bump-semver v0.29.0 (DR-0020) で削除済の旧構文が現行 v0.31.1 で **exit 2** を返すこと、それを release.yml の `case 文 → 「初回 release 扱い」` で握り潰すため、**二重リリース防止 semver guard が完全無効化**されていたことを発見。cmux-msg 経由で gh-monitor 担当セッション (6de0cefa) に引き継ぎ。

修正方針: canonical (`kawaz/bump-semver/main/.github/workflows/release.yml`) に揃え、`bump-semver vcs tag latest --include-prerelease --vcs git` で LATEST 取得 → exit code 別経路 → `compare gt $VERSION $LATEST` の 2 段構えへ。`--include-prerelease` は旧構文との byte-identical 互換のため明示。fetch-depth: 0 は既存維持。

実害: v0.4.0 / v0.4.1 release は VERSION が正しく増加していたため二重リリースは未発生 (guard 無効化されていただけ)。

### Phase 3: justfile vcs subcommand refactor + jj HEAD ズレ修正 (= 0.4.2 同梱)

49bba385 から「justfile も jj 直書きで bump-semver vcs サブコマンドへ移行余地あり」と詳細指摘を受領 (4 点)。canonical (`bump-semver/main/justfile`, `claude-plugin-reference/main/justfile`) に揃えて refactor:

1. `ensure-clean`: `jj log -r @ -T empty` → `bump-semver vcs is clean`
2. `check-version-bump` → `check-version-bumped`: 自前 `jj file show + jq + jj diff --summary` → `bump-semver vcs diff -q main@origin -- <paths>` + `compare gt <local> vcs:<ref>:<file>` の 2 段構え
3. `push` / `push-without-bump`: `jj bookmark set + jj git push` → `bump-semver vcs push --branch main --jj-bookmark-auto-advance`
4. recipe `bump-semver` → `bump-version` rename (コマンド名衝突解消)

`check-versions` gate (plugin.json と marketplace.json の version 整合性) は advisor 指摘で取り戻し維持 (= 多重 file 対応プロジェクトの安全網)。

問題 3 (jj HEAD ズレ) は `hooks/post_tool_use.sh` の SHA 解決を jj-aware に修正:

```bash
head_sha=""
if [ -d "$workdir/.jj" ] && command -v jj >/dev/null 2>&1; then
    head_sha=$(jj -R "$workdir" log -r 'latest(::@ & ~empty())' --no-graph -T 'commit_id' 2>/dev/null | head -1 || true)
fi
if [ -z "$head_sha" ]; then
    head_sha=$(git -C "$workdir" rev-parse HEAD 2>/dev/null || true)
fi
```

`@` が empty → `@-` を返す (= just push / jj bookmark set main -r @- フローの push 対象と一致)、`@` 自身が non-empty → `@` を返す (= jj bookmark set main -r @ で push されるケースと一致)、jj 不在 / 非 jj リポは従来通り `git rev-parse HEAD` で fallback。

## ハマり所と気付き

- **release.yml の guard 無効化は CI 緑のままだった**: workflow が success を返すこと ≠ guard が機能していること。「success のときに正しい挙動か」を別途検証する必要がある (= `empirical-verification.md` の典型例)。発見経路は別セッション dogfood で初めて exit code を観察した結果
- **canonical 統一の威力**: bump-semver の `vcs:` 抽象化を 3 リポ (bump-semver / claude-plugin-reference / gh-monitor) で揃えることで、jj/git 透過化を justfile / release.yml の両方で同じ流儀に統一。dogfood も 1 リポで効くと他リポでも横展開しやすい
- **multi-session 協調**: cmux-msg を介して別セッションから「critical バグ」「役割分担」「詳細実装提案」を受け取る運用が機能。bookmark 衝突を「役割分担明示」で回避できた
- **jj HEAD ズレは latent**: passive モードでは「間違った repo 全体を見る」だけで実害が薄かった (idle backoff で吸収)。SHA-pinned で「存在しない SHA を pin して 24h 常駐」に化け、no-match-timeout の必要性が浮上 → 問題 3 の根治へつながった

## 残課題 (open)

- 問題 2 (= `CLAUDE_PROJECT_DIR` 別 repo 誤検出) の根治: 問題 1 + 問題 3 で十分実害は小さくなったため引き続き YAGNI 保留。将来 hook が push コマンド文字列を解析して実 repo を推定する余地あり
- bot 連投 / CI 中間遷移の suppress (`docs/issue/2026-05-26-suppress-noise-followups.md`): 実害観測待ち
- 共有 cache 層 (`docs/issue/2026-06-02-shared-cache-layer.md`): DR-0005 の次フェーズ、設計案段階

## 関連

- DR-0005: SHA-pinned + Passive opt-in 化
- DR-0003: watch-workflow の repo 単位常駐 (= Passive モード限定と再解釈)
- bump-semver DR-0020: PR-Tag-Latest (`vcs tag latest` 導入、`vcs:latest-tag()` 削除)
- 元 issue (削除済): `docs/issue/2026-06-02-sha-pinned-no-match-timeout-and-wrong-repo.md` — 問題 1+3 解決済、問題 2 YAGNI 保留として本 journal に集約
