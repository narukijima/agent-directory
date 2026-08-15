# DOCS.md — Project文書の任意拡張

`ARCHITECTURE.md`または`docs/`を持つProjectだけが読む、段階的開示と文書責務の正本である。
Projectの成果契約、attachment、stateは`projects/PROJECTS.md`が引き続き所有する。

## Project文書の三層

Scope Canon（`AGENTS.md`/`PROJECT.md`/`STATE.md`/`ARCHITECTURE.md`）、Domain Canon
（`docs/<DOMAIN>.md`と`docs/<DOMAIN>_SENSE.md`）、Detail Documents（`docs/`下の小文字ケバブケースの
詳細設計、仕様、研究、計画、証拠）の三層を使う。標準概念として先に生成しない。

### Domain Canon

`docs/`直下に置く、意味を持つ大文字のMarkdownである（例: `DESIGN.md`、`PLANS.md`、`RESEARCH.md`）。
必須一覧はなく、実際に存在する分野だけを作る。

- 命名は原則として`^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*\.md$`を満たす。
- 内容を持つ`docs/`は最低1件のDomain Canonを直下に持つ。詳細文書だけを置いて入口を欠かない。
- `docs/README.md`、`docs/NOTES.md`、`docs/MISC.md`のような汎用的・無責任な正本を作らない。
- 単なるリンク一覧にしない。現在有効な原則、境界、決定を短く保持し、詳細文書へ案内する正本兼入口とする。
- 24KiBを超えない。超える詳細はDetail Documentsへ委譲する。見出し構成は分野ごとに決めてよい。

### Detail Documents

詳細フォルダと詳細文書はProjectごとに設計してよく、agent-directory全体で名前を固定しない
（例: `docs/design-docs/core-beliefs.md`）。

- フォルダと詳細文書は原則として小文字ケバブケースとする。
- `misc/`、`other/`、`notes/`のような総受けフォルダを作らない。
- `docs/`直下の各フォルダは少なくとも一つのDomain Canonから参照し、`references/`と`generated/`も
  どのDomain Canonが管理するかを明示する。
- 下位コレクションの局所地図として`index.md`を使ってよい。下位`README.md`を正本や入口として多用しない。
- 空フォルダをテンプレート生成しない。
- `docs/references/`は繰り返し参照するProject固有資料に限定し、Root Knowledgeと二重正本にしない。
  `docs/generated/`は生成元、生成コマンド、鮮度確認方法がある場合だけ使い、生成物を手編集しない。

## ARCHITECTURE.md

Project rootに置く任意の全体地図である。所有するのは、Projectが解く問題の俯瞰、主要コンポーネント、
コード・パッケージ・データの配置、依存方向とシステム境界、アーキテクチャ不変条件、横断的関心事。
現在目標・TODO・進捗、詳細な試行履歴、頻繁に変わる実装詳細、`PROJECT.md`と`STATE.md`の再掲は置かず、
詳細設計はDetail Documentsへ置く。

## `<DOMAIN>_SENSE.md`

分野固有の定性的な品質判断を所有する任意パターンである。裸の`SENSE.md`を使わず、必ず対象Domainを
名前に含める。例: `PRODUCT_SENSE.md`、`DESIGN_SENSE.md`。

- 所有する: What good looks like、Core beliefs、判断ヒューリスティクス、トレードオフ、
  Anti-patterns、良い例と悪い例、レビュー時の問い、見直し条件。
- 所有しない: 必須仕様、数値合格条件、コマンド、現在状態、単なる好み、根拠のない抽象語。

測定可能な評価軸は`QUALITY_SCORE.md`または`<DOMAIN>_SCORE.md`が持つ。

## 個別ProjectのAGENTS.md

Project固有の作業差分だけを持ち、差分があるときだけ置く。`ARCHITECTURE.md`または`docs/`が存在する場合は、
同Projectの`AGENTS.md`と`CLAUDE.md`を必須とし、段階的開示の入口にする。

置いてよい内容:

- 条件付きのProject Docs Route（本文を複製せず、条件と読む正本だけを列挙する）
- Project固有のbuild、test、lintコマンドと検証順序
- 特定パスの編集禁止、既存成果物の上書き禁止、使用するruntime
- 本番送信、公開、課金、権限変更のauthorization条件、`## Push Policy`、Project固有の生成物配置

置いてはいけない内容:

- 目的、最終ゴール、継続的使命、完了条件、成功指標、Project Criterion
- 現在目標、現在状態、検証結果、現在有効な決定
- KnowledgeとSkillの参照一覧
- `projects/PROJECTS.md#作らない重複`が禁じる本文の複製と一括読込指示

見出しは`## Project Docs Route`と正確に一致させ、存在する`ARCHITECTURE.md`と`docs/`直下の各Domain
Canonを条件付き項目として列挙する。項目は「条件」と「読む正本」を持つ表の行、または`条件:`と
`参照:`の対とする。本文中の言及、単なるファイル一覧、禁止文への登場は条件付き参照として数えない。
`PROJECT.md`と`STATE.md`を正本として参照し、同階層に`@AGENTS.md`だけを持つ`CLAUDE.md`を必ず置く。
サイズ予算（2KiB）を拡大せず、短いRoute表として収める。

## 研究文書とKnowledge昇格

具体的な研究活動はProjectが所有し、再利用可能な研究方法はSkillが所有する。仮説、調査、実験は規模に応じて
`docs/RESEARCH.md`か`docs/research/<study-name>.md`へ、成果物は`outputs/`へ置く。推奨要素は、
問い、目的、仮説、方法、使用した証拠、観測・結果、反対証拠・限界、現在の結論、Knowledgeへの昇格先。

Root Knowledgeへ昇格するのは、Project外でも再利用でき、根拠へ遡れ、適用範囲と不確実性が明記され、
一時的な作業メモでない場合だけとする。昇格時はProject Researchを研究履歴として残し、Knowledge側と
元研究・原資料を双方向にリンクする。現在有効な再利用可能結論はKnowledgeを正本とし、同じ結論を二つの
active正本として保守しない。Project固有の結論を無理に昇格させない。
