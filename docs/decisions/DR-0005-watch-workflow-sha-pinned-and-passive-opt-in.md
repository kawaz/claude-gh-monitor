# DR-0005: watch-workflow に SHA-pinned モード追加 + Passive モード明示オプトイン化

- ステータス: Accepted
- 日付: 2026-06-02
- 関連: [DR-0003](./DR-0003-watch-workflow-persistent-per-repo.md) (本 DR で適用範囲を Passive モードに限定と再解釈), [DR-0004](./DR-0004-suppress-self-originated-events.md), [docs/issue/2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md](../issue/2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md)

## 文脈

DR-0003 で「repo 単位 1 本常駐」を確立したが、運用してみると以下のパターンで CI watch が積み上がり、結果的に GH API の RateLimit に引っかかる事案が頻発した:

- 親エージェントが複数のサブエージェントを並列起動 → 各サブエージェントがそれぞれ `watch-workflow` Monitor を起動 → 同じ repo に対して N 個の poller が走る (= 同セッション内の重複は DR-0003 で防げるが、**別セッション間で重複している軸**を捕まえていなかった)
- ほぼ完了状態のサブエージェントが Monitor を抱えたまま放置される → 不要な poll が継続
- main コンテキストに同一イベントの通知が N 重で届く

サブエージェント起因のスケールは DR-0003 のスコープ外。各セッションが独立に Monitor を抱えてよいが、それが N 並列するとサーバ側に効いてしまう。

## 決定

`watch-workflow.sh` を **起動 mode 必須**の 2 モード構成にする:

### モード 1: SHA-pinned (推奨、自分の push 用)

```
watch-workflow.sh --sha <SHA> [--grace=60s] [--timeout=24h] <OWNER/REPO>
```

- 指定 SHA のチェックが全 terminal state、かつ「最後に新規 matching run または state transition を観測してから grace 期間 (デフォルト 60s) 経過」で **自走 exit**
- `--grace` の役割: late-arriving run / `workflow_run` cascade / 後追い dispatch の救済
- re-run policy: **監視中**の re-run はそのまま追う / **自然 exit 後**の再実行は対象外
- 同 repo の SHA 違い並列起動を許容 (= 案 B、自然 exit するので積み上がらない)
- 安全 timeout (デフォルト 24h) で queue 詰まり等の無限待ちを救済

### モード 2: Passive (明示的オプトイン)

```
watch-workflow.sh --passive [--max-interval=10m] [--timeout=24h] <OWNER/REPO>
```

- `--passive` flag **必須**。明示的オプトイン
- idle backoff: 初期 30s → 指数的 (×1.5) に伸ばす、`--max-interval` 上限 (デフォルト 10m)
- reset trigger: workflow run の新規発火 / 既存 run の state 遷移
- `--timeout` で自走 exit (デフォルト 24h)
- DR-0003 の「repo 単位常駐 1 本」ルールは **Passive モードのみに限定** (本 DR で再解釈)

### 起動 mode 必須化 (誤起動の事前 guard)

- `--sha` も `--passive` も無い起動は exit 2 (エラー終了)
- stderr に `[ERROR] mode required: --sha <SHA> (recommended for own work) or --passive (repo-wide watch).`
- WARN ではなく **事前 guard** にする (= WARN は起動後にしか出ないので「気付いた時には既に走っている」を防げない)

## 理由

### 1. SHA-pinned の自走 exit が「停止し忘れ」を構造的に排除

エージェントの規律に「いらなくなったら止める」を委ねると、サブエージェントが死ぬ / 放置されるたびに Monitor が残る。SHA-pinned は「terminal + grace で自然 exit」なので、停止責任が **仕組み側**に移る。

### 2. grace window が late-arriving / cascade を救済

「terminal 直後 exit」の素朴な実装だと:
- SHA push 直後、最初の run が API に現れる前に poll → terminal な run が 0 個 = 「全部 terminal」と誤判定して即 exit
- `on.workflow_run` cascade で親 run の completion 後に走る子 run を見逃す
- 監視中に手動 dispatch で同一 SHA を追加した run を見逃す

これらを「最後の新規 event から grace 期間 (60s) 経過してから exit」で吸収する。grace 内に新 event が来れば grace が再起動する。

### 3. Passive `--passive` 必須化が誤起動を事前 guard

