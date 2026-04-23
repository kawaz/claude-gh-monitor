# ブランチ/bookmark 名の取得方法検証

## 判明した事実

- `git rev-parse --abbrev-ref HEAD` は **jj workspace 方式(git bare + jj workspace)では失敗する**（`fatal: ambiguous argument 'HEAD'`）
- `git branch --show-current` は **jj workspace でも git worktree でも正しく現在の bookmark/branch 名を返す**
- jj の template で `heads(bookmarks() & ::@)` を使うと、@ 自身または祖先に紐づく最も近い bookmark を取得できる

## 実用的な示唆

- `detect-pr.sh` はブランチ名取得の第一候補として `git branch --show-current` を使うべき
- jj workspace で `--detached` や「@ に bookmark なし」ケースのフォールバックとして `jj log -r 'heads(bookmarks() & ::@)' -T 'bookmarks'` を持っておくと安全
- 最後に `git rev-parse --abbrev-ref HEAD` を fallback として残すことで、古い git や特殊な環境にも対応

## 検証の詳細

### 検証環境

| ディレクトリ | 方式 | 結果 |
|---|---|---|
| `claude-pr-monitor/main` | git bare + jj workspace | `git rev-parse --abbrev-ref HEAD` → fatal error、`git branch --show-current` → `main` |
| `antenna/2074-feature-dashboard-redesign` | git bare + worktree | `git branch --show-current` → `feature/dashboard-redesign` |

### 検証コマンド

```bash
# jj workspace 側（claude-pr-monitor/main）
:;git rev-parse --abbrev-ref HEAD
# → fatal: ambiguous argument 'HEAD'

:;git branch --show-current
# → main

jj log -r @ --no-graph -T 'bookmarks ++ "\n"'
# → (空: @ 自身に bookmark が無い)
```

```bash
# git worktree 側（antenna/2074-...）
:;git branch --show-current
# → feature/dashboard-redesign
```

### 考察

jj workspace 方式では、HEAD 参照が jj 側の内部状態を指しており、`git rev-parse --abbrev-ref HEAD` のような解決は失敗する。一方 `git branch --show-current` は symbolic ref を直接読むため、jj が export した bookmark 名を取得できる。jj の内部論理上「@ が bookmark を持たない change」でも、git 側から見た HEAD は直近の bookmark を指している状態になっていることが多い（export された状態）。

万一 `git branch --show-current` が空を返すケース（detached HEAD 相当）では、jj に直接問い合わせる `jj log -r 'heads(bookmarks() & ::@)'` が最終防衛線となる。
