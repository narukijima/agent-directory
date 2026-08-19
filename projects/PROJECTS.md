# PROJECTS.md — 成果契約と現在状態の正本

固有のデータ、仕事、成果物を1 Project 1ディレクトリで保存する。

## 正本と責務

すべての一般Projectに必要なのは`PROJECT.md`と`STATE.md`だけである。その他は実在する複雑さを分離する
必要が生じたときだけ追加し、空の層や将来用文書を作らない。

```text
AGENTS.md              = 条件付きの読込先、固有コマンド、禁止事項
PROJECT.md             = なぜ行い、何を実現するか。種別、成果契約、判断原則、固定制約
STATE.md               = 今どこにいるか。現在目標、合格条件、検証結果、有効な決定、次の一手
ARCHITECTURE.md        = Project全体の構造地図、境界、不変条件
docs/                  = 必要になったProject固有の文書
Root Knowledge         = Projectを越えて再利用する確定知識
```

別の`GOAL.md`、`STATUS.md`、`TODO.md`を作らない。成果物はKnowledge、Skill、`.tmp/`へ残さず
必ず一つのProjectが所有し、再利用可能な知見だけを`knowledge/`へ同期する。

### 作らない重複

同じ情報のactive正本を二つ持たない。次は文書全体へ適用する。

- `docs/**`の一括読込。
- `AGENTS.md`への`PROJECT.md`、`STATE.md`、Project文書本文の複製。
- `PROJECT.md`や`STATE.md`への補助文書本文の複製。
- `PROJECT.md`と補助文書、`STATE.md`と計画文書、`ARCHITECTURE.md`と詳細設計文書、
  Projectの研究結果とRoot Knowledge。

## 対象の選択

1. 依頼か正本の明示相対パスを最優先する（未指定時の検索は`projects/AGENTS.md#着手`）。
   Project選択の単位は`PROJECT.md`であり、`docs/`配下を通常候補へ展開しない。
2. 通常候補は`status: active`だけ。`paused`、`completed`、`retired`は明示参照、再開、監査、保守時だけ選ぶ。
3. 候補メタデータだけで一意に選べず、選択で成果や安全性が変わる場合は利用者へ確認する。

## 基本構造

必要になった部分だけを作り、ツリー全体を生成しない。

```text
projects/<project-name>/
├── PROJECT.md
├── STATE.md
├── AGENTS.md         # 任意。作業差分がある場合だけ
├── ARCHITECTURE.md   # 任意。Project全体の構造地図
├── docs/             # 任意。必要になったProject固有文書
├── inputs/           # Project固有の入力
├── outputs/          # 完成成果物
├── runs/             # 保存価値のある詳細履歴。既定では読まない
├── candidates/       # Project固有の再利用候補
└── scripts/          # Project固有の固定コード
```

新規作成は利用者の明示依頼後に`_template/`をコピーし、すべてのプレースホルダーを書き換える。
`_template/`は`PROJECT.md`と`STATE.md`だけを持ち、他を常設しない。

## Project文書の任意拡張

`ARCHITECTURE.md`、`docs/`、個別`AGENTS.md`、研究文書は、実在する複雑さを分離する必要がある場合だけ追加する。
標準の文書階層、必須名、空フォルダを先に作らず、Projectに自然な名前と構造を使う。同じ情報のactive正本を
複製せず、必要な文書だけを個別`AGENTS.md`から条件付きで参照する。

`ARCHITECTURE.md`はProject全体の構造地図が必要な場合だけ使う。個別`AGENTS.md`はProject固有の読込条件、
build/testコマンド、編集禁止事項がある場合だけ置き、目的、成果契約、現在状態を複製しない。

具体的な調査、仮説、実験、結果はProjectが所有する。Project外でも再利用でき、根拠、適用範囲、不確実性を
示せる確定知識だけをKnowledgeへ昇格し、元の証拠へリンクする。同じ結論をProjectとKnowledgeの二つの
active正本として保守しない。

## 食い違いの訂正

利用者から間違い、重複、目的不一致、過去決定の見落としを指摘された場合は、`PROJECT.md`、`STATE.md`、
対象成果物を再読し、期待と現在結果の差を特定する。成果契約を無断で変えず、最小範囲を修正して契約の検証を
再実行し、現在有効な結果と判断だけを`STATE.md`へ反映する。失敗・却下済みの方法は新しい根拠なしに繰り返さない。

## Attachment

Projectは成果、目的、状態の境界であり、Gitリポジトリは変更権限、自動化、配布、外部接続の境界である。
両者を1対1にしない。agent-directoryは外部repoの集約点ではなく、一体のAgent Workspaceである。

Project root、実装root、通常の作業cwdは、attachmentによらず`projects/<name>/`へ統一する。
違いはpathではなく所有Gitだけである。

