# OPERATING_PROFILE.md — Recommended Multi-AI Operating Profile

複数のAI runtimeと決定的Toolを利用できるAgentが、役割分担を毎回ゼロから設計し直さないための
推奨責任モデルである。これはReference Architectureであり、Runtime Permission、必須Provider、
モデル合格条件、または新しいRouteではない。利用者の明示指示とProject固有契約が常に優先する。

## 適用と優先順位

複数runtimeが利用可能でtaskに利益がある場合、このProfileを初期案として使う。単一runtimeしかない場合、
小さなtask、画像を必要としないtask、または利用者が別構成を指定した場合は、利用可能な主体へ責務を統合してよい。

役割を決める優先順位は次のとおりとする。

1. Human / Operatorの明示override
2. Project固有契約
3. 本書のRecommended Profile
4. 実際に利用可能なcapability

代替Providerや別モデルへsilent fallbackしない。推奨から外れるときは、変更した役割、primary owner、
利用するcapabilityを作業記録またはhandoffで明示する。Human / Operatorはultimate authorityであり、
Project固有approval、安全境界、lifecycle、成果契約は本書より上位にある。

## Capability Role

長期的な責任構造は製品名ではなくcapabilityで定義する。現在の推奨mappingは次のとおりである。

| Capability role | Primary ownerの現在推奨 | 主な責務 |
|---|---|---|
| Control Plane | Codex | 目的解釈、戦略、計画、分解、worker選択、横断調整、状態確認、評価、final gate、学習更新 |
| Creative / Production Worker | Claude Code | 調査、情報探索、企画、編集、執筆、構成、候補生成、creative brief、Project固有の深い制作 |
| Visual Worker | ChatGPT（optional external worker） | 画像生成・編集、visual composition、social / carousel画像、visual conceptの実制作 |
| Deterministic Execution Layer | Python、shell、API、DB、既存Tool | protocol実行、検証、永続化、冪等性、時刻・ID・lock・retryなどの決定的処理 |

製品やモデルが変わっても、責任構造を保ってcapabilityに合うruntimeへmappingを更新できる。
Provider抽象framework、runtime registry、queue、RPC、daemonをCoreへ追加する根拠にはしない。

## 推奨Control Plane

Codexを利用できる複数runtime環境では、Codexをoperational chiefとすることを推奨する。

> Think globally / delegate locally / verify centrally.

Codexは全体戦略、優先順位、planning、task decomposition、orchestration、worker選択、Project横断調整、
repository stateの確認、成果物検査、評価、final gate、learning loop、次回戦略、scheduled AI workflowの
上位統括をprimary responsibilityとする。制作、visual work、決定的protocolをすべて自身で抱え込まず、
taskとcapabilityが適合するownerへ渡し、結果を中央で統合・検証する。

Codexだけが利用可能ならproductionまで担当してよい。利用できない場合は、Projectが指定したruntime、
または必要な計画・統合・検証capabilityを持つruntimeがControl Planeを兼任できる。

## 推奨Creative / Production Worker

Claude Codeを利用できる場合、文章、編集、企画、調査、コンテンツ制作の主力workerとして推奨する。
research、information foraging、source investigation、idea generation、creative exploration、editing、
copywriting、article / SNS writing、storytelling、structure development、content planning、比較案、
creative / visual brief、Project固有の深い制作をobjectiveとconstraintsの範囲で所有する。

標準関係は、Control Planeがobjective・constraints・必要contextを渡し、Claude Codeがresearch・production・
candidatesを返し、Control Planeが評価・選択・次のactionを決める形である。Claude Codeしか利用できない
環境では、同じruntimeがControl Planeも兼任できる。workerは委譲範囲を越えて全体戦略や正本を独自に
変更しない。

## 推奨Visual Worker

画像生成または画像編集が必要でChatGPTを利用できる場合、optional Visual Workerとして推奨する。
ChatGPTはimage generation、image editing、visual composition、creative visual production、social image、
carousel、visual concept executionを担当できる。

