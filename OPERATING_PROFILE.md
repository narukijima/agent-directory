# OPERATING_PROFILE.md — Provider-Scoped Operating Profile

Agent Workspaceを複数のAI Providerから利用できる場合に、Provider間の固定分業で目的・文脈・完成責任を
分散させず、利用中のAgentが成果物に適したsurfaceを自律的に選ぶための推奨運用モデルである。
これはReference Architectureであり、新しいRoute、必須Provider、Provider router、またはモデル合格条件ではない。

本テンプレートはOpenAIを主対象として現行surfaceの判断材料を具体化する。Anthropicは独立したProvider familyとして
扱い、OpenAIとの自動分業や自動fallbackを標準経路にしない。

## 適用と優先順位

Providerとsurfaceを決める優先順位は次のとおりとする。

1. Human / Operatorの明示指定
2. Project固有契約
3. taskのprimary deliverableと完了条件
4. 必要なfile、app、browser、repository、local / cloud capability
5. 現在利用可能なProvider / surface

Human / Operatorはultimate authorityである。Project固有approval、安全境界、lifecycle、成果契約は本書より
上位にある。製品名から機械的に経路を決めず、目的、主成果物、必要な道具、review方法、完了証拠をまとめて判断する。

## Operator Runtime Profile

Agent Directory共通のRuntime autonomyは、Provider固有のmode名ではなく次の3段階で宣言する。

| Profile | 実行契約 | 主な利用環境 |
|---|---|---|
| `ask` | 外部作用・高リスク操作でRuntimeのinteractive approvalを比較的積極的に使う。Agent Directoryのsemantic stop条件は変えない | 保守的な対話運用 |
| `auto` | 推奨default。明示taskのscope内にある通常操作をAgentが判断して完遂し、同じ目的・target・destinationをTool call単位で再承認させない。Runtimeが真に危険または曖昧と判定した場合だけ確認する | 通常のAgent Workspace |
| `full` | Runtimeが提供できる最大のfilesystem / network / command能力と最少approvalを使う。Agent DirectoryのRepository integrityとsemantic safetyは維持する | dedicated / isolated machine |

未指定時は`auto`を推奨するが、Agent DirectoryはOperatorのRuntime設定を変更しない。`ask / auto / full`は
Runtimeへの要求と運用意図であり、現在のcapabilityを観測した証拠ではない。Operator / Runtimeはprofileを選び、
実際のsandbox、approval、filesystem、network等を提供する。Agentは与えられた能力内で最大限進め、Agent Directoryは
意味的安全とWorkspace integrityだけを判定する。

profileはtask capabilityの固定集合ではない。必要capabilityはtaskごとに`filesystem_read`、`filesystem_write`、
`network`、`localhost`、`process_spawn`、`git`、`github`、`browser`、`api`から宣言し、実測可能なものだけを
`observed`、Runtimeが提供を宣言した未実測値を`declared`、未検査を`not-probed`、既知の不一致を`unavailable`とする。
`full`だからGitHubが必要、`ask`だからlocal editが不可、という推論をしない。

## Standing Authorizationと通常完遂

明示されたtaskは、同じobjective、scope、target、destinationで完了に必要な通常工程へのStanding Authorizationである。
read / search、file create / edit / move、mkdir、package install / update、build / test / lint / format、local server、
localhost / network / public documentation / API、Git add / commit / branch、設定済み通常GitHub finish、明示された
deploy / publishの通常工程を、操作ごとの追加approvalへ分解しない。Runtimeが許可済みで、target / destinationが一意、
Project契約とsemantic safetyに衝突しないなら、Agent自身も「念のため」の再確認を追加しない。

target / destination / credential、目的、不可逆対象、lifecycle、secret、予期しない課金、ownership、credential scope、
Project契約、divergence、Single Writer、正本のいずれかが一意でない場合だけ、人間が決める不足一点へ上げる。
`full`でもこの条件は消えず、`ask`でも既に一意な依頼をAgent Directoryが独自に再承認させる理由にはならない。

## Core契約

長期的な運用契約は次のとおりである。

```text
one task → one provider family → one final owner
```

- 一つのtaskは原則として一つのProvider family内で完了させる。
- primary deliverableに一人のfinal ownerを置き、複数surfaceを同時final ownerにしない。
- Provider側memoryや会話履歴ではなく、RepositoryとProject成果契約をcanonical stateにする。
- surface選択は品質を上げる既定判断であり、製品名だけをvalidatorの永久的な成功条件にしない。
- publish、API mutation、ID、retry、schema validation、永続化は決定的Toolへ委ねる。
- Runtime PermissionはOperator / Runtime側が所有し、Provider別permission wrapperを追加しない。

## Providerの選択と分離

明示されたProvider、または現在taskを開始したProvider familyが、そのtaskのobjectiveと完了責任を保持する。
別Providerの方が得意そうだという推測だけで、Providerをまたぐ自動delegateと自動fallbackを行わない。

