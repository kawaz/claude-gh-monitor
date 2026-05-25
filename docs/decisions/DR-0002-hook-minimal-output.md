# DR-0002: hook は「状態判定 + 1 行の Monitor 起動指示」に徹する

- ステータス: Accepted
- 日付: 2026-05-25
- 関連: DR-0001 (改名 + スコープ拡大), DR-0003 (workflow-watch 常駐 Monitor), `hooks/`, `skills/`

## 文脈

`pr-monitor` の SessionStart hook は「PR を検出して Claude に skill 起動を促す」という指示を stdout に出す設計。`workflow-watch` の追加にあたり、PostToolUse hook で push を検出して同様に Monitor 起動を促す形を取りたい。

ここで注意が要るのは **hook が stdout に出した additionalContext は会話履歴の一部として残り続ける**点。

- hook が出力したテキストは、それ以降の **全ターンのリクエストに毎回入力トークンとして含まれる**
- 同じ hook が N 回発火すれば、内容が同一でも **N 個の重複テキストが履歴に積み上がる**
- プロンプトキャッシュ (Anthropic API) は prefix 一致でヒットし **課金を下げるだけ**で、コンテキストウィンドウの占有は下げない。「毎回同じ文言だから無料」にはならない

PostToolUse は push のたびに発火するため、毎回 hook が長い手順説明を出すと履歴を一方的に圧迫する。

## 決定

**hook が Claude の context に注入する文字列は可変情報のみの最小 1 行に絞る。** Monitor の poll ロジックは skill 同梱スクリプトに置き、hook は「そのスクリプトを呼ぶ Monitor を起動せよ」という短い指示だけを context に注入する。重複起動防止は **Monitor リストに同じ description が無ければ起動** という状態判定で行う。

具体イメージ (注入される文字列):

```
[gh-monitor] Monitor リストに `workflow-watch: kawaz/foo` が無ければ、
Monitor ツールで command=`workflow-watch.sh kawaz/foo`, persistent=true を起動せよ。
```

手順説明 (Monitor 引数の組み立て方、通知行の読み方、`gh` API の詳細) は **skill 側に置く**。skill は Claude が起動したときだけ読まれるため、コンテキストに乗るのは実質 1 回。

### hook 出力経路は event ごとに異なる (実装上の注意)

Claude Code hooks は event ごとに「Claude の context にどう注入されるか」の規約が違う。**plain stdout が context に注入されるのは SessionStart など一部の event のみ**。PostToolUse は plain stdout を context に注入しないため、`additionalContext` を含む JSON を stdout に返す必要がある。

| Event | Claude への context 注入経路 |
|-------|------------------------------|
| SessionStart | plain stdout がそのまま context に注入される (現 `hooks/session_start.sh` がこの方式) |
| PostToolUse | JSON の `hookSpecificOutput.additionalContext` フィールドに入れる必要がある (plain stdout は無視される) |

PostToolUse の出力例:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[gh-monitor] Monitor リストに `workflow-watch: kawaz/foo` が無ければ、Monitor ツールで command=`workflow-watch.sh kawaz/foo`, persistent=true を起動せよ。"
  }
}
```

「指示は短い 1 行」という本 DR の設計判断は変わらない。違うのはその 1 行を**どこに載せて Claude に届けるか**だけ。具体的なフィールド名・スキーマは実装時に Claude Code hooks の最新仕様を確認すること。

## 理由

1. **コンテキストウィンドウ占有の構造的圧迫を避ける**
   - 重い手順説明が hook 出力に乗ると、毎 push ごとに数百〜数千トークンが履歴に積もる
   - skill に押し込めば skill 起動時の 1 回だけで済む
2. **3-layer の責務分離を維持**
   - 現 `pr-monitor` の `hook = 指示だけ / skill = 詳細 / scripts = 実ロジック` は良い分離
   - スコープを拡大しても同じ構造を踏襲することで、機能追加のたびに hook が肥大化するのを防ぐ
3. **重複防止は description マッチで成立する**
   - Monitor の description フィールドに `<feature>: <key>` 規約 (例: `workflow-watch: kawaz/foo`, `pr-watch: kawaz/foo#123`) を入れる
   - Claude が TaskList を見て該当 description があれば起動をスキップする
   - 規約さえ守れば hook は冪等な指示を出し続けるだけでよい

## 「対応済みなら黙る」をどう実現するか (重要な訂正)

当初の検討では「hook は対応済みなら黙る」を素朴に書いたが、これは **hook 単体では実現不可** であることが codex レビューで明らかになった:

- **hook は Monitor リスト (TaskList) を見られない**
- したがって hook 自身は「すでに Monitor が立っているか」を判定できず、毎回同じ指示を出すしかない

重複防止と履歴蓄積抑制は **2 段構え** で考える:

| 段 | 仕組み | 防げるもの | 防げないもの |
|----|--------|----------|------------|
| (a) | hook は毎回 idempotent な最小指示を出す + Claude が TaskList を見て重複 Monitor 起動を回避 | 重複 Monitor 起動 | hook 出力テキストの履歴蓄積 |
| (b) | hook が session-local な状態ファイル (session_id ベースの tmp パス等) に「この repo を promote 済み」を記録し、2 回目以降は何も出力しない | 履歴蓄積も含めて両方 | — |

**初期実装は (a) のみで進める。** push 頻度は低く、各 push は別イベントなので積もりは許容範囲。(b) の採用可否は未決論点として次セッション以降で詰める。

## 不採用案

### A. hook 出力に Monitor 引数 + poll ループのシェルスクリプトを直接埋め込む

「skill 起動の 1 ステップを省ける」というメリットはあるが、push のたびに数十行のシェルスクリプト全文が履歴に積もる。コンテキスト占有が現実的でない。

### B. hook 自身が Monitor リストを直接読みに行く

hook の実行環境 (Bash) からは Claude セッション内の Monitor リストは見えない。仮に外部ファイル等で擬似的に持たせても、複数セッション間の整合や Monitor の自然終了 (タスク完了 / Claude が手動 kill) との同期コストが高すぎる。

### C. 最初から (b) (状態ファイル方式) を入れる

(a) だけで実用上は十分なので YAGNI。先に (a) で運用して履歴蓄積が実害になってから (b) を入れる方が筋が良い。

## 関連

- DR-0001: 本 DR の前提となる改名 + スコープ拡大
- DR-0003: `workflow-watch` の常駐 Monitor 設計 (description = `workflow-watch: <user/repo>`)
- `hooks/session_start.sh`: 現 `pr-monitor` の hook 実装 (改名後も同じパターンを踏襲)
