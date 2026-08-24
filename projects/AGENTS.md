# projects/AGENTS.md — Project作業の入口

成果契約・Git境界・文書拡張・`repository_role`は`projects/PROJECTS.md`が所有する。

## 着手

1. 対象を一つに確定する。明示パスがなければ`projects/*/PROJECT.md`のfrontmatter
   （`name` / `description` / `status`）だけを1回の検索でまとめて取得して候補を絞り、1件ずつ開かない。
   明示依頼なく新設しない。
2. 書込Git root（`git -C projects/<name> rev-parse --show-toplevel`）、`AGENTS.md`（任意）、
   `PROJECT.md`、`STATE.md`、Required参照、条件付き文書を`AGENTS.md#Context Loading`に従って読む。
3. 対象契約（`#PC-xx`か`#status`）と合格条件を特定する。

## Git所有境界

- toplevel=Workspace rootならEmbedded、`projects/<name>/`ならIndependentとして各Gitへcommitする。
- 解決不能時だけ`projects/REPOSITORIES.md`を読みmaterializeへ進む。
- 書込は常に`projects/<name>/**`。本体sessionはregistryを、root sessionは本体を書かない。

## 実行と完了

- 成果契約内で最小かつ完全に変更する。契約変更は`projects/LIFECYCLE.md#人間が決める遷移`。
- `PROJECT.md`の検証を実行し、未実行を合格扱いしない。
- 状態変化と同じ作業内で`STATE.md`を更新。
- Project固有検証とroot validator（通常は`bash tools/validate-agent-directory.sh --changed`）を実行し、
  結果、証拠、commit、未完了を区別して報告する。

## 詳細正本を読む条件

- `PROJECTS.md`: 新設、状態・契約変更、文書拡張、Independent昇格・移行、remote、復旧、規約保守、明示参照。
