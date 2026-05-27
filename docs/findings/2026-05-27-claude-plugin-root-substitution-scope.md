# `${CLAUDE_PLUGIN_ROOT}` の置換スコープ

## 判明した事実

Claude Code plugin の `${CLAUDE_PLUGIN_ROOT}` (および `${CLAUDE_PLUGIN_DATA}` / `${CLAUDE_PROJECT_DIR}` / `${user_config.*}`) は **plugin loader が事前にテキスト置換する経路** と **しない経路** がある。

### 置換される

- `hooks/hooks.json` の `command` フィールド
- `monitors/monitors.json` の `command` フィールド (plugin が宣言する monitor)
- `.mcp.json` / `.lsp.json` の server config
- **SKILL.md / agent 本文**（公式 docs `plugins-reference#environment-variables`: "All are substituted inline anywhere they appear in **skill content, agent content**, hook commands, monitor commands, and MCP or LSP server configs."）
- hook process / MCP・LSP subprocess の **env として export** もされる

### 置換されない

- **hook スクリプトが stdout に出す `hookSpecificOutput.additionalContext`** (Claude のコンテキストに注入されるだけのテキスト、loader を再通過しない)
- **Claude が runtime に Monitor ツールへ渡す `command` 文字列** (Bash と同じ実行経路、Claude main process の env には `CLAUDE_PLUGIN_ROOT` が存在しない)
- Claude が runtime に Bash ツールへ渡す任意の文字列

## 実用的な示唆

| 書く場所 | 推奨 |
|---|---|
| `hooks.json` の `command` | `${CLAUDE_PLUGIN_ROOT}/...` で OK (公式パターン) |
| `monitors.json` の `command` | `${CLAUDE_PLUGIN_ROOT}/...` で OK |
| SKILL.md 本文 (Claude に読ませる手順) | `${CLAUDE_PLUGIN_ROOT}/...` で OK (loader が置換) |
| hook スクリプトの additionalContext | **絶対パスに resolve してから埋める**。`$0` ベースで `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd); PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)` |
| hook 内部から script を呼ぶとき | env の `$CLAUDE_PLUGIN_ROOT` を使ってもよいが、`$0` ベースの方が手動テストでも動くので可搬性が高い |

`$0` ベースは env 依存ゼロで、`session_start.sh` 既存パターンと一貫する。

## 検証の詳細

### Monitor の substitution 実機確認

`Monitor` ツールに `command: echo "[${CLAUDE_PLUGIN_ROOT}]"` を渡して実行:

```
CLAUDE_PLUGIN_ROOT_value=[]
literal_expansion_test=[/scripts/foo.sh]
```

→ Monitor は Claude main process の env で shell expansion するだけ。`CLAUDE_PLUGIN_ROOT` は unset なので空に潰れる。

### SKILL.md の substitution 実機確認

`Skill` ツールで `gh-monitor:watch-workflow` を invoke すると、SKILL.md 本文の `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-workflow.sh ...` が:

```
bash /Users/kawaz/.claude-personal/plugins/cache/gh-monitor/gh-monitor/0.3.4/scripts/watch-workflow.sh ...
```

に置換された状態で Claude に渡されることを確認。SKILL.md 内の `${CLAUDE_PLUGIN_ROOT}` は plugin loader が解決する。

### バグ報告との対応

ユーザ報告: 「watch-workflow は `${CLAUDE_PLUGIN_ROOT}` 未解決で起動失敗 (exit 127)」

原因は `hooks/post_tool_use.sh:73` が literal `\${CLAUDE_PLUGIN_ROOT}` を additionalContext に埋めていたこと。additionalContext は置換されないので、Claude はそのまま Monitor に渡し、Monitor の shell expansion で空になり `bash /scripts/watch-workflow.sh ...` → 127。

修正は `$0` ベースで `PLUGIN_ROOT` を resolve して埋める形に変更（session_start.sh と同じパターン）。

### 公式 docs 抜粋 (`plugins-reference#environment-variables`)

> Claude Code provides three variables for referencing paths. All are substituted inline anywhere they appear in skill content, agent content, hook commands, monitor commands, and MCP or LSP server configs. All are also exported as environment variables to hook processes and MCP or LSP server subprocesses.
>
> `${CLAUDE_PLUGIN_ROOT}`: the absolute path to your plugin's installation directory. Use this to reference scripts, binaries, and config files bundled with the plugin. In hook commands, use exec form with `args` so the path is passed as one argument with no quoting. In shell-form hooks and monitor commands, wrap it in double quotes, as in `"${CLAUDE_PLUGIN_ROOT}"`. This path changes when the plugin updates.

> The `command` value supports the same variable substitutions as MCP and LSP server configs: `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, `${CLAUDE_PROJECT_DIR}`, `${user_config.*}`, and any `${ENV_VAR}` from the environment.

docs が言う "monitor commands" は `monitors/monitors.json` の宣言を指す。runtime に Claude が Monitor ツールへ渡す `command` は対象外。
