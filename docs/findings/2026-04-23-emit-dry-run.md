# pr-monitor.sh の emit 形式 dry-run

## 判明した事実

- `gh pr view --json state,mergedAt,comments,reviews,statusCheckRollup` の出力を
  jq で加工した結果、DESIGN.md §4 で規定した行頭パターンが想定通り生成される
- 本文改行は `gsub("\n"; " ")` で空白に統一される（Monitor 1行=1通知の前提を守れる）
- `reviews[].submittedAt` が null の場合は `select(.submittedAt != null)` で除外され、誤通知しない
- CI の conclusion が無い場合（pending 中など）は `status` にフォールバックする

## 実用的な示唆

- 現行 pr-monitor.sh は仕様通りの emit を出せる。実運用の PR にそのまま投入可能
- 将来 `check_run` の URL までリンクしたい場合は jq 展開を拡張するだけで済む（構造は保てている）
- 既存 antenna セッション側の Monitor 出力は、本セッションから直接観察することができない（Claude Code の Monitor 機構はセッション境界を跨がないため）。代わりに本 dry-run で emit 仕様を確定させた

## 検証の詳細

### 入力サンプル

```json
{
  "state": "OPEN",
  "mergedAt": null,
  "comments": [
    {"createdAt": "2026-04-23T09:00:00Z", "author": {"login": "shintaroino"}, "body": "LGTM with a small note about the regex."},
    {"createdAt": "2026-04-23T10:00:00Z", "author": {"login": "kawaz"},       "body": "fixed."}
  ],
  "reviews": [
    {"state": "APPROVED", "author": {"login": "shintaroino"}, "submittedAt": "2026-04-23T10:30:00Z"}
  ],
  "statusCheckRollup": [
    {"name": "Test",                    "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"name": "Detect parallel changes", "status": "COMPLETED", "conclusion": "FAILURE"}
  ]
}
```

`last_check_time = 2026-04-23T09:30:00Z` として pr-monitor.sh の jq 部を個別実行した。

### 出力

```
[COMMENT by kawaz] fixed.
[REVIEW APPROVED by shintaroino]
[CI] Test=SUCCESS, Detect parallel changes=FAILURE
```

期待通り:
- `createdAt` が閾値より古い shintaroino の初コメントは除外されている（既出扱い）
- 新規コメントは 1 件のみ正しく抽出
- CI は全 check の現状がまとめて 1 行で出ている

### antenna #2108 の観察について

antenna セッションで別途稼働中の Monitor（Task ID: bzrlv2xnb）からの emit は、本セッションからは直接取得する手段が無い:

- Claude Code の Monitor ツールは自セッションにスコープされる（`TaskList` も自セッションのみ）
- cmux-msg 機構もセッション間での Monitor ストリーム共有は想定外

よって実運用検証は antenna セッション側で emit 行をスクリーンショット/ログ化して手動フィードバックするしかない。現状はその手動フィードバックが無いので、DESIGN.md §5-(F) は「本リポ公開後、別途実運用セッションで継続検証」として未完了マークに留める。