- **Embedded** — Git top-levelはAgent Workspace root。`projects/<name>/**`をroot Gitが所有する。
- **Independent** — Git top-levelは`projects/<name>/`自身。直下に実`.git/`を持つ通常cloneである。

Projectの恒久attachment、registry、recovery単位としてworktree、submodule、symlink、`.git` file、外部配置、
`repository/`のような下位repo階層を使わない。RuntimeがWorkspaceやProject repositoryを一時worktreeへcheckoutし、
session isolationや並列作業に使うことは妨げない。そのworktree自体をregistry entryや採用revisionの正本にしない。
すべてのProjectはEmbeddedで開始し、独立したremote identityが必要な場合だけIndependentへ昇格する。

`PROJECT.md`はattachmentを宣言しない。`repository_mode`等の旧repository frontmatterと
`STATE.md`の`## Repository State`は廃止済みで現役schemaへ残さない。
判定は`projects/REPOSITORIES.md`の登録、`git -C projects/<name> rev-parse --show-toplevel`の結果、
root Gitがそのpath配下を追跡しているかの三つで行う。

### Canonical Ownership

Independentでは`projects/<name>/**`のすべて（契約、状態、個別`AGENTS.md`、docs、入出力、
コード、Git履歴）をProject固有Gitが所有し、root Gitは内部ファイルを一つも追跡しない。root側へ
`PROJECT.md`や`STATE.md`のコピーを残さず、同じ契約と状態を二つのGitへ複製しない。

Owner Agentが開発する公開基盤製品だけはregistryの`repository_role: public-foundation`で明示する。
これは一般Projectではなく、製品repositoryが公開目的、仕様、repository-local規約、検証、配布文書を所有し、
Owner Agent rootが製品横断の現在目標、優先順位、相互影響、次の一手、採用revision、handoff状態を一元管理する。
製品repositoryへOwner Agent固有の`PROJECT.md` / `STATE.md`を置かず、同じactive状態を二つのGitへ複製しない。
一般利用者のProject契約と混同せず、この役割のrepositoryは`meta` Routeで扱う。

### Registryとignore projection

root Gitが持つのはrepository本文ではなく、[projects/REPOSITORIES.md](REPOSITORIES.md)の最小な
attachment／recovery registryと、その派生projectionである`projects/.gitignore`だけである。registryは
目的、成果契約、status、mode、現在状態を複製せず、entry形式、field規則、`repository_reason`と
`repository_role`の値、
managed blockの規則はregistry自身が所有する。registryが正本であり、ignoreは派生である。

Embedded Project、`_template/`、registry自身をignoreせず、`projects/*/`のような広いpatternを追加しない。

コード量、ファイル数、言語、整理都合、重要度、期間、既存repoだった事実だけではIndependent化しない。
大容量binaryも理由にせず、外部artifact保管先とchecksumはProject側が定義する。remote名は`origin`固定と
し、remoteから復旧できることを必須とする。

### Session rootとSHA handoff

一つのAI sessionは二つのGit rootへ書き込まない。Single Writer定義は`tools/SAFETY.md`が所有する。

cwdとcommit先の対応は`projects/AGENTS.md#Git所有境界`が所有する。registryを更新するsessionは
registryとignore projectionだけを書き、本体を変更するsessionはroot repositoryを変更しない。

### Remote操作の境界

Agent Directoryはpush、PR、merge、branch cleanup、remote platform APIの実行Toolやworkflowを持たない。
対象ProjectとRuntimeがremote操作を完了した後、Independent sessionは確定commit SHAだけをhandoffし、別のroot sessionが
`projects/REPOSITORIES.md`の`revision`とignore projectionを更新する。Coreはlocal Git ownership、登録URL、採用revision、
materialization整合を検証し、remote操作方法やapproval modeを規定しない。

### Materialization境界

健全なAgent Workspaceでは、statusにかかわらず全Independent repositoryがmaterialize済みである。
materializerの動作は`tools/TOOLS.md#independent-project`が所有する。rootでの破壊的な`git clean`は、
ignoreされたIndependent cloneを削除しうるため実行しない。

### 昇格、移行、統合

EmbeddedからIndependentへの昇格は次の順で行う。

1. 利用者がIndependent化と`repository_reason`を明示決定し、root Gitで移行前checkpointを確定する。
2. remote repoを作成し、`projects/<name>/`をrootとするsessionで検証、commit、`origin`へ通常pushする。
3. root indexから`projects/<name>/`配下を削除し、registry entryとmanaged entryを同じroot commitで
   追加する。
4. validatorで二重正本とroot追跡の不在を確認する。

履歴抽出は実益がある場合だけ行い、そのために平常時からrepoを分けない。
登録のないnested repoまたはsubmoduleは追加、削除、ignore、submodule化せず、停止して利用者へ確認する。

