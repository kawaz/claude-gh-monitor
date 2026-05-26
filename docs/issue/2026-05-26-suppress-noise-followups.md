# self filter の後続: bot 連投・CI 中間遷移・self-merge silent

DR-0004 (self filter) を入れたあとに残るノイズ系の follow-up メモ。実害が出てから着手判断する。

## 1. CI 中間遷移 (`queued` / `in_progress`) の suppress

### 現状

`scripts/watch-pr.sh` の `[ci:change]` と `scripts/watch-workflow.sh` の `[run:change]` は **状態変化のたびに emit** する。`queued` → `in_progress` → `success` のように 1 check / 1 run につき複数行流れることがあり、特に多数 check の PR や matrix build で行数が増える。

### 案

「終端状態 (`success` / `failure` / `cancelled` / `timed_out` / `skipped` / `action_required` / `neutral` / `stale` / `startup_failure`) になった瞬間のみ emit」というモードを追加。`in_progress` 単発の通知は無くなる代わりに、長時間 stuck している check を察知しにくくなるトレードオフがある。

### 設計の論点

- watch-pr の `[ci:change]` と watch-workflow の `[run:change]` で別個に分けて on/off するか、共通の env var で揃えるか
- 「いつまでも `in_progress` のまま」を別 emit (`[ci:stuck]` like) で救うか

## 2. bot 連投 (codecov / dependabot / etc) の集約

### 現状

codecov コメントや GitHub Actions の post-PR コメントは、同一 bot が 1 PR に対して短時間に何度も coverage report / status summary を更新するケースがある。`[comment:add]` がそのたび emit されると Claude の通知履歴が膨らむ。

### 案

- 同 author の連続 emit を「直前から N 秒以内なら束ねる」または「内容ハッシュが変わらなければ suppress」
- bot 判定: GitHub API の `.author.__typename` が `Bot` の場合のみ対象にする
- いずれも実装が重くなるので、本当にうるさい bot が観測されてから対応する

### 既知のうるさい bot 候補

- `codecov[bot]`
- `dependabot[bot]` (security PR の脆弱性詳細を delta 更新する)
- 各種 deploy preview bot

## 3. self-merge 後の `[pr:merge]` を完全 silent

### 現状

DR-0004 で self-merge の `[pr:merge]` は emit suppress するが、watcher 自体は exit する。Monitor タスクの完了通知が Claude 側に届くので、watcher が止まったこと自体は気付ける。

### 検討事項

- Monitor タスクが「完了通知」を出すかは Claude Code 側の挙動に依存。仮に「Monitor 完了 = 1 通知」がデフォルトで出るなら、self-merge も結局 1 行ノイズが出ることになる
- 必要なら watcher を `exit 0` ではなく Monitor が黙って終わる exit code に変える等の対応を検討

## 関連

- [DR-0004](../decisions/DR-0004-suppress-self-originated-events.md): self filter 本体
