# watch-workflow に `--on-success` / `--on-failure` action hook を追加

## 背景

bump-semver の release 運用で「`just push` → `gh-monitor:watch-workflow` 起動 → Release workflow 成功通知 → AI が `brew upgrade kawaz/tap/<pkg>` を実行」のフローを `@echo` hint で誘導していたが、AI が echo hint を流し見しがちで brew upgrade が抜けることが多発。

watch-workflow の event 通知は AI が必ず読むことが session 経験で判明している。**通知 event 内に明示的な action item を embed できれば catch 率が大幅に上がる**。

## 提案

watch-workflow.sh に **`--on-success <key> <msg>` / `--on-failure <key> <msg>` option** を追加 (= repeatable + append)。

特定 workflow の状態遷移時に event line に追加で ACTION 行を emit する。

### 利用例

```bash
# bump-semver 単純ケース
watch-workflow.sh --sha XXX \
  --on-success Release "brew upgrade kawaz/tap/bump-semver" \
  kawaz/bump-semver

# 複数 workflow を持つ project
watch-workflow.sh --sha XXX \
  --on-success Release "brew upgrade kawaz/tap/myproj" \
  --on-success Deploy "echo prod deployed" \
  --on-failure Release "say 'リリース失敗確認お願いします'" \
  kawaz/myproj
```

### emit される event

```
[run:change] workflow:Release id:XXX status:success commit:abc branch:main user:kawaz event:push
[ACTION:Release] brew upgrade kawaz/tap/bump-semver
```

failure 時:
```
[run:change] workflow:Release id:XXX status:failure ...
[ACTION:Release] say 'リリース失敗確認お願いします'
```

## key の matching 軸

GitHub Actions API response には以下 2 つの field がある:

```json
{
  "workflow_runs": [{
    "name": "Release",                       // YAML name: field
    "path": ".github/workflows/release.yml"  // workflow file path
  }]
}
```

**両方の matching を許す** ことで user の mental model に合わせる:

| key 形式 | 例 | matching 対象 |
|---|---|---|
| YAML name | `Release` | `.name` 完全一致 |
| basename | `release.yml` | `basename(.path)` 完全一致 |
| filename (no ext) | `release` | `basename(.path)` から `.yml`/`.yaml` 剥がして完全一致 |

複数項目とマッチした場合 (= ambiguous) は warning emit + 全部に action 適用 or skip、要設計判断。

## 実装変更点

1. **jq クエリに `path` 追加** (= 現在は `.name` のみ取得、`(.path // "")` も加える)
2. **arg parser に `--on-success` / `--on-failure` 追加** (= key + msg の 2 引数、repeatable)
3. **emit_run の後に action 判定 + ACTION line emit**:
   - status が success/failure に遷移したとき、登録済 on-success / on-failure 設定を引いて key matching
   - matching したら `[ACTION:<key>] <msg>` を stdout に emit
4. **passive mode でも同じ動作** (= sha-pinned 専用にはしない、複数 release を観測する CI でも有用)

## 互換性

- 既存呼び出し (= option 無し) は完全に従来通り動作
- option を 1 つも指定しなくても error にしない (= 無 effect)

## 期待効果

- AI が action item を見落とす確率を低減 (= echo hint 流し見問題の根本解決)
- justfile push hint を「complete command」として書ける (= monitor 起動 + 成功時 action が 1 行で記述可能)
- kawaz/* 他プロジェクトでも同じパターン適用可能 (= homebrew tap 経由配布 project、deploy 通知が要る project 等)

## 関連 context

- bump-semver 2026-06-10 release シリーズ (v0.32.0 - v0.33.7) で 8 回くらい release を出したが、AI が brew upgrade を一度も実行しなかった。session 終盤に kawaz が「ローカルも最新?」と気付いて手動 upgrade
- echo hint より AI 視野に強制的に入る notification 経路が必要、という reasoning から本提案に到達
- watch-workflow.sh は SHA-pinned mode + passive mode を持つが、本機能は両 mode 共通の挙動として追加

## phase

- Phase 1: `--on-success NAME MSG` (= 最小、bump-semver 1 用途で価値十分)
- Phase 2: `--on-failure NAME MSG` (= 対称性、音声通知 / Slack post 等)
- Phase 3: 必要なら status の細分化 (`--on Status=cancelled` 等)