このテンプレートはChatGPT runtime adapterや自動連携を提供しない。直接呼び出せない環境では、Control Planeが
visual requirementを決め、Creative Workerがcreative / visual briefを作り、利用者またはProject固有経路が
ChatGPTへhandoffし、出力をControl Planeへ戻す。画像が不要ならVisual Workerを置かない。

## Deterministic Execution Layer

LLMが判断する必要のないことをLLMへ委ねない。API request、publish、fetch、metrics収集、schema validation、
date / time / timezone / DST / business-day計算、ID生成、重複検知、idempotency、state serialization、
DB更新、file変換、deterministic quality gate、retry policy、locking、protocol実装は、既存のPython、shell、
API、DB、決定的Toolをprimary ownerとする。

Control Planeはprotocolを曖昧に再現する主体ではなく、必要なToolを選び、入力・destination・結果・失敗を
確認する主体である。外部作用、秘密、Runtime Permissionは`AGENTS.md`と各Project契約の既存境界に従う。

## OrchestratorとWorkerの最小契約

AI間のhandoffは会話の暗黙状態だけに依存せず、taskに必要な範囲で次を構造化する。巨大なworkflow engineや
全項目必須のschemaをCoreへ導入せず、Project固有実装があればそれを使う。

依頼側の最小候補:

```text
task_id / objective / owner / target / context / constraints
required_output / sources / deadline / state / evaluation_criteria
```

返却側の最小候補:

```text
result / candidates / evidence / claims / uncertainties
assets / recommended_choice / validation
```

責任は`one responsibility → one primary owner → optional collaborators`とする。CodexとClaude Codeの双方を
final ownerにせず、同じschedule、production job、state更新を重複所有させない。委譲は
`tools/CONTROL.md#委譲の境界`に従い、同一Git rootのWriterとfinal gateを一つに保つ。

## Repository State

Repositoryのtracked canonical stateを、会話履歴、Provider側memory、検索cache、runtime stateより優先する。
複数AIは同じ正本を参照し、各製品の独立した「記憶」をglobal stateや並行する正本にしない。workerの出力は
候補または証拠であり、primary ownerが既存Route、成果契約、検証を通して統合したものだけがcanonical stateになる。

## Scheduled WorkflowとRoutineの境界

二つのschedule責任を混同しない。

### Core Maintenance Routine

`routines/ROUTINES.md`が所有するOptional Trigger Layerである。cron / launchdが起動時刻、既存executorが
deterministic maintenance、必要な場合だけoptional reasoningを所有する。AI製品固有SchedulerやCodexを
Core実行基盤にせず、現在のMaintenance契約を維持する。

### Business / Creative / Autonomous Workflow

定期市場調査、SNS・メディア運用、コンテンツ制作、定例分析、recurring research、日次・週次planningなど、
AI判断を伴う継続Projectがscheduleを必要とする場合のProject-level設計である。Codexを利用できるなら、
planning・strategy・worker選択・評価を担う上位scheduled orchestratorとして推奨し、Claude Code、ChatGPT、
決定的Toolへ必要な作業を渡せる。

本書はscheduleの導入を要求せず、テンプレートへ既定scheduleを登録しない。実際のtrigger、credential、
Single Writer、出力、失敗処理は対象Projectの契約に置き、Maintenance Routineを置き換えない。

## Current Model Recommendations

Role contractは上記の長期原則であり、modelは交換可能なcurrent recommendationである。現在の推奨値は
この節だけで管理し、validator、eval、adapter、Project合格条件へ複製または固定しない。

| Role | Current recommendation | Reasoning / Effort | 主用途 |
|---|---|---|---|
| Control Plane | Codex 5.6 Sol | Medium | orchestration、planning、strategy、coordination、evaluation、final gate、scheduled AI workflow |
| Creative / Production Worker | Claude Opus 5 | High | research、production、editing、writing、creative work、deep content development |

利用者は別モデルを選べる。モデル更新時はこの節の推奨値だけを更新し、Role contract、Core compatibility、
validator合否を変更しない。

## 要約

> Codexは考え、統括する。Claude Codeは調査し、編集し、制作する。ChatGPTはvisualを生成・編集する。
> 決定的Toolはprotocolを実行する。Repositoryはcanonical stateであり続け、Humanがultimate authorityである。
