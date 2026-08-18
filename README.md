# agent-directory

長期稼働するAIエージェント1体ごとに持つ、ローカルファーストのAgent Workspaceテンプレート。
Knowledge、Skill、Projectを正本として育てながら、1タスクの読込量は総量から切り離す。

これは複数の外部リポジトリを束ねる集約点ではなく、一体のAgent Workspaceである。独立したremote identityが
必要なProjectも、cloneはこのツリー内の`projects/<name>/`へ置く。

`AGENTS.md`は百科事典ではなく、ブートローダー兼ルーター兼目次である。Routeを一つ決めたら、その領域を
所有する正本へ引き継ぐ。詳細契約は各正本が持ち、READMEはそこへの入口だけを持つ。

## 公開製品の契約

本製品の継続的使命は、一体のAgentごとに検証可能で移植可能なdurable Agent Workspace仕様と決定的Toolを
提供することである。公開製品として次を安定した合格条件とする。

- Workspaceのidentity、Knowledge、Skill、Project、Runtime Permissionの責務境界が正本と実装で一致する。
- 通常検証と対象変更のtestが、外部AIやHosted CIを必須にせず決定的に合格する。
- 利用者がテンプレートからAgentを導入し、一般Projectを`PROJECT.md` / `STATE.md`で管理できる。
- Independent repositoryを別Git・別remoteのままmaterializeし、固定revisionで再現・検証できる。

本製品は複数製品のmonorepo、Runtime独自のsandbox / approval database、Provider別permission wrapper、
Scheduler Engineを所有しない。公開仕様、テンプレート、validator、test、fixture、互換性契約、利用者向け文書を
このrepositoryが所有し、特定Owner Agentの現在目標、優先順位、次の一手、長い運用履歴は所有しない。

## 利用開始

1. このリポジトリをエージェント1体につき1つコピーまたはクローンする。
2. [AGENTS.md](AGENTS.md)の`<agent-name>`、役割、使命、ビジョン、`<operator-language>`（運用者応対言語）を置換する。
   Agent名・役割はbacktickを保ったまま置換する。自己定義の名乗り行（`- あなたは…`）のbacktick語だけが
   上流報告の匿名化遮断語になり、応対言語・使命・ビジョンは遮断語にならない。
3. `skills/_template/`または`projects/_template/`を、明示された必要に応じてコピーする。
4. [SETUP.md](SETUP.md)に従ってmachine-localなruntime、認証、Workspace Trust、preflightを準備する。
5. `bash tools/install-git-hooks.sh --install`でcommit・push境界の検査hookを導入する。
6. `bash tools/validate-agent-directory.sh --strict --full`を実行する。
7. `tools/find-context.sh --route <route> --limit 5 -- "検索語"`で対象候補を絞って運用する。

テンプレートのままではプレースホルダーが残るため、通常の検証は合格し、`--strict`は導入完了まで失敗する。

## 設計方針

- 通常経路は`Route → Target → Work → Verify`に固定し、`tools/task.sh`を共通入口にする。
- 常時守る安全境界は[tools/SAFETY.md](tools/SAFETY.md)の6項目だけとし、実装詳細は条件付きで読む。
- 明示依頼を同じ操作のStanding Authorizationとして扱う。target / destinationが一意でsemantic safetyを
  満たす公開、送信、通常push、削除は追加承認なしで完了し、曖昧性と整合性の不足だけを人間へ確認する。
- Provider非依存のOperator Runtime Profileは`ask / auto / full`とし、通常の推奨defaultは`auto`にする。
  ProfileはRuntime設定を強制せず、task別capabilityの`observed / declared / not-probed / unavailable`と分離する。
- リポジトリ内の正本を会話記憶、製品側AIメモリ、検索結果より優先する。
- `raw/internal/`と`raw/external/`の既存原資料は同じ強さで保護し、変更・削除しない。
- 完了・停止・廃止を物理archiveで表さず、frontmatterの状態で検索から除外する。
- 全件台帳をLLMへ渡さず、状態付きの決定的検索で候補を絞る。
- 派生catalogと自動生成DBは削除・再生成可能とし、恒久参照先にしない。
- ベクトルDB、常駐サービス、CI、外部課金は既定で導入しない。

