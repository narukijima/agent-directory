# PROJECTS.md — 成果契約と現在状態の正本

固有のデータ、仕事、成果物を1 Project 1ディレクトリで保存する。

## 正本と責務

すべての一般Projectに必要なのは`PROJECT.md`と`STATE.md`だけである。その他は実在する複雑さを分離する
必要が生じたときだけ追加し、空の層や将来用文書を作らない。

```text
AGENTS.md              = 読込Route、固有コマンド、禁止事項、authorization条件
PROJECT.md             = なぜ行い、何を実現するか。種別、成果契約、判断原則、固定制約
STATE.md               = 今どこにいるか。現在目標、合格条件、検証結果、有効な決定、次の一手
ARCHITECTURE.md        = Project全体の構造地図、境界、不変条件
docs/<DOMAIN>.md       = 分野ごとの現在有効な正本兼入口
docs/<DOMAIN>_SENSE.md = 分野固有の定性的判断
下位文書               = 詳細設計、仕様、研究、計画、証拠
Root Knowledge         = Projectを越えて再利用する確定知識
```

別の`GOAL.md`、`STATUS.md`、`TODO.md`を作らない。成果物はKnowledge、Skill、`.tmp/`へ残さず
必ず一つのProjectが所有し、再利用可能な知見だけを`knowledge/`へ同期する。

### 作らない重複

同じ情報のactive正本を二つ持たない。次は文書全体へ適用する。