`--sha` 省略時に WARN で済ませる案も検討したが、WARN は起動後にしか emit されないため、エージェントが脊髄反射で起動してしまった後では遅い。CLI レベルで mode 必須にすれば **起動自体を拒否**できる。

### 4. SHA-pinned 並列許可 (案 B) の正当化

同 repo の SHA 違いに新 push が来たとき:

- 案 A: 旧 SHA Monitor を TaskStop して新規起動
  - 利点: 常に 1 本
  - 欠点: 連続 push 時に「直前 push の CI も並行で見届けたい」需要を潰す
- **案 B: 並列許可、自然 exit 任せ (採用)**
  - 利点: 連続 push の並行追跡が可能、過去 push の CI を妨げない
  - 欠点: 一時的に N 並列 (= 各 SHA 完了まで)、ただし数分〜10 数分で解消

SHA-pinned が自然 exit する性質上、案 B でも積み上がりは一時的。RateLimit 抑制は将来の共有 cache 層で根治する方針。

### 5. DR-0003 を Passive 限定と再解釈

DR-0003 の文字面は「repo 単位 1 本」だが、理由の中心は「push のたびに exit しない Monitor が増殖し続けることの回避」。SHA-pinned は「増えるが自然 exit する」性質なので、DR-0003 の精神 (= 並列を許容しつつ常駐ゴミを残さない) に整合する。本 DR で:

- DR-0003 の「1 本」ルール → **Passive モードのみに limit**
- SHA-pinned は **並列許可**
- Passive と SHA-pinned の **同居可**: description が異なるため重複起動防止ロジックに干渉しない

と再解釈する。

### 6. 不採用案

#### 不採用 a: SHA 省略時 WARN で起動 (passive にフォールバック)

- WARN は起動後にしか出ないため、誤起動の構造的防止にならない
- エージェントが「とりあえず起動」しがちな運用実態と相性が悪い
- → 明示オプトイン (`--passive` 必須化) に置き換え

#### 不採用 b: 案 A (新 push で旧 SHA Monitor を TaskStop)

- 「連続 push の CI を並行追跡したい」需要を潰す
- TaskStop 操作の責任分界が複雑化 (誰が止めるか)
- → 案 B (並列許可、自然 exit) を採用

#### 不採用 c: terminal 直後 exit (grace なし)

- late-arriving run / `workflow_run` cascade を取りこぼす (codex review #1)
- → grace window 必須化

## 影響

### 互換性

- 旧コマンド `watch-workflow.sh <OWNER/REPO>` は exit 2 (mode 必須エラー) で起動失敗
- 既存 `hooks/post_tool_use.sh` は本 DR と同時に SHA-pinned 起動に更新 (= 移行時の hook 互換性は同コミットで揃える)
- 既存 test (`tests/run-tests.sh`) は `--passive` を付ける形で更新

### 設定値のデフォルト

| パラメータ | デフォルト | 上書き |
|---|---|---|
| `--grace` (SHA-pinned) | 60s | CLI |
| `--max-interval` (Passive) | 10m | CLI |
| `--timeout` (両モード) | 24h | CLI |
| 初期 interval (両モード) | 30s | `WATCH_WORKFLOW_INTERVAL` 環境変数 (test 用 override) |

## 将来の余地 (本 DR では決めない)

- **共有 cache 層**: 同 repo を見る並列セッションが N あっても effective な GH API 呼び回数を 1 セッション分に抑える。`XDG_CACHE_HOME/gh-monitor/api-cache/` + `XDG_STATE_HOME/gh-monitor/sessions/` + single-flight fetcher。詳細は [docs/issue/2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md](../issue/2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md) の「将来 issue」セクションを参照
- **ping reset**: 外部からの「いま見たい」シグナルで passive interval を強制 reset。共有 cache 層と一緒に検討

## 関連

- DR-0001: 改名 + スコープ拡大 (本 DR の上位)
- DR-0002: hook 出力最小化
- DR-0003: 本 DR で **Passive モードに limit** と再解釈
- DR-0004: self filter (workflow run は対象外、本 DR で変更なし)
- 実装: `scripts/watch-workflow.sh`, `hooks/post_tool_use.sh`, `skills/watch-workflow/SKILL.md`
- 議論経緯: `docs/issue/2026-06-01-watch-workflow-sha-pinned-and-passive-mode.md`