OpenAIとAnthropicを同時に利用できても、一つの仮想チームとして固定分業させない。別Providerを使うのは、
Humanの明示指定、Project契約、独立した比較・review、または明示的な所有権移管がある場合だけである。
外部API、DB、browser、決定的Toolを使うことはProvider移管ではない。推論とfinal ownershipを誰が持つかで判定する。

## 自律的なSurface選択

Agentは依頼文の語ではなくprimary deliverableからsurfaceを選ぶ。次を判断材料にし、必要なsurfaceを自律的に選択する。

- 完成物は回答、会話、file、report、presentation、code、commit、PRのどれか。
- 単発生成か、複数工程と途中状態を持つworkか。
- local file / app / browserが必要か、cloud継続が必要か。
- repository、Git、test、diff、technical reviewが中心か。
- Projectのacceptance criteriaをどのsurfaceで最も直接検証できるか。

surface mappingは硬い禁止表ではない。現在surfaceが必要capabilityを持ち、Projectの品質基準と完了証拠を満たせるなら、
Agentはそのsurfaceで完了してよい。別surfaceの方が明確に適する場合は理由と期待成果を示し、handoffまたは切替を選ぶ。
直接起動できないsurfaceへ仕事を送った、開始した、完了したと推測してはならない。

## OpenAI Provider Profile

OpenAIを利用するtaskでは、現行の公式区分を初期判断として次を使う。

| Surface | 主な用途 | 選択の目安 |
|---|---|---|
| Chat | 質問、相談、比較、短いdraft、要約、ワンショット生成・編集 | その場の対話や短い返答が主成果物 |
| ChatGPT Work | 調査、分析、複数工程、file、document、spreadsheet、presentation等の完成成果物 | review可能な成果物まで作ることが主目的 |
| Work Local | local file、app、browserを使うwork | Operatorのmachine上のcontextが必要 |
| Work Cloud | 長時間・継続・scheduled work | machineを閉じても継続する必要がある場合に利用可能なら選択 |
| Codex | codebase理解、実装、Git、test、diff、PR、technical review | software / repository変更が主成果物 |
| Voice | Chat、Work、Codexの開始、確認、追加指示を行うruntime-native coordination | 利用可能なDesktop機能として使い、Core APIとはみなさない |
| OpenAI API / Workspace Agent | Project固有のprogrammatic workflow | 公開・実装済みの契約がある場合だけ利用 |