## Route

Routeの区分と対象は[AGENTS.md](AGENTS.md#route)が正本である。本表は入口へのリンクだけを足す。

| Route | 対象 | 着手後に読む正本 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) |
| `skill` | 再利用手順・研究方法 | [skills/SKILLS.md](skills/SKILLS.md)と対象`SKILL.md` |
| `project` | 固有作業・成果物・研究 | [projects/AGENTS.md](projects/AGENTS.md)、対象`PROJECT.md`、`STATE.md` |
| `meta` | 構造、規約、eval、tool | 対象領域の大文字正本と変更対象 |
| `none` | 永続変更のない回答 | 追加ロードなし（一時作業の中間物は`.tmp/`） |

## 構造

固定ファイルは大文字名、利用者が作るKnowledgeページとProjectの詳細文書は小文字ケバブケースとする。

```text
agent-directory/
├── AGENTS.md                     # ブートローダー兼ルーター兼目次
├── CLAUDE.md                     # @AGENTS.md
├── SETUP.md                      # Operator / machine側setupの正本
├── OPERATING_PROFILE.md          # Provider分離とOpenAI surface選択の推奨運用モデル
├── .codex/environments/          # Codex DesktopのLocal Environment
├── .claude/settings.json         # Claude Codeの共有project hook
├── .agent-cache/                 # Git管理外の派生物
├── knowledge/
│   ├── KNOWLEDGE.md
│   ├── raw/{internal,external}/  # 不変の原記録と原資料
│   └── wiki/
│       ├── INDEX.md              # 小型ルートマップ
│       ├── LOG.md                # 現在の変更履歴。既定では読まない
│       ├── logs/                 # 閉鎖済みの不変ログ
│       ├── _template/            # SOURCE.md / TOPIC.md
│       ├── sources/              # 一つの原資料を解釈したKnowledge
│       └── topics/               # 複数の根拠や判断を統合したKnowledge
├── skills/
│   ├── SKILLS.md
│   └── _template/                # SKILL.mdとagents/だけ
├── projects/
│   ├── AGENTS.md                 # Project作業共通の薄い入口
│   ├── CLAUDE.md                 # @AGENTS.md
│   ├── PROJECTS.md               # Projectシステムの詳細正本。条件付きで読む
│   ├── REPOSITORIES.md           # Independent Projectのattachment registry
│   ├── .gitignore                # registryから導出するignore projection
│   ├── LIFECYCLE.md              # 状態遷移時だけ読む
│   ├── RECOVERY.md               # 目的不一致の復旧時だけ読む
│   ├── _template/                # PROJECT.mdとSTATE.mdだけ
│   └── <project-name>/           # PROJECT.md、STATE.md、任意のAGENTS.md・docs/・inputs/・outputs/
├── evals/                        # EVALS.md、TRACE.md、cases/、fixtures/、profiles/
└── tools/                        # task.sh、SAFETY.md、THREAT_MODEL.mdほかTool正本
```

## ローカル実行環境

`AGENTS.md`を共通の判断規約、`tools/`を決定的処理の正本とし、AIクライアント固有設定は薄いadapterにする。

| 層 | 共有入口 | 責務 |
|---|---|---|
| 共通 | `AGENTS.md` / `tools/setup-local-environment.sh` | 規約と冪等な初期化 |
| Codex Desktop | `.codex/environments/agent-directory.toml` | worktree作成時のSetupと共通Actions |
| Claude Code | `.claude/settings.json` | 新規`SessionStart`から同じSetupを呼ぶ |

