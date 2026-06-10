# Claude Code Plugin: gh-monitor

## 概要

GitHub の非同期イベント（PR の状態変化 + GitHub Actions workflow run）を Claude Code の Monitor ツール経由で低コンテキストに通知する。

実装機能:

- **watch-pr**: ブランチに紐づく GitHub PR の状態変化（コメント / レビュー / CI / マージ）。SessionStart hook で PR を検出して skill 起動を促す
- **watch-workflow**: GitHub Actions workflow run の start / success / failure 等。PostToolUse hook で push を検出して skill 起動を促す（[DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md)）

## 3-layer 構造

| Layer | watch-pr | watch-workflow |
|-------|----------|----------------|
| Hook | `hooks/hooks.json` + `hooks/session_start.sh` | `hooks/hooks.json` + `hooks/post_tool_use.sh` |
| Skill | `skills/watch-pr/SKILL.md` | `skills/watch-workflow/SKILL.md` |
| Scripts | `scripts/watch-pr.sh` / `scripts/detect-pr.sh` | `scripts/watch-workflow.sh` |

## 設計原則

- **Hook は最小指示だけ、Monitor 起動は Claude の仕事**: hook で直接常駐プロセスを起こさない（[DR-0002](docs/decisions/DR-0002-hook-minimal-output.md)）
- **変化時のみ emit**: PR 全体ハッシュと CI ハッシュを独立管理し、不要な再通知を抑止
- **watch-workflow は 2 モード必須化**（[DR-0005](docs/decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md)）:
  - **SHA-pinned** (`--sha`、第一推奨): 自分の push 用、`<repo>+<SHA>` 単位で並列許可、全 check terminal + grace で自走 exit。push のたびに増えても自然 exit
  - **Passive** (`--passive` 明示必須): repo 全体監視、`<repo>` 単位で 1 本のみ ([DR-0003](docs/decisions/DR-0003-watch-workflow-persistent-per-repo.md) は Passive モードに限定と再解釈)、idle backoff + `--timeout`
  - `--sha` も `--passive` も無い起動は exit 2 (誤起動の事前 guard)
- **軽量**: Bash + gh + jq のみ。1 プロセス ~2MB

## 開発

```bash
just validate         # プラグイン検証
just lint             # shellcheck
just version          # バージョン表示
just bump-version     # バージョンバンプ（patch）
just push             # バージョン一致 + validate + lint + push
just push-without-bump
```

### self-dogfood: Release success → plugin reload

このリポ自身を **`watch-workflow` の `--on-success` で dogfood** する運用にしている。

- `just push` 自体は plugin cache を update しない (= CI/Release 検証前の version を local に反映しないため、過去の `_local-plugin-reload` ルートは撤去済)
- post_tool_use hook が出す Monitor 起動指示に対し、**このリポでは追加で `--on-success Release 'just _on-release-success'` を付ける** こと:
  ```bash
  bash <plugin>/scripts/watch-workflow.sh --sha <SHA> \
    --on-success Release 'just _on-release-success' \
    kawaz/claude-gh-monitor
  ```
- `just _on-release-success` は `claude plugin marketplace update gh-monitor` + `claude plugin update gh-monitor@gh-monitor` + `/reload-plugins` 依頼 echo を実行
- 流れ: push → CI/Release workflow → Release success → 通知 stream に `[ACTION:Release] just _on-release-success` が emit → AI が task 実行 → ユーザに `/reload-plugins` 依頼

詳細設計は [docs/DESIGN.md](docs/DESIGN.md)、設計判断は [docs/decisions/INDEX.md](docs/decisions/INDEX.md) を参照。