- `docs/**`の一括読込とDomain Canon全件の無条件読込。
- `AGENTS.md`へのDomain Canon、`PROJECT.md`、`STATE.md`本文の複製。
- `PROJECT.md`や`STATE.md`へのDomain文書本文の複製。
- `PROJECT.md`とDomain Canon、`STATE.md`と`PLANS.md`、`ARCHITECTURE.md`と詳細設計文書、
  Project ResearchとRoot Knowledge。

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
├── docs/             # 任意。Domain Canonと詳細文書（構成は次節）
├── inputs/           # Project固有の入力
├── outputs/          # 完成成果物
├── runs/             # 保存価値のある詳細履歴。既定では読まない
├── candidates/       # Project固有の再利用候補
└── scripts/          # Project固有の固定コード
```

新規作成は利用者の明示依頼後に`_template/`をコピーし、すべてのプレースホルダーを書き換える。
`_template/`は`PROJECT.md`と`STATE.md`だけを持ち、他を常設しない。

## Project文書の任意拡張

`ARCHITECTURE.md`、`docs/`、個別`AGENTS.md`、研究文書は、実在する複雑さを段階的に読む必要がある場合だけ
追加する。三層構造、命名、責務、Docs Route、Knowledge昇格は[projects/DOCS.md](DOCS.md)が所有する。

## Attachment

Projectは成果、目的、状態の境界であり、Gitリポジトリは変更権限、自動化、配布、外部接続の境界である。
両者を1対1にしない。agent-directoryは外部repoの集約点ではなく、一体のAgent Workspaceである。

Project root、実装root、通常の作業cwdは、attachmentによらず`projects/<name>/`へ統一する。
違いはpathではなく所有Gitだけである。

- **Embedded** — Git top-levelはAgent Workspace root。`projects/<name>/**`をroot Gitが所有する。
- **Independent** — Git top-levelは`projects/<name>/`自身。直下に実`.git/`を持つ通常cloneである。

worktree、submodule、symlink、`.git` file、外部配置、`repository/`のような下位repo階層を使わない。
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

Agent Directoryはremote操作Toolを持たない。Independentの`origin`はCI、deploy、release、Webhook、
外部共同編集、公開のような外部影響を持ちうるため、対象Projectの契約で扱う。

#### push policy

Projectごとに一度決め、以後push可否を質問しない。値は`auto`と`gated`だけとし、判定は次の優先順で
一意に定める。

1. **宣言** — `projects/<name>/AGENTS.md`の`## Push Policy`が`auto`か`gated`を1語で持つ。
2. **観測** — repository内にCI、deploy、release、publish、Webhookを起動する設定がある場合は`gated`。
3. **既定** — `repository_reason`が`automation`、`distribution`、`access`なら`gated`、
   `collaboration`、`identity`、`upstream`、`retention`なら`auto`。

- `auto` — 検証済みcommitを`origin`へ通常pushし、remoteにSHAが存在することまでAIが自律確認する。
- `gated` — pushにStanding Authorizationを必要とする。現在の依頼が`pushして`まで明示していれば
  それで充足し、追加承認なしで通常pushとremote SHA確認まで行う。authorizationがなければpushだけを止め、
  検証済みローカルcommitを取り消さない。

通常pushがrepository ruleによって「Pull Request必須」という理由だけで拒否された場合は失敗終端にしない。
検証済みcommitをhead branchへ通常pushし、同じauthorizationの範囲でPR作成、expected head SHA確認、
remote platform上のmerge、default branchがそのSHAを含むことの確認まで完了する。PR作成だけをmerge完了として
報告せず、別理由の拒否、check失敗、head移動、divergenceは既存の停止条件として扱う。local checkoutへ
pull / merge / rebaseせず、remote ruleを迂回しない。

default branch反映を確認した後は、PR metadataのhead branch名とexpected head SHAが一致し、対象がdefault branchで
ないことを再確認して、そのsource branchだけをremote platform上で削除し、remote不在を確認する。raw
`git push --delete`の一般解禁やwildcard / pruneは行わない。working treeがcleanなlocal checkoutでは、先に
検証済みremote default branch tipへcheckoutを退避し、local source branch tipがexpected head SHAと一致する場合だけ
そのbranchも削除する。local pull / merge / rebaseでmainを更新せず、branch名・SHA・merge状態の不一致では削除を止める。
PR merge済みでもremoteまたはlocal source branchが残っていれば、この限定経路の完了とは報告しない。

三段で一意にならない場合だけ一度確認し、決まった値を`## Push Policy`へ記録する。判定のための
新しいregistry fieldやfrontmatterを追加しない。

policyによらず、force push、force-with-lease、mirror push、local pull・merge・rebaseによる自動統合、検証前の
push、root sessionからのIndependent remote操作、remote divergenceの自動解消を行わない。

通常のIndependent更新は次の順で進み、安全条件を満たす限り確認を挟まない。

1. `projects/<name>/`のsessionで`projects/AGENTS.md`の手順どおり読込、変更、検証、commitする。
2. push policyに従って`origin`へpushする。PR必須ruleなら上記限定経路でdefault branch反映とsource branch削除まで完了する。
3. branch SHA、default branch反映、remote / local source branch不在、検証結果、未完了をhandoffする。
4. 別のroot sessionが`projects/REPOSITORIES.md`の`revision`だけを更新する。
5. root validatorとcacheを実行してroot Gitへcommitする。

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

状態遷移と削除条件は必要な場合だけ[projects/LIFECYCLE.md](LIFECYCLE.md)を読む。
利用者から間違い、重複、目的不一致、過去決定の見落としを指摘された場合、またはIndependent
repositoryの接続不一致を検出した場合だけ[projects/RECOVERY.md](RECOVERY.md)を読む。

## 検証

- Project固有の検証は`PROJECT.md`の`## 検証方法`に実行手順、合格条件、不合格時の扱い、
  必要な環境変数（キー名のみ）、使用した入力を記す
  （コードの置き場は`tools/TOOLS.md#一時作業`）。
- 外部公開、本番反映、送信、課金、権限変更、`gated`なpushはStanding Authorizationと一意なdestinationを
  必要とする。利用者が同じ操作を明示依頼済みなら追加承認なしで実行する。destination等が曖昧なら
  その不足だけを確認し、内部で完結する検証と修正は止めない。
