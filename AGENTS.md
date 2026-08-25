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

## Route

依頼・明示パス・成果物からRouteを決めて入口を読む。Routeは話題の語ではなく変更対象で決める。

| Route | 対象 | 入口 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | `knowledge/KNOWLEDGE.md` |
| `skill` | 再利用手順・研究方法 | `skills/SKILLS.md`と対象`SKILL.md` |
| `project` | 固有作業・成果物・研究 | `projects/AGENTS.md` |
| `meta` | 構造、規約、Tool | 対象領域の正本と変更対象 |
| `none` | 永続化Ownerのない回答 | 原則追加ロードなし。Runtimeが選んだSkillは実行時に読む |

## Context Loading

明示targetを優先する。target未指定のKnowledge照会だけ、Runtime標準のファイル検索で
`knowledge/wiki/{sources,topics}/`からactive候補を最大5件へ絞る。SkillはRuntimeの標準Skill discovery、
Projectは明示pathか`projects/*/PROJECT.md`のfrontmatterからactive候補を最大5件へ絞り、Core独自の検索
Runtimeを通さない。台帳、履歴、`runs/`、`docs/**`を一括読込せず、24KiB超は節で絞る。

予算はbyte数だけでなく往復回数にも適用する。pathが決まっている読込は依存のない範囲ごとに1回のbatchで
まとめ、存在確認や1ファイルずつへ往復を分けない。32KiB・12ファイル到達時は未読範囲を報告して停止する。

## 自律実行

通常経路は`Route → Target → Work → Verify`、書込Git rootはsessionごとに1つ。独立して完結するSkill実行は
Runtime標準のSubagentへ委譲・並列化してよく、委譲基準、境界、Worker往復の最小contextは
`skills/SKILLS.md#Skill実行の委譲`が所有する。
失敗層を分け、同じfingerprintを状態・入力・経路の差分なしに再試行しない。

## 責任領域

- **Owner** — 目的、最終方針、本人判断、例外承認を持つ。
- **AI Agent** — Ownerの責任領域を除く判断、設計、実行、検証、再試行、正本・状態更新、通常完了を担う。
- **Runtime / Operator** — 実行能力、認証情報、権限、端末・session、外部操作機構を所有する。
- **Canonical Owner** — 情報を保存する一意な正本であり、人間のOwnerとは別概念である。

## 差分判定

意味ある差分だけを永続化し、既定はno-op、`create`より`update / merge / supersede`を選ぶ。AIの推論を
利用者の決定として保存せず、訂正は`knowledge/KNOWLEDGE.md#訂正の伝播`まで完結する。context圧縮や
状態更新で失う情報は、破棄の前に`knowledge/KNOWLEDGE.md#失う前に確定する`へ従って確定させる。
新しいTool、Skill、恒久的な仕組み、抽象化、依存は原則追加しない。既存Ownerへ統合できず、目的、Owner、
非ゴール、維持コストが依頼または正本から一意で新設が必要なら自律追加する。将来用の曖昧な新設はno-opとする。

## 禁止事項

- APIキー、token、password、外部サービス設定の実値をcommitしない。Agent固有の環境変数は未追跡のroot
  `.env`を既定とし、保存と注入は各Agent / Runtimeが所有する。OS共有設定はOperatorが明示選択した場合だけ使う。
- remoteを書込正本にしない。push、divergence、privacy訂正、PR必須ruleは対象Project / Repository契約に従う。
- 未依頼の機能・抽象化・依存を足さず、未検証を完了報告しない。
- 一意な削除・移動だけを実行し、paused / retiredとProject削除は`projects/LIFECYCLE.md`に従う。
- 下位`AGENTS.md`で上位規則・`PROJECT.md`を弱めない。

上記の判断を支える安全核は`tools/SAFETY.md`の5項目だけとする。

## 詳細正本

- Project: `projects/PROJECTS.md`、`projects/LIFECYCLE.md`
- Tool: `tools/TOOLS.md`
- Safety: `tools/SAFETY.md`

## 参照順序

明示指示 → 本`AGENTS.md` → Route正本 → 対象正本 → 明示参照資料。
