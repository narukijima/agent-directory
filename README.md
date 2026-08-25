# agent-directory

長期稼働するAIエージェント1体ごとに持つ、ローカルファーストのPortable Canon / Workspace仕様。
Runtimeを置き換えず、Identity、Knowledge、Skill source、Project契約、State、Lifecycle、Ownership、
Structural safetyをProvider非依存の正本として保つ。

`AGENTS.md`はブートローダー兼ルーターである。Routeを一つ決めたら、その領域の正本へ引き継ぐ。

## 公開製品の契約

本製品が提供するもの:

- Agent identityと共通判断規則
- Knowledge、Skill、Projectの責務分離
- frontmatterによる状態管理
- 大規模Knowledgeを限定取得するbounded context契約
- Embedded / Independent ProjectのGit所有境界
- repository / revisionからのIndependent Project再現
- secret-bearing fileを追跡しない静的検査
- 外部AI、Hosted CI、特定Providerを必要としない静的validator

本製品が提供しないもの:

- Runtime、Provider、model routing、permission、認証、machine setup
- Skill discovery / invocation、subagent、worktree isolation、MCP、hook、product-side memory
- Git / GitHub操作、backup、Issue / PR、publish、deploy、scheduler
- Provider間の分業・fallback
- 常駐daemon、外部DB、Tool broker

## 利用開始

1. エージェント1体につき1つcopyまたはcloneする。
2. [AGENTS.md](AGENTS.md)の自己定義placeholderを置換する。
3. 共有Skillは`bash tools/import-skill.sh <name> --source /path/to/agent-skills`で取り込み、固有SkillまたはProjectだけを
   各`_template/`から作る。
4. Agent固有の環境変数を未追跡のroot `.env`へ置き、Runtime、Provider、認証、permissionをそのAgentの環境で設定する。
5. `bash tools/validate-agent-directory.sh --strict --full`を実行する。

テンプレート配布状態では通常validatorは合格し、`--strict`は自己定義置換まで失敗する。

## 設計方針

- 通常経路は`Route → Target → Work → Verify`。
- Repository正本を会話履歴、製品側memory、Runtime側cacheより優先する。
- 全件をLLMへ渡さず、active metadataから候補を最大5件へ絞る。
- 原資料を変更しない。
- 状態変更を物理archiveで表さない。
- Runtimeと外部操作は各Agent / Operator / Projectが所有する。
- 新しいTool、Skill、恒久的仕組み、抽象化、依存は原則追加しない。既存Ownerへ統合できず、
  新設が必要な場合だけ事前にOwnerへ確認する。

## Route

| Route | 対象 | 入口 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) |
| `skill` | 再利用手順・研究方法 | [skills/SKILLS.md](skills/SKILLS.md)と対象`SKILL.md` |
| `project` | 固有作業・成果物・研究 | [projects/AGENTS.md](projects/AGENTS.md) |
| `meta` | 構造、規約、Tool | 対象正本 |
| `none` | 永続化Ownerのない回答 | 原則追加ロードなし。Runtimeが選んだSkillは実行時に読む |

## 構造

```text
agent-directory/
├── AGENTS.md
├── CLAUDE.md                    # @AGENTS.mdだけのClaude Code bridge
├── README.md
├── .agents/skills/              # Codex用Skill bridgeの空の受け皿
├── .claude/
│   ├── skills/                  # Claude Code用Skill bridgeの空の受け皿
│   └── settings.json            # 権限overrideを持たないnative設定
├── .codex/
│   └── config.toml              # 権限overrideを持たないnative設定
├── knowledge/
│   ├── KNOWLEDGE.md
│   ├── raw/{internal,external}/
│   └── wiki/{INDEX.md,_template,sources,topics}/
├── skills/
│   ├── SKILLS.md
│   └── _template/
├── projects/
│   ├── AGENTS.md
│   ├── PROJECTS.md
│   ├── REPOSITORIES.md
│   ├── LIFECYCLE.md
│   ├── .gitignore
│   ├── _template/
│   └── <project-name>/
├── tests/                        # repository開発用。Coreから独立
│   ├── run-evals.py
│   └── evals/                    # cases、fixture、trace契約
└── tools/
    ├── TOOLS.md
    ├── SAFETY.md
    └── 3 executable Tools + 2 internal files
```

