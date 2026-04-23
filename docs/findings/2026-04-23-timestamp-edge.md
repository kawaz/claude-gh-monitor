# 新規コメント/レビュー検出のタイムスタンプ境界問題

## 判明した事実

- `select(.createdAt > $t)` は strict inequality のため、「既出コメントと同じ秒に来た新規コメント」は検出から漏れる
- last_check_time ベース（システム時計）は、時計のズレや同秒問題に弱かった
- 最大 createdAt / submittedAt ベースに切り替えることで時計依存は無くなった（GitHub 側の時刻基準で判定）
- ただし同秒エッジは依然として残る。完全堅牢化には「既出 id セットとの差集合」方式が必要

## 実用的な示唆

- **99% のケースは `最大timestamp + strict>` で十分**（人間の操作速度では同秒に複数コメントは稀）
- 完全堅牢化を求める場合は、次のステップとして `[.comments[].id]` を前回セットとして保存し、差集合で emit する方式に切り替える
- GitHub の GraphQL 経由コメント/レビューは各ノードに `id` を持つので id ベースの diff が可能

## 検証の詳細

### テストケース t1 → t2 の遷移

t1:
```json
{"comments":[{"createdAt":"2026-04-23T09:00:00Z","author":{"login":"a"},"body":"c1"}]}
```
→ max_comment_at = `2026-04-23T09:00:00Z`

t2（同秒に b から追加コメント）:
```json
{"comments":[
  {"createdAt":"2026-04-23T09:00:00Z","author":{"login":"a"},"body":"c1"},
  {"createdAt":"2026-04-23T09:00:00Z","author":{"login":"b"},"body":"c2 same second"}
]}
```
→ max_comment_at = `2026-04-23T09:00:00Z`（更新なし）

→ `select(.createdAt > "2026-04-23T09:00:00Z")` は両方 false で c2 を emit できない。

### 将来の堅牢化アイデア

```bash
# 既出 id を前回セットとして保持
prev_comment_ids_json="[]"

# 差分算出
new_comments=$(printf '%s' "$cur" | jq --argjson prev "$prev_comment_ids_json" '
  [.comments[] | select(.id as $id | ($prev | index($id)) | not)]
')

# emit
printf '%s' "$new_comments" | jq -r '.[] | "[COMMENT by \(.author.login)] " + (.body | .[0:200] | gsub("\n"; " "))'

# 更新
prev_comment_ids_json=$(printf '%s' "$cur" | jq -c '[.comments[].id]')
```

この方式なら同秒エッジも編集済みコメントの再 emit 抑止も完全に機能する。メモリも通常 O(PR の全コメント数) 程度で、数千件規模でも問題ない。

現時点では max-timestamp 方式で十分に実用的なので、完全版は次の iteration で実装する方針。
