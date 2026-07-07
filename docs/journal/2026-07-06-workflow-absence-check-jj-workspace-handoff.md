# ハンドオフ: post_tool_use hook の workflow 不在チェックを jj workspace 対応にする

対象 issue: `docs/issue/2026-07-06-workflow-absence-check-bypassed-on-jj-workspace.md`
方針: 独自の git/jj 解決ロジックを `bump-semver vcs` に寄せる (kawaz 指示)。

このファイルは調査途中のハンドオフ。**実機で裏取りできた事実のみ**を「確定」に置く。
未確認・要判断は明示的に分けてある。次セッションは「要再確認」項目を先に潰すこと。

## 確定した事実 (実機検証済み)

### 1. バグの再現

`hooks/post_tool_use.sh` の toplevel 解決は `git -C "$workdir" rev-parse --show-toplevel`
のみに依存。git bare + jj workspace 構成では bare リポに当たり exit 128
(`fatal: this operation must be run in a work tree`) を返す。

- gh-monitor リポ自身も **git bare + jj workspace 構成** (`.git` は無く `.jj` のみ、
  `bump-semver vcs get backend` = `jj`)。
- `main/` で `git rev-parse --show-toplevel` → exit 128 を実機確認。
- 結果、`_repo_toplevel` が空になり workflow 不在チェックのブロック (下記「該当箇所」の
  workflow 存在チェック) 全体がスキップ → workflow を持たないリポでも push のたびに
  watch nudge が出続ける。

### 2. `bump-semver vcs` で置換可能なこと

- `bump-semver vcs get root` → git bare + jj workspace でも正しく repo root を返す
  (実機: gh-monitor/main で正しいパスを返した)。git backend でも動く agnostic API。
- `bump-semver vcs get commit-id` → 40-char SHA。ただし **jj のデフォルト rev は `@`**。
- `bump-semver vcs get backend` → `git` / `jj` を返す。

### 3. SHA 解決の落とし穴 (重要 — 単純置換で退行する)

hook の head SHA 解決には既存の意図がある: 「push された **non-empty** commit を pin する」。

実機検証時の gh-monitor/main の状態:
- `@` は **EMPTY** (空 working-copy commit、commit_id `64b7d3d…`)
- `git rev-parse HEAD` = `64b7d3d…` = **空コミット** (実際に push された commit ではない)
- `jj log -r 'latest(::@ & ~empty())'` = `2c89449…` = **実際の push 対象**
- `bump-semver vcs get commit-id` (デフォルト `@`) = `64b7d3d…` = **空コミット** ← 退行
- `bump-semver vcs get commit-id --rev 'latest(::@ & ~empty())'` = `2c89449…` = **正しい**

→ SHA 解決を `vcs get commit-id` のデフォルトに置き換えると、jj で空コミットの SHA を
pin してしまい CI run が存在せず no-match-timeout まで無駄常駐する (現行実装が回避
している退行そのもの)。置換するなら **jj では `--rev 'latest(::@ & ~empty())'` 相当が
必須**。ただしこの revset は jj 専用で git backend では通らない見込み (未検証、下記要確認)。

### 4. 現行 hook の該当箇所 (前半で全文取得済み・信頼できる)

`hooks/post_tool_use.sh`:
- **cd override 内の toplevel 解決** (~85 行目付近): `git -C "$_last_cd_expanded"
  rev-parse --show-toplevel`。越境 push (`cd /other/jj-repo && just push`) で cd 先が
  jj workspace だと同じく失敗し `_workdir_override` が空 → CLAUDE_PROJECT_DIR に
  fallback。issue には未記載だが同根の bug。
- **workflow 不在チェックの toplevel 解決** (~112 行目付近): `git -C "$workdir"
  rev-parse --show-toplevel` → `_repo_toplevel` → `$_repo_toplevel/.github/workflows`
  の存在チェック。**issue の主眼**。