## RuntimeとProvider

Runtime、Provider、認証、permission、machine-local setupは各Agent / Operatorが所有する。
Agent Directory Coreはそれらを選択・変換・実行せず、共通Permission schema、approval engine、network gatewayを
持たない。`.codex/config.toml`と`.claude/settings.json`はnative設定の受け皿だけを残し、Runtime権限をoverrideしない。
Auto / Manual、sandbox、Permission Profile、network、Browser / Computer Use、Git metadataの権限は各Runtimeと
Operatorの設定をそのまま使う。配布済み`CLAUDE.md`は`@AGENTS.md`だけをimportする。Repository Knowledgeが正本で、
製品側memoryは任意のRuntime cacheである。

Agent固有の環境変数はroot `.env`を既定の未追跡注入面とする。値や変数一覧を公開templateへ持たず、OS共有、
Keychain、外部secret storeを必須にしない。別の注入面が必要なRuntimeでは、そのAgent / Operatorが明示選択する。

`skills/`はPortableなSkill sourceであり、発見・選択・起動を行うRuntimeではない。利用するRuntimeの標準配置
（Codexの`.agents/skills/`、Claude Codeの`.claude/skills/`）から、必要なSkill directoryだけをper-Skill symlinkで
`skills/<name>/`へ接続する。同じ規則、Skill本文、references、scriptsをProvider固有pathへ複製しない。

```bash
ln -s ../../skills/<skill-name> .agents/skills/<skill-name>
ln -s ../../skills/<skill-name> .claude/skills/<skill-name>
```

Skill実行はRootの直列実行に限らない。独立して完結するSkill workは、CodexやClaude Codeが標準で提供する
Subagent実行へ委譲・並列化してよい。委譲基準、Worker往復の最小context、並列とSingle Writerの境界は
[skills/SKILLS.md](skills/SKILLS.md)の「Skill実行の委譲」が所有し、Coreは独自のorchestrator、queue、
worker manager、DAG管理を持たない。

両RuntimeのSkill受け皿は空の構造だけをtemplateに含める。Skill実体、偽の`SKILL.md`、`_template` linkは置かず、
`tools/import-skill.sh`が共有Skillのimport時にだけ同名linkを作る。固有Skillを`_template/`から作る場合も、同じ2本の
per-Skill linkだけを追加する。

## ProjectとGit

Project rootは常に`projects/<name>/`で、違いは所有Gitだけである。

- Embedded: Workspace root Gitが追跡
- Independent: `projects/<name>/.git/`を持つ通常clone

Projectの恒久attachment、registry、recovery単位としてworktree、submodule、symlink、`.git` file、外部配置、
下位`repository/`階層は使わない。これはRuntimeが一時的なsession isolationや並列作業にGit worktreeを使うことを
禁止しない。Runtime worktreeはProject identityや採用revisionの正本にしない。
Independent Projectの正本は[projects/REPOSITORIES.md](projects/REPOSITORIES.md)のrepository URLとrevisionである。

```bash
bash tools/materialize-project-repositories.sh --all --check
bash tools/materialize-project-repositories.sh --all
bash tools/materialize-project-repositories.sh --project <name>
```

既存cloneは検査だけを行い、reset、clean、stash、merge、rebase、remote貼替えをしない。
認証とremote操作は各Agent / Projectが所有する。

## コンテキスト探索

明示パスを検索より優先する。target未指定のKnowledge照会だけ、Runtime標準のファイル検索で
`knowledge/wiki/sources/`と`knowledge/wiki/topics/`のactive候補を最大5件へ絞る。Projectは`projects/<name>/`、
Skill sourceは`skills/<name>/SKILL.md`を直接使う。検索結果や製品側memoryを正本の代わりにしない。
予算はbyte数だけでなく往復回数にも適用し、pathが決まっている読込は1回のbatchへまとめる。

