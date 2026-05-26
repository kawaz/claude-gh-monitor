# ROADMAP

将来検討項目。優先度は流動的、`docs/issue/` に正式化してから着手する想定。

## 短期 (1-2 セッション)

- **release.yml の初回動作確認**: 次の `plugin.json` bump で release.yml が trigger され、`gh release create v<X.Y.Z>` まで完走するか確認。過去 tag (v0.2.0 / v0.3.0-0.3.2) は未補完のため初回 release は v0.3.3+ になる見込み (`release-flow-awareness.md` 方針)。
- **GitHub Actions 復旧後の CI 検証**: 2026-05-26 のサービス障害中に push した 4 change 分の CI が遡って実行されるか、それとも skip されたままか確認。詳細は [docs/findings/2026-05-26-non-stop-flow-verification.md](findings/2026-05-26-non-stop-flow-verification.md)。

## 中期 (機能拡張)

- **`watch-workflow.sh` の filter オプション**: `--only-mine` / `--workflow <name>` / `--events <list>` の追加。チーム開発で他人 run のノイズを抑える用途。[DR-0003](decisions/DR-0003-watch-workflow-persistent-per-repo.md) の「将来の拡張余地」節参照。
- **手動起動用 invocable skill**: `/gh-monitor:watch-ci` のような明示 invoke 用 skill (現状は PostToolUse hook 経由のみ)。
- **`[CI]` 行 (watch-pr) の URL 追加**: 既に `[ci:change]` で `url:` 含めているが、`[review:submit]` でも url を含めたい。`gh pr view --json reviews` の固定 schema に url がないため、`gh api graphql` 経由が必要。
- **`watch-pr` の hash 比較 fields に reaction を含めるか**: 現状はリアクション追加で emit しない設計だが、APPROVED reaction (👍) を「軽量レビュー」として拾う選択肢。

## 長期 (運用整備)

- **pkf-tasks (Taskfile.pkl) への移行**: kawaz/* canonical (kawaz/bump-semver) が pkfire ベース。本リポは justfile 単独運用なので、移行すると `check-translations` などの kawaz 横断 task をそのまま使える。CLAUDE.md の方針更新も伴う。
- **`check-translations` 自動検証**: 上記 pkf-tasks 移行の一部。日本語版 (`*-ja.md`) が英訳版 (`*.md`) より新しい commit を持っていれば push を止める gate。
- **`engines.claude-code` の version pin**: `bun add -g @anthropic-ai/claude-code@latest` で CI 再現性が低い。plugin.json に `engines.claude-code` 制約を追加し、ci.yml で読み取る形に。

## 不採用 / 一時保留

- **過去 release の tag 補完 (v0.2.0 / v0.3.0 / v0.3.1 / v0.3.2)**: `release-flow-awareness.md` の「人もエージェントも tag を手動で打たない」方針により見送り。CHANGELOG で経緯を追える状態は維持。
- **`gh api` ページネーション対応**: 個人プロジェクト規模で `per_page=100` を超える run 件数が短期間に発生する可能性は低い。`known_state` GC は実装済み (2026-05-26)。