IndependentからEmbeddedへの統合は自動既定にしない。`repository_reason`のどの根拠も現在成立しないことを
監査し、利用者が明示指示した場合だけ実行する。その指示を再承認させない。停止中という理由だけで統合しない。

### 旧構造からの移行

旧`projects/<name>/repository/`方式とagent-directory外へcloneを置く旧方式は、最終標準として残さず
永久併存も認めない。移行は現在のregistry、採用revision、Git ownerを検査して一度だけ行う。

## PROJECT.md

frontmatterは次を必須とする。

```yaml
---
name: project-name
description: 候補選択に使う一行説明
status: active
mode: finite
---
```

- `name`はディレクトリ名と一致させる。
- `description`は200文字以内の一行とし、タブを含めない。
- `mode`は`finite`または`continuous`だけを使う。
- `status`は`active | paused | completed | retired`だけを使う。
- パスが恒久IDである。別のID体系や物理archiveを作らない。
- 本文の必須見出し集合は`projects/_template/PROJECT.md`を規範とする（目的、判断原則、非ゴール、
  制約・固定決定、品質基準、入力、使用するKnowledge、使用するSkill、成果物、検証方法）。
  validatorがこの集合を検査する。

### finite

一つの検証可能な終了状態を実現する。`最終ゴール`と固定ID付き`完了条件`を持ち、
全条件の検証後だけ`completed`にする。

### continuous

現在目標を更新しながら継続する。`継続的使命`、固定ID付き`成功指標`、`見直し・終了条件`を持つ。
`completed`は使わない。終了・転換は`projects/LIFECYCLE.md`の遷移（利用者の決定）に従う。

## 参照するKnowledgeとSkill

各参照欄を`### Required`と`### Conditional`に分ける。

- RequiredのKnowledgeとSkillは合計6件以内とし、着手時に読む。
- Conditionalは`条件:`と`参照:`を組にし、条件成立時だけ読む。
- 参照はリポジトリ相対パスを使う。ウィキリンクだけを実行時参照にしない。
- 非activeなKnowledge、deprecated/retired SkillをRequiredにしない。
- 上限を超える場合は条件付き化、参照入口の集約、またはProject分割を行い、無制限読込で解決しない。

## 着手から終了まで

実行手順（読込順序、契約とPC-xxの特定、最小かつ完全な変更、検証、STATE更新、scoped commit、報告）は
入口`projects/AGENTS.md#着手`と`projects/AGENTS.md#実行と完了`が所有する。

`mode`、目的、ゴールまたは使命、完了条件または成功指標、判断原則、非ゴール、固定決定は、
利用者が変更を明示した場合だけ変更する。

## Project Criterion

finiteの完了条件とcontinuousの成功指標だけに、`- **PC-01** <安定した合格条件>`の形式で
`PC-01`から始まる固定IDを付ける。IDは達成状態ではなく恒久的な住所である。並べ替えや達成で変更せず、削除後に番号を再利用しない。
達成状態と証拠は`STATE.md`だけが持つ。

## STATE.md

- 現在目標は一つの到達状態とし、`対象契約: PROJECT.md#PC-xx`を一つ示す
  （状態遷移そのものを扱う作業だけ`PROJECT.md#status`を使う。completed Projectは常に`#status`）。
- 必須見出し集合は`projects/_template/STATE.md`を規範とする（現在の到達点、現在の目標、
  目標の合格条件、検証結果、未完了・ブロッカー、現在有効な決定、失敗・却下済み、次の一手）。
  validatorがこの集合を検査する。
- 合格条件は第三者が判定できる形にする。
- 検証結果は対象、確認日、方法、客観的結果を持ち、最新の有効な証拠だけを残す。
- 有効な決定、失敗・却下済み、ブロッカー、次の一手を現在形で短く保つ。
- 詳細な試行履歴は`runs/`またはGitへ移し、8KiBを超えない。
- 現在判断ではactiveなKnowledgeとSkillを優先する。

状態遷移と削除条件は必要な場合だけ[projects/LIFECYCLE.md](LIFECYCLE.md)を読む。Independent repositoryの
接続不一致は[projects/REPOSITORIES.md](REPOSITORIES.md)の復旧境界に従う。

## 検証

- Project固有の検証は`PROJECT.md`の`## 検証方法`に実行手順、合格条件、不合格時の扱い、
  必要な環境変数（キー名のみ）、使用した入力を記す
  （コードの置き場は`tools/TOOLS.md#一時作業`）。
- 外部公開、本番反映、送信、課金、権限変更、remote操作の実行契約は対象Project、Runtime、Operatorが所有する。
  Agent Directoryは成果契約と検証結果だけを正本として保持する。