## 検証

```bash
bash tools/validate-agent-directory.sh --changed
bash tools/validate-agent-directory.sh --strict --full
bash tools/validate-agent-directory.sh --base origin/main --full
bash tools/validate-agent-directory.sh --full --self-test
python3 tests/run-evals.py validate
python3 tests/run-evals.py score --case tests/evals/fixtures/eval-runtime/case.yaml --trace tests/evals/fixtures/eval-runtime/pass.jsonl
```

validatorは構造、schema、サイズ、所有境界、Tool、script、参照を検査する。`--changed`は対象を絞るが、
HEADに対するraw不変性とProject lifecycleは常に検査する。`--base <ref>`は指定revisionからのcommit済み差分も検査する。
`--self-test`はTool自身の回帰検査であり、Workspaceの内容を検査しないため通常運用では使わない。
networkと外部AIを必要とせず、検証は作業Agent自身がsession内で完結させる。CIやHosted checkへ依存しない。
[behavioral tests](tests/evals/README.md)は本repositoryの開発QAであり、導入済みWorkspaceのCore依存ではない。
静的validatorでは判定できないRoute解釈を、保存済みtraceで検査する。

commit、push、branch、PR、merge、approvalはGit、Runtime、Operator、対象Repositoryの標準機能が所有する。
Core独自のpre-commit / pre-push hook、ack、receipt、approval layerは持たない。

## Tool

`tools/`は7ファイル固定で、実行Toolは3本、内部実装は2ファイルである。完全な一覧とCLIは
[tools/TOOLS.md](tools/TOOLS.md)が所有する。

新しいToolを追加する前に、既存Toolまたは対象Ownerへの統合を優先する。新設が不可避な場合は、
追加前にOwner確認を得る。

## Remoteと公開

remoteは稼働正本ではない。push、PR、merge、branch cleanup、公開、backup、認証の実行はRuntime、Operator、
対象Projectが所有し、Agent Directory Coreは固有Toolや実行workflowを持たない。Coreが持つのはGit ownership、
repository / revisionによる再現性、送信対象に対するsecret・不変原資料・protected contractの境界検査である。

## 依存条件

- Bash 3.2以上（macOS標準`/bin/bash`互換。Tool全体をBash 3.2で検証する）
- Git 2.x
- Python 3（`tools/import-skill.sh`のfrontmatter正規化と`tests/run-evals.py`だけが使う）
- validatorとbehavioral testはnetworkを使わない。
- Skill importはnetworkを使わず、`--source`は信頼済みlocal repositoryを指定する
  （信頼境界は`tools/TOOLS.md#Skill import`）。
- Independent Projectのmaterializationは、remote URLをclone / fetchする場合だけnetworkと
  実行環境の標準Git認証を必要とする。

## Version

contract versionは`bash tools/validate-agent-directory.sh --version`が返す（現在`1.1.0`）。
採用versionはGit tag（`v<version>`）で固定する。schema・validator契約のbreaking changeはversionを上げ、
その時だけ移行手順を`docs`として添える。自動migrationや更新managerは持たない。

## 正本

| 正本 | 所有する内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 自己定義、Route、Context Loading、共通判断 |
| [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) | Knowledge構造、不変規則、限定取得 |
| [skills/SKILLS.md](skills/SKILLS.md) | Skill schema、選択、実行委譲、Owner確認 |
| [projects/AGENTS.md](projects/AGENTS.md) | Project作業入口 |
| [projects/PROJECTS.md](projects/PROJECTS.md) | 成果契約、Git ownership、attachment |
| [projects/REPOSITORIES.md](projects/REPOSITORIES.md) | Independent registry |
| [projects/LIFECYCLE.md](projects/LIFECYCLE.md) | 状態遷移と削除 |
| [tools/TOOLS.md](tools/TOOLS.md) | Tool allowlistとCLI |
| [tools/SAFETY.md](tools/SAFETY.md) | 五つの安全不変条件 |

## ライセンス

[MIT License](LICENSE)
