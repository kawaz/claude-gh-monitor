# SHA-pinned: no-match timeout の追加 + CLAUDE_PROJECT_DIR 誤検出の悪化

DR-0005 (= SHA-pinned モード) を実機運用して見つかった弱点。発見: 2026-06-02、claude-plugin-reference を push した際に hook が cmux-msg の未 push SHA を pin する起動指示を出した実例から。

> **Status (2026-06-02)**: **問題 1 (no-match timeout) は実装済** (= `--no-match-timeout`、デフォルト 10m、v0.4.1)。**問題 3 (jj HEAD ズレ) が未対応で優先度高** (= kawaz 全リポ jj なので push のたびに常時発生)。問題 2 (CLAUDE_PROJECT_DIR 越境誤検出) は問題 1 で実害緩和済、根治は YAGNI 保留。

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

## 問題 3: jj 環境で `git rev-parse HEAD` が empty working-copy commit を指す (= kawaz 環境では常時発生)

### 現象

`hooks/post_tool_use.sh` は push 後の対象 SHA を `git rev-parse HEAD` で解決する。しかし **jj 管理リポでは `@` (working-copy) が空の作業用 commit であることが多く、HEAD はその empty commit を指す**。実際に push されたのは `@-` (= 直前の実 commit) なので、hook は **存在しない / 無関係な SHA を pin** する。

### 重要度: 高 (= 「軽微な誤検出」ではない)

問題 2 (= 別 repo 誤検出) は越境作業時のみだが、**問題 3 は kawaz の全リポが jj 管理なので push のたびに常時発生する**。SHA-pinned hook はほぼ毎回 empty `@` の SHA を pin し、その SHA の CI run は存在しないため、no-match-timeout (10min) まで無駄 poll する。

### 実例 (2026-06-02)

cmux-msg を docs push (`just push` = `jj bookmark set main -r @-` 後に push) した直後、hook が:

```
bash .../scripts/watch-workflow.sh --sha 4ccdf841... kawaz/claude-cmux-msg
```

を起動指示。`4ccdf841` は jj の empty working-copy commit (`@`) の git SHA で、push された実 commit (`@-` = `dcf0d4d5`) ではない。`4ccdf841` の CI run は存在しないため no-match-timeout 待ちになる。

### 改善案 (= 実装すべき、YAGNI ではない)

`hooks/post_tool_use.sh` の SHA 解決を jj 対応にする:

```bash
head_sha=""
if [ -d "$workdir/.jj" ] && command -v jj >/dev/null 2>&1; then
    # @ から遡って最新の non-empty commit = 直前に作業/push した実 commit
    head_sha=$(jj -R "$workdir" log -r 'latest(::@ & ~empty())' --no-graph -T 'commit_id' 2>/dev/null | head -1 || true)
fi
if [ -z "$head_sha" ]; then
    head_sha=$(git -C "$workdir" rev-parse HEAD 2>/dev/null || true)  # 非 jj リポ fallback
fi
```

- `latest(::@ & ~empty())` = `@` の祖先で空でない最新 commit (= 通常 `@-`、push 対象)
- jj が PATH に無い / `.jj` が無ければ従来の `git rev-parse HEAD` に fallback
- `commit_id` template は git commit hash (40 hex) を返す

### 注意点 (= 実装時に詰める)

- `@` 自体が non-empty (= まだ `jj new` していない作業中) の場合、`latest(::@ & ~empty())` は `@` を返す。これは push 対象と一致するとは限らない (= cmux-msg フローは `@-` を push) が、HEAD(empty) よりは遥かに正確
- hook 実行環境の PATH に jj が含まれるか要確認 (= mise shim 等)。含まれなければ fallback で従来動作

## 推奨対応順

1. **no-match timeout 実装** (= 問題 1、最優先) — ✅ 実装済 (v0.4.1)。誤検出 (問題 2/3) の害を緩和
2. **問題 3 の jj 対応 hook 修正** — kawaz 環境では常時発生のため優先度高。実装すれば問題 2 (別 repo) でも「正しい repo の正しい SHA」を取れる確率が上がる
3. DR-0005 / DR-0003 に問題 2/3 の hook 限界を明記
4. 問題 2 の「別 repo 越境 push」根治は引き続き YAGNI (= no-match timeout + 問題 3 修正で実害が十分小さくなる)

## 関連

- [DR-0005](../decisions/DR-0005-watch-workflow-sha-pinned-and-passive-opt-in.md) — SHA-pinned モード本体
- [DR-0003](../decisions/DR-0003-watch-workflow-persistent-per-repo.md) — CLAUDE_PROJECT_DIR ベース repo 解決の既知限界
- `scripts/watch-workflow.sh` — `matching_warn_threshold` 周辺に no-match timeout を追加
- `hooks/post_tool_use.sh` — repo / SHA 解決ロジック
