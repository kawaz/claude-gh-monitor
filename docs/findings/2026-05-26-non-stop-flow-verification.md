# non-stop モードでの修正フロー検証 (2026-05-26)

## 判明した事実

- **ローカル側の修正 → bump-semver → just push のフローは正常に回る**。1 セッションで 5 連続 push (`0.3.1` / `0.3.2` / `release.yml 追加` / `lint tighten`) を実行、全て deps チェイン (ensure-clean + ci + check-versions + check-version-bump) を通過し `jj git push --bookmark main` まで完走。
- **GitHub Actions が `degraded_performance` 状態 (https://www.githubstatus.com で確認) のとき、新規 workflow ファイルおよび既存 workflow への push trigger が一切発火しない**。`gh workflow run` での dispatch も HTTP 500 で失敗する。`gh workflow list` は workflow を active と表示するが、`gh run list --workflow=<id>` で run は空配列が返る。
- **bump-semver `compare gt` の戻り値 contract**: `0` = ターゲット > 比較対象、`1` = ターゲット ≤ 比較対象、`2` = 比較対象が空 (tag なし、初回 release 想定)。これを release.yml で初回 release 判定に使える ([kawaz/bump-semver の release.yml 参照](https://github.com/kawaz/bump-semver/blob/main/.github/workflows/release.yml))。
- **`actionlint` は justfile の `lint` レシピに追加すると、ローカル開発時点で workflow の SC2005 などを未然に検出できる**。今回 `bun pm bin -g >> $GITHUB_PATH` を `echo "$(...)" >> $GITHUB_PATH` から修正したのは actionlint 経由の検出による。
- **PostToolUse hook (post_tool_use.sh) の URL パース regex はホスト前置を anchor で縛る必要がある**。当初 `github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$` だと `https://attacker.com/github.com/hacker/...` のような中間詐称を accept していた。修正後の regex `^(https?://|ssh://(git@)?|git@)github\.com[:/]...` は正常 5 種を accept、攻撃 4 種 (詐称 / subdomain / 経路詐称 / 改行注入) を全 reject することを確認。
- **quote_value() のエスケープ順序**: backslash を最初に escape し、その後に double quote、最後に改行。順序を逆にすると `\` の二重エスケープが壊れる。
- **`watch-workflow.sh` の `known_state` GC**: 各 poll で TSV に登場した run_id 集合を作って、known_state から不在分を `unset` で落とすと、`per_page=100` から押し出された run のメモリ蓄積を防げる (理論上の改善、kawaz の個人プロジェクト規模では実害なし)。

## 実用的な示唆 / ベストプラクティス

- **GitHub Actions degraded を疑う**: workflow ファイルは remote に届いていて `gh workflow list` で active なのに run が動かない場合、`https://www.githubstatus.com/api/v2/components.json` を `jq '.components[] | select(.name | test("Actions"; "i"))'` で確認すると 30 秒で原因特定できる。これがフロー停止の典型原因。
- **non-stop モードでは外部依存検証を待ち合わせない**: GitHub Actions のような外部サービスの結果を必須にすると、サービス障害でフロー全体が止まる。「ローカル側のフロー成立確認」と「リモート CI/CD 結果確認」を別 task として分離し、後者は復旧時にまとめて確認する設計が筋。
- **複数 push を立て続けに行うときの bookmark 移動**: `jj git push --bookmark main` は `bookmark main -r @-` を経由するため、push する前に `jj new` で @ を空にしておくのが必須 (= `ensure-clean` deps が working copy の empty を要求)。
- **kawaz/* 標準: tag は workflow が打つ**。`release-flow-awareness.md` の「人もエージェントも tag を手動で打たない」方針が `release.yml` の必要性と直結。本リポは v0.3.2 まで tag なしのまま push 完了したが、これは「自動化整備中の暫定状態」として CHANGELOG で経緯を追える状態を維持。

## 検証の詳細

### 実施した push の系譜

```
main (= origin) の祖先: 0.2.0 (3df06f8d, [✓])
↓
@---: docs(decisions): DR-0001/0002/0003 (tlmnwmwn 041f53a8)
@--:  feat(watch-workflow): ... (05bb11a5)
@-:   chore(release): bump to 0.3.0 (21c91f28) ← 前セッション push 済み

# 今セッション開始
↓
chore(ci): adopt kawaz/* 横断ルール (c280ba27)
docs: split README/DESIGN into ja/en (d4ac0b50)
docs(issue): remove resolved migration issues (5bbdac7d)
chore(release): bump to 0.3.1 (47ed8b3f) ← 0.3.1 push
fix(security): harden URL parsing ... (184637e0 → dc7a963)
chore(release): bump to 0.3.2 (105ec319 → 3100b54a) ← 0.3.2 push
ci: add release.yml (64b912f6 → 44bc9595) ← release.yml push
ci: tighten lint (7049f138 → e84d6681) ← lint tighten push
```

### GitHub Actions 不発火の検証

```bash
# 直近 5 commits は全て main に届いている
$ gh api 'repos/kawaz/claude-gh-monitor/commits?per_page=5&sha=main' --jq '.[] | "\(.sha[0:7])\t\(.commit.message | split("\n")[0])"'
44bc959  ci: add release.yml (auto tag + GH Release on plugin.json version bump)
3100b54  chore(release): bump to 0.3.2
dc7a963  fix(security): harden URL parsing + quote_value + GHA permissions + known_state GC
47ed8b3  chore(release): bump to 0.3.1
025115b  docs(issue): remove resolved migration issues

# それぞれの workflow runs は 0 件
$ gh api 'repos/kawaz/claude-gh-monitor/actions/runs?head_sha=47ed8b3f72e1' --jq '.total_count'
0
$ gh api 'repos/kawaz/claude-gh-monitor/actions/runs?head_sha=3100b54ad0ec01db317b0b4f0e213c8f1f9d04b9' --jq '.total_count'
0

# workflow_dispatch も HTTP 500
$ gh workflow run ci.yml --repo kawaz/claude-gh-monitor
could not create workflow dispatch event: HTTP 500: Failed to run workflow dispatch

# GitHub Status: Actions が degraded
$ curl -s https://www.githubstatus.com/api/v2/components.json | jq '.components[] | select(.name | test("Actions"; "i"))'
{ "name": "Actions", "status": "degraded_performance" }
```

### URL パース regex の検証 (post_tool_use.sh)

| 入力 URL | 旧 regex 判定 | 新 regex 判定 |
|---|---|---|
| `https://github.com/kawaz/claude-gh-monitor.git` | `kawaz/claude-gh-monitor` ✓ | `kawaz/claude-gh-monitor` ✓ |
| `git@github.com:kawaz/claude-gh-monitor.git` | `kawaz/claude-gh-monitor` ✓ | `kawaz/claude-gh-monitor` ✓ |
| `ssh://git@github.com/kawaz/...` | ✓ | ✓ |
| `http://github.com/kawaz/...` | ✓ | ✓ |
| `https://attacker.com/github.com/hacker/malicious.git` | **`hacker/malicious` (FALSE ACCEPT)** | rejected ✓ |
| `https://evilgithub.com/hacker/malicious` | rejected | rejected ✓ |
| `https://example.com/path/github.com/hacker/...` | **FALSE ACCEPT** | rejected ✓ |
| `https://github.com/kawaz/repo%0Aevil/repo` | rejected (改行で末尾外れ) | rejected ✓ |

### quote_value() のエスケープ検証

| 入力 | 出力 | 検証点 |
|---|---|---|
| `plain` | `plain` | no special: 素のまま |
| `two words` | `"two words"` | space: quote |
| `has "quote"` | `"has \"quote\""` | quote escape |
| `C:\path\to\file` | `"C:\\path\\to\\file"` | backslash escape (新規対応) |
| `line1\nline2` (改行) | `"line1\nline2"` | newline escape (新規対応) |
| `has "quote" and\backslash\nand\nnewline` | `"has \"quote\" and\\backslash\nand\nnewline"` | 混在: backslash → quote → newline の順 |
| `` (空) | `""` | 空文字: 空 quote |

### 復旧後の検証 TODO

GitHub Actions 復旧後に確認:

1. `gh run list --repo kawaz/claude-gh-monitor --limit 10` で 0.3.1 ~ lint tighten の 4 push 分の CI run が遅延で実行されるか、それとも skip されたままか
2. CI workflow (`ci.yml`) が 4 run 分流れる場合、いずれも success で完走するか
3. Release workflow (`release.yml`) は 0.3.1 / 0.3.2 の plugin.json 変更を遡って trigger するか (= 通常は遡らない、`release.yml` 追加時点の commit `44bc9595` でのみ trigger 判定される)。trigger されない場合、次の bump (0.3.3+) で初めて release が作られる
4. watch-workflow Monitor (task `bk7ndcaw3`) が CI 完了時に `[run:change] workflow:CI id:... status:success` を emit するか

## 残課題

- DR-0004 として「emit format の最終確定 ([scope:action] + severity 二系統)」を起票するか判断 (今回 `~/.claude` のメモではなく実装＋ DR-0003 追記で済ませている。本格的に独立 DR にするかは設計判断)
- release.yml の初回動作確認 (次の bump 時)
- Claude Code plugin marketplace の install 経路と tag の関係を再確認 (tag が無くても plugin install できているのは branch HEAD 参照のため? それとも特定 tag フォーマットを期待?)