現行区分の根拠はOpenAIの
[Use ChatGPT](https://learn.chatgpt.com/docs/use-chatgpt)、
[Get started with ChatGPT Work](https://learn.chatgpt.com/docs/get-started-with-work)、
[ChatGPT Voice](https://learn.chatgpt.com/docs/features/voice)、
[Codex SDK](https://learn.chatgpt.com/docs/codex-sdk)を参照する。

CodexをWorkspace全体の恒久的なControl Planeには固定しない。CodexはOpenAI family内のdeveloper / technical
surfaceであり、Work向けtaskの入口になった場合は、現在capabilityで品質基準を満たして完了するか、最小handoffを
準備してWorkへ切り替えるかを判断する。公開された直接dispatch契約がないsurfaceを自動spawnする前提を置かない。

## 複合タスクとSingle Owner

codeとreport、調査と画像、実装とpresentationのような複合taskでは、primary deliverableを一つ決める。

- 動作するsoftware、repository change、test済みcommitが主成果物ならCodexをowner候補とする。
- document、analysis、spreadsheet、presentation等のreview可能な業務成果物が主成果物ならWorkをowner候補とする。
- 会話、判断材料、短いdraft、単発生成が主成果物ならChatをowner候補とする。

別surfaceの出力はownerへ渡す候補・asset・evidenceであり、それだけでcanonical stateにならない。final ownerが
Project成果契約、検証、保存境界を通して統合する。内部subagentを使う場合もfinal ownerとSingle Writerは変えない。

## Anthropic Provider Profile

Anthropicを選んだtaskは、Claude、Claude Code、Anthropic API等のAnthropic family内で完了させる。
OpenAIを自動worker、reviewer、fallbackとして呼ばない。Anthropic内部のsurface mappingは現行公式仕様、
Humanの指示、Project契約、primary deliverableに基づいて選び、本CoreがOpenAIとの見かけ上の対称性を推測して固定しない。

Claude Codeから開始したtaskでも、Anthropic family内でobjective、primary deliverable、completion evidenceを保持する。
別Providerが必要になった場合は、通常delegateではなく後述する明示handoffとして扱う。

## Cross-provider Handoff

Providerをまたぐのは次の場合だけである。

- Human / Operatorが明示した。
- Project契約が特定Providerまたは独立reviewを要求する。
- 比較、批評、red-team等を別Providerの独立taskとして実行する。
- 現在ownerがstateを確定し、HumanまたはProject契約に沿って所有権を明示移管する。

handoffの最小候補は次である。

```text
objective / primary deliverable / requested provider / current owner / target
canonical inputs / completed work / remaining work / constraints
file and Git state / external effects / receipts / uncertainties
acceptance criteria / completion state
```

受取側が実際に開始した証拠がない限り、handoffを実行中または完了と報告しない。review目的の別Provider出力は
候補または証拠であり、元のfinal ownerが採否を判断する。

## AvailabilityとRecovery

executable unavailable、authentication unavailable、startup failure、runtime outage、infrastructure timeout等では、
まず同じProvider family内で状態を再観測し、意味のある再試行、resume、利用可能な別surfaceを検討する。
surfaceを変える場合もprimary deliverable、actual owner、既存outputを明示する。

Runtimeのsandbox / network / filesystem拒否、Agent Directory local policyのallowlist拒否、external providerの
authentication / authorization拒否、Repository integrity停止を同じProvider availability failureへまとめない。
停止・未完了は少なくとも`runtime`、`agent-directory-local-policy`、`external-provider`、`repository-integrity`、
`project-contract`、`network-service`の発生層に分け、観測できた層だけを報告する。
同じfailure fingerprintはruntime permission、cwd / Git root、target、remote、credential source、allowlist、network、
Tool path、provider stateのいずれかが変わるまで再試行しない。

Provider family全体が利用不能なら、別Providerへ自動fallbackしない。file changes、Git state、生成output、external
side effects、publish / send / API mutation、receipt、idempotencyを照合し、未完了と次の一手を報告する。
必要ならCross-provider Handoff packageを準備し、移管はHumanまたはProject契約の選択後に行う。

品質不足、成果物の検証失敗、通常のtask failureはavailability failureではない。surfaceやProviderを変えて隠さず、
既存のself-repair、acceptance criteria、verification、停止・報告契約に従う。

## Deterministic Execution Layer

LLMが判断する必要のないAPI request、publish、fetch、metrics収集、schema validation、date / time / timezone計算、
ID生成、重複検知、idempotency、state serialization、DB更新、file変換、retry policy、locking、protocol実装は、
既存のPython、shell、API、DB、決定的Toolをprimary ownerとする。

Agentはprotocolを曖昧に再現せず、Toolを選び、入力、destination、結果、失敗、receiptを確認する。決定的Toolは
Provider familyの一員ではなく、共通Coreのexecution capabilityである。

## Repository State

Repositoryのtracked canonical stateを、会話履歴、Provider側memory、検索cache、runtime stateより優先する。
Providerやsurfaceの出力は候補または証拠であり、既存Route、成果契約、検証を通して統合したものだけが
canonical stateになる。Providerを切り替えても、並行する正本を作らない。

## Scheduled Execution

scheduleはAgent内部のRoute、Executor、成果分類、reasoning systemではなく、通常taskを開始する外部triggerである。
起点がHumanでもscheduled triggerでも、Agent内部は同じ`Route → Target → Work → Verify → Finish`、Project契約、
Single Writer、安全境界を使う。

第一選択は選択中Provider / Productが提供する`Runtime-native scheduler`である。利用できない、利用しない、または
OperatorがOS-native executionを選ぶ場合だけ、macOSの`launchd`、Linuxの`systemd timer`、Unixの`cron`を
外部triggerとして使える。設定と運用はOperatorまたは対象Projectが所有する。
このrepositoryはScheduler Engine、daemon、schedule registry、Provider別adapterを実装しない。

scheduled taskも一つのProvider familyとfinal ownerを持つ。認証失敗やruntime unavailable時に別Providerへ自動移管せず、
同じProvider内のrecovery、state照合、停止・handoffを通常契約に沿って行う。

## 変更耐性

OpenAIやAnthropicの製品名、surface、model、dispatch capabilityは変化し得る。current mappingは本書だけで管理し、
Core route、Project合格条件、permission wrapper、adapterへ複製しない。公式仕様が変わった場合は、実際のcapabilityを
再確認し、本書のProvider Profileだけを最小更新する。

新しい製品機能を採用するために、独自Provider router、workflow engine、queue、RPC、daemonをCoreへ追加しない。
Runtime-native coordinationで目的を満たせない具体的なProject要件が確認された場合だけ、そのProjectが実装を所有する。

## 要約

> 一つのtaskは一つのProvider familyと一人のfinal ownerが完了まで所有する。
> Runtime autonomyは`ask / auto / full`からOperatorが選び、推奨defaultは通常作業を完遂する`auto`とする。
> OpenAIではChat、Work、Codexをprimary deliverableに応じて自律的に選ぶ。
> AnthropicはAnthropic family内で完結し、Providerをまたぐ自動分業・自動fallbackを行わない。
> RepositoryとProject成果契約が品質の正本であり、Humanがultimate authorityである。