setup、認証、Workspace Trust、runtime preflightの詳細は[SETUP.md](SETUP.md)が所有する。共通Setupは
`bash`、`git`、`python3`とGit rootを確認し、Git管理外の検索cacheを生成する。
`--git-author-name`または`AGENT_DIRECTORY_GIT_AUTHOR_NAME`の明示overrideがあれば適用し、なければ既存の
repo-local `user.name`を保持する。local値も未設定のときだけ`AGENTS.md#自己定義`の推奨Agent名を
既定値にする。emailと既存履歴は変更しない。既存cacheが新鮮なら本文を再読しないfast pathを使う。
`.env*`のコピー、package追加、
Git hook・remote・scheduleの変更、ネットワーク接続は行わない。Git hookと、設定済みGitHub backupを持つ
Workspaceのmachine認証Gateは[SETUP.md](SETUP.md#initial-setup)の明示コマンドとして分離する。CodexのActionsは限定検証、full検証、hook状態確認を
既存Toolへ直接つなぎ、GitHub認証状態は既存の`tools/setup-github-auth.sh --check`へ明示的に接続する。
GitHub認証Actionは実APIと実remoteを検査するが、共通local Setupからは呼ばない。初回machine setupでは
GitHub backup構成に限って正本手順から実行し、判定ロジックをadapterへ複製しない。
Claude Codeの`.worktreeinclude`も既定では置かず、
`.env*`などGit管理外ファイルをworktreeへ複製する必要が確認されたWorkspaceだけで個別に設計する。

### Provider-Scoped Operating Profile

一つのtaskは原則として一つのProvider familyと一人のfinal ownerが完了まで所有する。OpenAIを主対象とし、
Chatは対話・ワンショット、ChatGPT Workは複数工程とreview可能な完成成果物、Codexはsoftware・repository・
technical workを初期判断とする。ただし製品名による硬い禁止表にはせず、Humanの明示指定、Project契約、
primary deliverable、必要capability、acceptance criteriaからAgent自身がsurfaceを選ぶ。

Anthropicを選んだtaskはAnthropic family内で完結させる。OpenAIとAnthropicを固定分業させず、Providerをまたぐ
自動delegateと自動fallbackを行わない。明示handoff、Single Owner、partial executionの照合、Scheduled Execution、
Runtime-native coordinationの境界は[OPERATING_PROFILE.md](OPERATING_PROFILE.md)が所有する。

## Attachment境界

Project root、実装root、通常の作業cwdは、EmbeddedでもIndependentでも`projects/<name>/`である。違いは
pathではなく、どのGitがそれを所有するかだけである。すべてのProjectはEmbeddedで開始し、独立したremote
identityが必要になった場合だけIndependentへ昇格する。worktree、submodule、symlink、`.git` file、
外部配置、下位の`repository/`階層は使わない。

```text
projects/<embedded-project>/      # Git top-level = Agent Workspace root
├── PROJECT.md                    # root Gitが全体を追跡する
├── STATE.md
├── ARCHITECTURE.md               # 任意
├── docs/                         # 任意
└── outputs/

projects/<independent-project>/   # Git top-level = このディレクトリ自身
├── .git/                         # 実directory。普通のclone
├── PROJECT.md                    # Project固有Gitが全体を追跡する
├── STATE.md
├── AGENTS.md / ARCHITECTURE.md / docs/
└── src/ tests/ …
```

root側の正本は`projects/REPOSITORIES.md`のattachment registryだけで、`projects/.gitignore`のmanaged block
はその派生projectionである。所有境界の完全な表、昇格条件、`repository_reason`、session rootとSHA handoff、
remote操作の境界とpush policy（`auto` / `gated`）は[projects/PROJECTS.md](projects/PROJECTS.md)が所有する。

Owner Agentがこの公開テンプレートや再利用Capability配布元のような公開基盤製品を開発する場合は、registryへ
`repository_role: public-foundation`を明示する。製品repositoryは公開目的、仕様、repository-local規約、検証、
配布文書を所有し、Owner Agent固有の現在目標、優先順位、次の一手、到達履歴はOwner Agent rootの単一active正本が
所有する。一般Projectの`PROJECT.md` / `STATE.md`契約は変わらず、公開基盤製品だけを`meta` Routeで扱う。

```bash
bash tools/materialize-project-repositories.sh --all --check
bash tools/materialize-project-repositories.sh --all
bash tools/materialize-project-repositories.sh --project <name>
```

> [!WARNING]
> 登録済みIndependent Projectはroot Gitからignoreされるため、rootでの破壊的な`git clean`は
> それらの未コミット作業やcloneを不可逆に失わせうる。`git clean`の禁止条件は
> [tools/BACKUP.md](tools/BACKUP.md)が所有する。

## コンテキスト探索

```bash
# active Knowledgeを最大5件
tools/find-context.sh --route knowledge --limit 5 -- "資本配分"

# 明示的な監査時だけ非activeも含める
tools/find-context.sh --route project --include-inactive -- "site migration"

# 対象確定後の通常入口
tools/task.sh context --route project --target projects/<name>
tools/task.sh context --route meta --target tools/TOOLS.md
```

`context`とローカル探索・編集・検証は、設定済みGitHub remoteやcredentialの状態から独立して開始する。
Agent固有の環境変数・secret・API token・外部サービス設定はすべてAgent Workspace rootの`.env`が所有し、OS home、
machine共通store、Keychain、別Workspace、global process environmentを正本にしない。各Toolは
`tools/lib/agent-env.sh`で必要なkeyだけを非実行parseし、`.env`全体をsourceしない。GitHub操作は同じrootの
`GH_TOKEN`だけを子processへ限定注入し、別Agentのcredentialへfallbackしない。導入と実probeは
`setup-github-auth.sh --install-token` / `--workspace-ready` / `--check`を使う。境界は
[Agent-scoped environment threat model](tools/THREAT_MODEL.md)を参照する。

明示パスと正本の明示参照を最優先とし、検索結果は候補として扱う。選択後に正本を読む。
`.agent-cache/`は正本から再生成され、検索のstale回復はrouting catalogだけを一度作り直す。
manifest（全体inventory）はfull検証とboundary作業だけが再生成する。
探索順位は[tools/TOOLS.md](tools/TOOLS.md)、実行時の読込予算は[AGENTS.md](AGENTS.md)、
固定Toolの呼び出し形・入出力・fallbackは[tools/REFERENCE.md](tools/REFERENCE.md)が所有する。

## 検証

```bash
tools/task.sh verify                                      # 通常入口
bash tools/validate-agent-directory.sh --changed          # 互換・直接実行
bash tools/validate-agent-directory.sh
bash tools/validate-agent-directory.sh --strict --full
bash tools/validate-agent-directory.sh --full --base main
python3 tools/run-evals.py score --case <case> --trace <trace.jsonl>
```

validatorは構造、`AGENTS.md`と`CLAUDE.md`の三層、frontmatter、Project契約、状態、Project docsの境界と
命名、参照上限、サイズ、INDEX、LOG、eval schema、派生cacheの決定的再生成、禁止されたGit追跡を検査する。
`--changed`は変更されたProject・Knowledge・Skillだけを検査し、baseline未指定ならHEAD、タスク開始SHAが
あるなら`--base <sha>`で開始点からworking treeまでを検査する。不変原資料・閉鎖済みlogの編集や削除、
Knowledgeページの削除は通常workとして通らない。meta正本への変更は全体静的検査へ自動fallbackする。
依存関係、CI、GitHub接続を必要としない。
行動evalは[evals/EVALS.md](evals/EVALS.md)のtrace契約を`tools/run-evals.py`で採点できる。外部AIは
必須ではなく、観測されていない期待は自己申告でPASSにせず`UNVERIFIED`に残す。

commit・push境界は`tools/check-boundary.sh`と導入済みgit hooksが機械的に強制する。通常変更と
protected変更の分離、検証、Independent repositoryへの適用は
[tools/CONTROL.md](tools/CONTROL.md)だけが所有し、停止時または境界保守時に読む。

## CoreとOptional

Coreは`AGENTS.md`、Route正本、`tools/task.sh`、validator、[tools/SAFETY.md](tools/SAFETY.md)である。
通常タスクはこの範囲だけで開始できる。backup、GitHub認証repair、Independent repository、
behavioral eval、上流Issue報告はOptional capabilityであり、該当機能を使うときだけ正本とToolを読む。

既存consumerとの互換性のため`tools/prepare-context.sh`と`tools/finalize-task.sh`は残すが、新しい通常入口を
増やさない。分類と所有先は[tools/TOOLS.md](tools/TOOLS.md)、個別CLIは
[tools/REFERENCE.md](tools/REFERENCE.md)が所有する。

## Scheduled Execution

定期実行が必要なら、第一選択として利用中Productの`Runtime-native scheduler`、fallbackとして
`launchd` / `systemd timer` / `cron`をOperatorまたは対象Projectが設定する。scheduled triggerは通常taskを
起動するだけで、別Route、別Executor、別commit lifecycleを作らない。このrepositoryは既定scheduleや
Scheduler Engineを持たない。詳細と交換可能なcurrent mappingは
[OPERATING_PROFILE.md](OPERATING_PROFILE.md#scheduled-execution)が所有する。

## ローカル正本とGitHubバックアップ

ローカルが稼働正本、GitHubは受動的な復旧コピーである。backupはOptional capabilityであり、設定済みの
タスク境界でだけ`tools/backup-to-github.sh`を使う。認証、scope、divergence、復旧、Single Writer、
`git clean`の禁止は[tools/BACKUP.md](tools/BACKUP.md)が所有する。

```bash
bash tools/setup-github-auth.sh --check
bash tools/backup-to-github.sh --dry-run
```

Toolは前提違反ならremoteを変更せず停止する。backup失敗は検証済みlocal commitを取り消さず、
`local task`、`local commit`、`backup`、`recoverability`を分けて報告する。

## 正本

| 正本 | 所有する内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 自己定義、共通判断原則、Route判定、Context Loading、自律実行と例外、禁止事項、目次 |
| [OPERATING_PROFILE.md](OPERATING_PROFILE.md) | Provider分離、OpenAI surface選択、明示handoff、Single Owner、recovery、Scheduled Execution |
| [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) | 四層構造、保存先、不変規則、命名、限定取得、INDEX、LOG |
| [skills/SKILLS.md](skills/SKILLS.md) | Skillの選択、frontmatter、Knowledge参照、構造 |
| [projects/AGENTS.md](projects/AGENTS.md) | Project作業共通の着手・実行・完了手順 |
| [projects/PROJECTS.md](projects/PROJECTS.md) | 成果契約、attachment、push policy、PROJECT / STATE schema |
| [projects/DOCS.md](projects/DOCS.md) | 任意のProject docs、Domain Canon、Docs Route、Research昇格 |
| [projects/REPOSITORIES.md](projects/REPOSITORIES.md) | Independent Projectのattachment registryとentry形式 |
| [projects/LIFECYCLE.md](projects/LIFECYCLE.md) / [projects/RECOVERY.md](projects/RECOVERY.md) | 状態遷移と削除条件 / 目的不一致からの復旧 |
| [evals/EVALS.md](evals/EVALS.md) | 振る舞いevalの契約、ケースschema、fixture、最低条件 |
| [evals/TRACE.md](evals/TRACE.md) | trace event語彙、採点根拠、adapter呼び出し契約 |
| [tools/UPSTREAM.md](tools/UPSTREAM.md) | 上流Issue報告の契約、匿名化検査、送信条件 |
| [tools/SAFETY.md](tools/SAFETY.md) | 通常判断で守る6つの安全不変条件とリスク別経路 |
| [tools/TOOLS.md](tools/TOOLS.md) | 通常入口、Core/Optional分類、Tool登録、自律commit、自己修復、サイズ予算 |
| [tools/REFERENCE.md](tools/REFERENCE.md) | 固定Toolの呼び出し形、入出力、生成物、停止reason、fallback |
| [tools/BACKUP.md](tools/BACKUP.md) | backup trigger、remote分類、失敗と復旧、divergence、Single Writer |
| [tools/CONTROL.md](tools/CONTROL.md) | 境界執行の三層、policy tier、明示エスカレーション、違反分類と代謝、委譲境界、導入基準 |

## ライセンス

[MIT License](LICENSE)
