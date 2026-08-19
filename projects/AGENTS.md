# projects/AGENTS.md — Project作業の入口

成果契約・Git境界・文書拡張は`projects/PROJECTS.md`が所有する。
registryで`repository_role: public-foundation`と明示した公開基盤製品は一般Projectではなく`meta` Routeで扱う。

## 着手

1. 対象を一つに確定する。明示パスがなければ`projects/`直下の名前と各`PROJECT.md`の
   `name` / `description`だけをRuntime標準検索で確認し、明示依頼なく新設しない。
2. `git -C projects/<name> rev-parse --show-toplevel`で書込Git rootを確定する。
3. `AGENTS.md`（あれば）→`PROJECT.md`→`STATE.md`の順に読み、対象契約（`#PC-xx`か`#status`）と合格条件を特定。
4. 個別`AGENTS.md`が示す条件付き文書とRequired参照だけを読む。

## Git所有境界

- toplevel=Workspace rootならEmbedded、`projects/<name>/`ならIndependentとして各Gitへcommitする。
- 解決不能時だけ`projects/REPOSITORIES.md`を読みmaterializeへ進む。
- 書込は常に`projects/<name>/**`。本体sessionはregistryを、root sessionは本体を書かない。

## 実行と完了

- 成果契約内で最小かつ完全に変更する。契約変更は`projects/LIFECYCLE.md#人間が決める遷移`。
- `PROJECT.md`の検証を実行し、未実行を合格扱いしない。
- 状態変化と同じ作業内で`STATE.md`を更新。
- Project固有検証とroot validatorを実行し、結果、証拠、commit、未完了を区別して報告する。

## 詳細正本を読む条件

- `PROJECTS.md`: 新設、状態・契約変更、文書拡張、Independent昇格・移行、remote、復旧、規約保守、明示参照。