- **head SHA 解決** (~131–140 行目付近): `.jj` 存在 + `command -v jj` ガードで
  `jj -R "$workdir" log -r 'latest(::@ & ~empty())'`、無ければ `git rev-parse HEAD`。
  = jj を **optional 依存** として扱う既存の前例 (bump-semver 化する際もこの
  「無ければ fallback」姿勢を踏襲するか要判断)。

## 要再確認 (後半で読んだが裏取りが弱い項目)

- **CI (`.github/workflows/ci.yml`) は jq のみ install、jj/bump-semver 無し** の見込み
  (`wc -l` = 21 は確定、"Install jq" step と `./tests/run-tests.sh` 実行は見えたが
  全文の信頼度が低い)。→ 次セッションで ci.yml を読み直して確定させること。
- gh-monitor は **plugin.json / marketplace.json を持つ配布 plugin** (ファイル存在は確認)。
  README の対象読者・依存要件セクションは未確認。

## 未解決の設計判断 (次セッションで kawaz に確認 or 判断)

hook は **ユーザ環境で実行時に動く**。justfile / release.yml が bump-semver を使うのは
「開発・リリース時の依存」で別レイヤ。hook が bump-semver に依存すると影響範囲が変わる。

- **論点 A: bump-semver を hook の依存にする形**
  1. **hard dependency**: 独自 git/jj ロジックを全撤去し bump-semver 前提。
     → CI テストに bump-semver install 追加が必要 (要再確認の CI 前提と直結)。
     → 配布 plugin なので bump-semver を持たない一般ユーザ環境で hook が壊れるリスク。
  2. **optional**: bump-semver があれば使い、無ければ現行 git/jj fallback を残す。
     → 独自ロジックは残るが安全。現行の jj optional 扱いと整合。
  3. bump-semver 不使用で独自ロジックを jj workspace 対応に修正するだけ。
     → kawaz 指示 (bump-semver を使う) に反するので原則不採用。
  - kawaz 指示は「bump-semver vcs を使う」。ただし配布 plugin の依存問題は未提起。
    hard か optional かを確認したい。

- **論点 B: 解決不能時のデフォルト方向** (issue の (b))
  現状は「toplevel 解決不能 → nudge を出す」(誤 nudge 側)。bump-semver で解決率が
  上がれば「判定不能」ケース自体が減るので、この論点の重みは下がる見込み。

## 修正プラン (骨子)

1. **toplevel 解決 2 箇所** (cd override / workflow チェック) を
   `bump-semver vcs get root` (対象 workdir を `-C` 相当で渡す方法を要確認 —
   `cd "$workdir" && bump-semver vcs get root` のサブシェル方式が無難) に置換。
   論点 A の結論次第で optional ラッパーにするか決める。
2. **head SHA 解決** は SHA 落とし穴 (上記 3) を踏まえ、単純置換しない。
   bump-semver 化するなら backend 判定 + jj は `--rev 'latest(::@ & ~empty())'`。
   git backend での revset 挙動を先に検証すること。
3. **TDD**: `tests/run-tests.sh` の post_tool_use セクションは現状 `setup_git_repo`
   (素の git init) のみで jj workspace ケースを持たない = このバグは未捕捉。
   git bare + jj workspace の fixture を作るヘルパーを追加し、「workflow 無し jj
   workspace リポ → nudge 無し」の RED テストを先に書く。ただし CI に jj/bump-semver
   が無い場合、fixture が動かない → 論点 A / CI 前提と合わせて test 戦略を決める
   (本物の jj で fixture を組み、jj/bump-semver 不在環境では skip する等)。

## 参照

- issue: `docs/issue/2026-07-06-workflow-absence-check-bypassed-on-jj-workspace.md`
- 対象: `hooks/post_tool_use.sh`
- テスト: `tests/run-tests.sh` (post_tool_use セクション、`setup_git_repo` ヘルパー)
- `bump-semver vcs get --help` (root / commit-id / backend / default-branch 等)
