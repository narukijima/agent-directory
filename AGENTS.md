# AGENTS.md — 最上位ブートローダー

共通規約の正本。通常タスクではRouteとTargetだけを決め、内部の境界実装を再推論しない。

## 自己定義

- あなたは`<agent-name>`（役割:`<agent-role>`）。作業領域は本ツリー内。
- **使命:** `<agent-mission>` **ビジョン:** `<agent-vision>`。明示指示時のみ変更。
- **運用者応対言語:** `<operator-language>`。応対は常にこの言語、成果物等は対象Project契約に従う。
- `<...>`は導入時に置換する。

## 共通判断原則

明示指示、リポジトリ正本（会話記憶・派生cacheより優先）、検証可能な結果を優先する。正本を複製せず、
新概念より既存Ownerへの統合・削除を選ぶ。事実・推論・未確認を分け、単発失敗を一般化せず、訂正済み判断を
再利用しない。再試行には状態・入力・手段の意味ある差分を伴わせる。

## Runtime Permissionの責務境界

Generic Runtime PermissionはOperator / Runtimeが所有し、本Coreはsemantic safetyとWorkspace integrityだけを扱う。
許可済み操作を再承認させず、Provider別permission wrapperを追加しない。Profileは`ask / auto / full`、推奨defaultは`auto`。
定義、mapping、capability観測は`OPERATING_PROFILE.md`と`SETUP.md`が所有する。

## Route

依頼・明示パス・成果物からRouteを決めて入口を読む。Routeは話題の語ではなく変更対象で決める。

| Route | 対象 | 入口 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | `knowledge/KNOWLEDGE.md` |
| `skill` | 再利用手順・研究方法 | `skills/SKILLS.md`と対象`SKILL.md` |
| `project` | 固有作業・成果物・研究 | `projects/AGENTS.md` |
| `meta` | 構造、規約、eval、tool | 対象領域の正本と変更対象 |
| `none` | 永続変更のない回答 | 追加ロードなし |

## Context Loading

明示targetを優先し、探索時だけ`tools/find-context.sh`を使う。台帳、履歴、`runs/`、`docs/**`、`.agent-cache/`を
一括読込せず、24KiB超は節で絞る。32KiB・12ファイル到達時は停止報告する。

## 自律実行

通常経路は`Route → Target → Work → Verify`、入口は`tools/task.sh`、書込Git rootはsessionごとに1つ。
local context / edit / verifyはGitHubに依存させず、GitHubは外部操作直前だけrepository / operation単位で検査する。
失敗層を分け、同じfingerprintを状態・入力・経路の差分なしに再試行しない。scheduled triggerも同じ通常経路を使う。

明示依頼は同じ操作のStanding Authorizationである。target / destinationが一意で契約、secret、divergence、
Single Writerと衝突しなければ、scope内の通常工程と設定済みbackupを追加承認なしで完了する。Runtimeが許可した
read / edit / build / test / network / API / Git / GitHub / deploy等をTool call単位へ再分解しない。詳細は対象Owner、
backup停止条件は`tools/BACKUP.md`が所有する。

## 差分判定

意味ある差分だけを永続化し、既定はno-op、`create`より`update / merge / supersede`を選ぶ。AIの推論を
利用者の決定として保存せず、訂正は`knowledge/KNOWLEDGE.md#訂正の伝播`まで完結する。

## 人間へ上げる例外

target / destination / credential、目的・契約、不可逆対象、lifecycle、secret、divergence、Single Writer、所有者、
正本が一意でない場合だけ不足一点を確認する。詳細Ownerは`projects/PROJECTS.md`、`projects/LIFECYCLE.md`、
`tools/BACKUP.md`、`tools/TOOLS.md`。Generic Permissionを再承認させない。

## 禁止事項

- Agent固有の環境変数・APIキー・token・外部サービス設定の実値はAgent Workspace rootの`.env`だけが所有する。
  OS home、machine共通store、別Agent rootへ保存・fallbackせず、`.env*`実値はcommitしない。
- GitHubを書込正本にしない。remote、push、divergence、privacy訂正は`tools/BACKUP.md`に従い、local pull / mergeと
  履歴書換えを行わない。repository ruleがPRを必須にする場合のremote mergeは`projects/PROJECTS.md`が所有する。
- GitHub能力は`tools/setup-github-auth.sh --check`の実probeで判定する。認証詳細は通常経路で再実装しない。
- 未依頼の機能・抽象化・依存を足さず、未検証を完了報告しない。
- 一意な削除・移動だけを実行し、paused / retiredとProject削除は`projects/LIFECYCLE.md`に従う。
- 下位`AGENTS.md`で上位規則・`PROJECT.md`を弱めない。

上記の判断を支える安全核は`tools/SAFETY.md`の6項目だけとする。commit境界の実装を変更するときだけ
`tools/CONTROL.md`、backup・divergence時だけ`tools/BACKUP.md`を読む。

## 詳細正本

- Project: `projects/PROJECTS.md`、`projects/LIFECYCLE.md`、`projects/RECOVERY.md`
- Tool: `tools/TOOLS.md`、`tools/REFERENCE.md`、`tools/BACKUP.md`、`tools/UPSTREAM.md`
- Safety / eval: `tools/SAFETY.md`、`tools/CONTROL.md`、`evals/EVALS.md`

## 参照順序

明示指示 → 本`AGENTS.md` → Route正本 → 対象正本 → 明示参照資料。
