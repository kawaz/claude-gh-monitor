# SHA-pinned: no-match timeout の追加 + CLAUDE_PROJECT_DIR 誤検出の悪化

DR-0005 (= SHA-pinned モード) を実機運用して見つかった弱点。発見: 2026-06-02、claude-plugin-reference を push した際に hook が cmux-msg の未 push SHA を pin する起動指示を出した実例から。

> **Status (2026-06-02)**: **問題 1 (no-match timeout) は実装済** (= `--no-match-timeout`、デフォルト 10m)。問題 2 (CLAUDE_PROJECT_DIR 誤検出) は問題 1 の実装で実害が緩和されたため、hook 側の根治は YAGNI として保留。

## 問題 1: 存在しない SHA を pin すると 24h timeout まで無駄常駐

### 現象

SHA-pinned で起動した watch-workflow が、指定 SHA に紐づく run を 1 つも観測できないまま (= `observed_any_matching=0`) 常駐し続ける。exit 条件は `observed_any_matching=1` を前提にしているため、matching run が永遠に現れないと **safety timeout (デフォルト 24h) まで張り付く**。

`matching_warn_threshold=300s` で「no matching run for SHA」WARN は 1 回出すが、exit はしない。

### 発生経路

1. **未 push の SHA を pin**: hook が `git rev-parse HEAD` で解決した SHA がまだ remote に push されていない → CI run が存在しない
2. **誤検出 repo の SHA**: 後述の問題 2
3. **workflow 不在 repo**: そもそも Actions を持たない repo に対して起動
4. **typo / 古い SHA をユーザが手で指定**

### 改善案: no-match timeout (grace とは別パラメータ)

「起動後 N 秒 (デフォルト 10min?) 経っても matching run を 1 つも観測しなければ `[INFO] no run found for SHA <sha7> after <N>, exiting` で exit」する。

- **grace window とは別物**: grace は「terminal 集約後に late-arriving を待つ」、no-match timeout は「そもそも 1 つも現れない」を諦める
- late-arriving run の最大遅延 (= push → run 生成のラグ) より十分長く取る。GitHub Actions の run 生成は通常数秒〜十数秒なので 10min あれば十分
- 現状の `matching_warn_threshold=300s` を「WARN を出す閾値」、no-match timeout を「exit する閾値」として 2 段にする案もある (= 5min で警告、10min で exit)

### トレードオフ

- no-match timeout を短くしすぎると、API ラグが大きい状況や queue 詰まりで「これから現れる run」を取りこぼす
- 安全側に倒すなら長め (10min) + WARN 併用

## 問題 2: CLAUDE_PROJECT_DIR ベースの repo 誤検出が SHA-pinned で悪化

### 現象

`hooks/post_tool_use.sh` は push コマンドを検出すると `CLAUDE_PROJECT_DIR` の origin remote と HEAD から repo / SHA を解決する。しかし **実際に push したコマンドの対象 repo とは限らない**:

- 別 worktree / 別 repo で `git -C <path> push` した
- session の cwd (`CLAUDE_PROJECT_DIR`) と実際の push 対象が異なる (= 越境作業、複数 repo を 1 session で触る)

これは [DR-0003](../decisions/DR-0003-watch-workflow-persistent-per-repo.md) で既知の限界として記録済 (「`git -C <別repo> push` / `cd <別repo> && git push` は誤検出・取りこぼし、ブロックしない以上害は軽微」)。

### SHA-pinned 化での悪化

- **旧 (passive)**: 誤検出しても「間違った repo 全体を見る」だけ → idle backoff で薄まる、害は軽微
- **新 (SHA-pinned)**: 誤検出 repo の HEAD SHA を pin → その SHA は対象 repo に存在しない → **問題 1 と合流して 24h 無駄常駐**

### 実例 (2026-06-02)

claude-plugin-reference を push した際、`CLAUDE_PROJECT_DIR` が cmux-msg を指していたため、hook が:

```
bash .../gh-monitor/0.4.0/scripts/watch-workflow.sh --sha 08ce34b9... kawaz/claude-cmux-msg
```

を起動指示。`08ce34b9` は cmux-msg のローカル journal commit (未 push)。これを起動すると cmux-msg に存在しない SHA を 24h watch することになる。

### 改善案

問題 2 単独の根治は難しい (= hook は push コマンド文字列を解析しないと実際の対象を知れない)。現実的な緩和:

- **問題 1 の no-match timeout で救済**: 誤検出しても 10min で自動 exit するので、24h 無駄常駐は防げる (= 最も費用対効果が高い)
- (将来) hook が push コマンド文字列から `git -C <path>` / cwd を解析して実 repo を推定する。ただし複雑で誤爆も増えるため優先度低
- (将来) hook が解決した repo に対して「最近 push されたか (= remote の HEAD が local HEAD と一致するか)」を軽くチェックしてから起動指示を出す

## 推奨対応順

1. **no-match timeout 実装** (= 問題 1、最優先)。誤検出 (問題 2) の害も同時に緩和できる
2. DR-0005 の「将来の余地」or 「開いた問い」に問題 2 の hook 限界を明記
3. 問題 2 の hook 側根治は YAGNI 判断 (= no-match timeout で実害が消えるなら後回し)

## 関連

- [DR-0005](../decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md) — SHA-pinned モード本体
- [DR-0003](../decisions/DR-0003-watch-workflow-persistent-per-repo.md) — CLAUDE_PROJECT_DIR ベース repo 解決の既知限界
- `scripts/watch-workflow.sh` — `matching_warn_threshold` 周辺に no-match timeout を追加
- `hooks/post_tool_use.sh` — repo / SHA 解決ロジック
