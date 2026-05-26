# CI workflow が push で trigger されていない

## 状況 (2026-05-26)

`.github/workflows/ci.yml` と `.github/workflows/release.yml` が remote に存在し、`gh api repos/.../actions/workflows` でも `state=active` だが、main への push で 1 度も trigger されていない。

```bash
# 観測
$ gh workflow list --repo kawaz/claude-gh-monitor
CI       active  283427698
Release  active  283430382

# どちらの workflow も runs が 0
$ gh api 'repos/kawaz/claude-gh-monitor/actions/workflows/283427698/runs?per_page=3'
{"total_count":0,"workflow_runs":[]}

$ gh api 'repos/kawaz/claude-gh-monitor/actions/workflows/283430382/runs?per_page=3'
{"total_count":0,"workflow_runs":[]}

# 手動 dispatch も 500
$ gh workflow run 283427698 --ref main
HTTP 500: Failed to run workflow dispatch

# Actions 自体は enabled
$ gh api repos/kawaz/claude-gh-monitor/actions/permissions
{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}

# actionlint も pass
$ actionlint .github/workflows/ci.yml .github/workflows/release.yml
(no output)
```

## 直近の push 履歴 (どれも CI が走らなかった)

- `af912e7` `chore(release): bump to 0.3.4` (2026-05-26T11:54:52Z)
- `289bb0d` `refactor(watch-workflow): drop self-actor filter (DR-0004 revised)`
- `2dadc8c` `chore(release): bump to 0.3.3`
- `f2ec6fd` `feat: suppress self-originated events by default (DR-0004)`
- `c1b1d50` `docs(readme): add Quick check + Troubleshooting + Terms; new ROADMAP.md`
- ... (それ以前の push でも shellcheck.yml の runs だけが記録され、新 ci.yml の runs は一度もない)

`shellcheck.yml` を `ci.yml` に統合した 0.3.1 以降、`gh api actions/runs` には旧 workflow_id (264983270 = `shellcheck`) の runs しか出てこず、新 workflow_id (283427698 = `CI`) の runs が一度も登録されていない。

## 可能性

1. GitHub UI 側の Settings → Actions で何らかの制限が新規 workflow にだけ effective
2. push event の actor (`kawaz`) が ruleset / branch protection で actions trigger を拒否されている
3. GitHub 内部の workflow registration が壊れている (手動 dispatch も 500 なので、GitHub UI で workflow を一度 disable → enable する救済策が効くかもしれない)

## kawaz 対応依頼

ブラウザで以下を確認 (CLI からは到達できない):

1. https://github.com/kawaz/claude-gh-monitor/actions → 左サイドバーの "CI" / "Release" workflow を選択し、各 workflow の上部に "Enable workflow" ボタンがあれば押す
2. https://github.com/kawaz/claude-gh-monitor/settings/actions → "Actions permissions" / "Workflow permissions" が想定通りか、custom ruleset で actions が抑制されていないかを確認
3. それでも直らない場合は Settings → Actions → "Disable Actions" → "Allow all actions" に切り替え直して再度 push してみる

CLI から復旧可能になり次第、watch-workflow 経由で CI 通過を観測できるようになる。

## 関連

- [docs/journal/2026-05-26-self-filter-dogfood-revision.md](../journal/2026-05-26-self-filter-dogfood-revision.md): CI が走らない状況下でも self filter の dogfood は局所完結した経緯
