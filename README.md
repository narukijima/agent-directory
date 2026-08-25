# agent-directory

長期稼働するAgent 1体ごとに持つ、ローカルファーストのPortable Canon / Workspace仕様である。
Runtimeを置き換えることなく、Identity、Knowledge、Skill source、Project契約、State、Lifecycle、
Ownership、Structural safetyを、Provider非依存の正本として保つ。

`AGENTS.md`はBootloader兼Routerである。Routeを一つ決めたあとは、その領域の正本へ引き継ぐ。

## 公開製品の契約

本製品が提供するもの:

- Agent identityと共通判断規則
- Knowledge、Skill、Projectの責務分離
- frontmatterによる状態管理
- 大規模Knowledgeを限定取得するbounded context契約
- Embedded / Independent ProjectのGit所有境界
- repositoryとrevisionからのIndependent Project再現
- secret-bearing fileを追跡しない静的検査
- 外部AI、Hosted CI、特定Providerを必要としない静的validator

本製品が提供しないもの:

- Runtime、Provider、model routing、permission、認証、machine setup
- Skill discovery / invocation、subagent、worktree isolation、MCP、hook、product-side memory
- Git / GitHub操作、backup、Issue / PR、publish、deploy、scheduler
- Provider間の分業とfallback
- 常駐daemon、外部DB、Tool broker

## 利用開始

1. Agent 1体につき1つcopyまたはcloneする。
2. [AGENTS.md](AGENTS.md)の自己定義placeholderを置換する。
3. 共有Skillは`bash tools/import-skill.sh <name> --source /path/to/agent-skills`で取り込む。
   固有SkillとProjectだけを、それぞれの`_template/`から作る。
4. Agent固有の環境変数を、追跡しないroot `.env`へ置く。Runtime、Provider、認証、permissionは、
   そのAgentの環境で設定する。
5. `bash tools/validate-agent-directory.sh --strict --full`を実行する。

配布直後のtemplate状態では、通常のvalidatorは合格する。`--strict`は自己定義を置換するまで失敗する。

## 設計方針

- 通常経路は`Route → Target → Work → Verify`である。
- Repository正本を、会話履歴、製品側memory、Runtime側cacheより優先する。
- 全件をLLMへ渡さず、active metadataから候補を最大5件へ絞る。
- 原資料を変更しない。
- 状態変更を物理archiveで表さない。
- 新しいTool、Skill、恒久的仕組み、抽象化、依存は原則として追加しない。既存Ownerへ統合できず、
  目的とOwnerが一意に定まる場合だけ自律追加する。将来に備えた曖昧な追加はno-opとする。

## 責任領域

責任領域の正本は[AGENTS.md](AGENTS.md#責任領域)である。Ownerは目的、最終方針、本人判断、例外承認を持つ。
それ以外の通常判断と完了はAgentが担い、Runtime / Operatorは実行能力と環境を所有する。

## Route

| Route | 対象 | 入口 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) |
| `skill` | 再利用手順、研究方法 | [skills/SKILLS.md](skills/SKILLS.md)と対象`SKILL.md` |
| `project` | 固有作業、成果物、研究 | [projects/AGENTS.md](projects/AGENTS.md) |
| `meta` | 構造、規約、Tool | 対象正本 |
| `none` | 永続化Ownerのない回答 | 原則として追加ロードなし。Runtimeが選んだSkillは実行時に読む |

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
    └── 実行Tool 3本 + 内部実装2ファイル
```

## RuntimeとProvider

Runtime、Provider、認証、permission、machine-local setupは、各Agent / Operatorが所有する。
Agent Directory Coreはそれらを選択も変換も実行もせず、共通Permission schemaやnetwork gatewayを持たない。
`.codex/config.toml`と`.claude/settings.json`はnative設定の受け皿だけを残し、Runtime権限をoverrideしない。
Auto / Manual、sandbox、Permission Profile、network、Browser / Computer Use、Git metadataの権限は、
各RuntimeとOperatorの設定をそのまま使う。配布済み`CLAUDE.md`は`@AGENTS.md`だけをimportする。
正本はRepository Knowledgeであり、製品側memoryは任意のRuntime cacheである。

Agent固有の環境変数は、root `.env`を既定の未追跡な注入面とする。値や変数一覧は公開templateへ持たず、
OS共有、Keychain、外部secret storeを必須にしない。別の注入面が必要なRuntimeでは、
そのAgent / Operatorが明示的に選択する。

`skills/`はPortableなSkill sourceであり、発見、選択、起動を行うRuntimeではない。
利用するRuntimeの標準配置（Codexの`.agents/skills/`、Claude Codeの`.claude/skills/`）から、
必要なSkill directoryだけをper-Skill symlinkで`skills/<name>/`へ接続する。
同じ規則、Skill本文、references、scriptsをProvider固有pathへ複製しない。

```bash
ln -s ../../skills/<skill-name> .agents/skills/<skill-name>
ln -s ../../skills/<skill-name> .claude/skills/<skill-name>
```

Skill実行はRootの直列実行に限らない。独立して完結するSkill workは、CodexやClaude Codeが標準で提供する
Subagent実行へ委譲し、並列化してよい。委譲基準、Worker往復の最小context、並列とSingle Writerの境界は、
[skills/SKILLS.md](skills/SKILLS.md)の「Skill実行の委譲」が所有する。
Coreは独自のorchestrator、queue、worker manager、DAG管理を持たない。

両RuntimeのSkill受け皿は、空の構造だけをtemplateに含める。Skill実体、偽の`SKILL.md`、`_template` linkは置かない。
同名のlinkは、`tools/import-skill.sh`が共有Skillをimportするときにだけ作る。
固有Skillを`_template/`から作る場合も、追加するのは同じ2本のper-Skill linkだけである。

## ProjectとGit

Project rootは常に`projects/<name>/`であり、違いは所有Gitだけである。

- Embedded: Workspace root Gitが追跡する
- Independent: `projects/<name>/.git/`を持つ通常のcloneとして扱う

Projectの恒久attachment、registry、recoveryの単位として、worktree、submodule、symlink、`.git` file、
外部配置、下位`repository/`階層は使わない。ただしこれは、Runtimeが一時的なsession isolationや並列作業に
Git worktreeを使うことを禁止しない。Runtime worktreeは、Project identityや採用revisionの正本にしない。
Independent Projectの正本は、[projects/REPOSITORIES.md](projects/REPOSITORIES.md)のrepository URLとrevisionである。

```bash
bash tools/materialize-project-repositories.sh --all --check
bash tools/materialize-project-repositories.sh --all
bash tools/materialize-project-repositories.sh --project <name>
```

既存cloneに対しては検査だけを行い、reset、clean、stash、merge、rebase、remoteの貼り替えをしない。
認証とremote操作は各Agent / Projectが所有する。

## Context探索

明示パスを検索より優先する。Runtime標準のファイル検索を使うのはtarget未指定のKnowledge照会だけであり、
`knowledge/wiki/sources/`と`knowledge/wiki/topics/`のactive候補を最大5件へ絞る。
Projectは`projects/<name>/`を、Skill sourceは`skills/<name>/SKILL.md`を直接使う。
検索結果や製品側memoryを正本の代わりにしない。予算はbyte数だけでなく往復回数にも適用し、
pathが決まっている読み込みは1回のbatchへまとめる。

## 検証

```bash
bash tools/validate-agent-directory.sh --changed
bash tools/validate-agent-directory.sh --strict --full
bash tools/validate-agent-directory.sh --base origin/main --full
bash tools/validate-agent-directory.sh --full --self-test
python3 tests/run-evals.py validate
python3 tests/run-evals.py score --case tests/evals/fixtures/eval-runtime/case.yaml --trace tests/evals/fixtures/eval-runtime/pass.jsonl
```

validatorは、構造、schema、サイズ、所有境界、Tool、script、参照を検査する。
`--changed`は対象を絞るが、HEADに対するrawの不変性とProject lifecycleは常に検査する。
`--base <ref>`は、指定revisionからのcommit済み差分も検査する。
`--self-test`はTool自身の回帰検査であり、Workspaceの内容を検査しないため通常運用では使わない。
検証はnetworkと外部AIを必要とせず、作業Agent自身がsession内で完結させる。CIやHosted checkへ依存しない。
[behavioral tests](tests/evals/README.md)は本repositoryの開発QAであり、導入済みWorkspaceのCore依存ではない。
静的validatorでは判定できないRoute解釈を、保存済みtraceで検査する。

commit、push、branch、PR、mergeは、Git、Runtime、Operator、対象Repositoryの標準機能を使う。

## Tool

`tools/`は7ファイル固定である。内訳は正本2ファイル、実行Tool 3本、内部実装2ファイルである。
完全な一覧とCLIは[tools/TOOLS.md](tools/TOOLS.md)が所有する。

新しいToolは、既存Toolまたは対象Ownerへの統合を優先する。必要性とOwnerが一意に定まる場合だけ自律追加する。

## Remoteと公開

remoteは稼働正本ではない。push、PR、merge、branch cleanup、公開、backup、認証の実行は、
Runtime、Operator、対象Projectが所有し、Agent Directory Coreは固有Toolや実行workflowを持たない。
Coreが持つのは、Git ownership、repositoryとrevisionによる再現性、
送信対象に対するsecret、不変原資料、protected contractの境界検査である。

## 依存条件

- Bash 3.2以上（macOS標準`/bin/bash`互換。Tool全体をBash 3.2で検証する）
- Git 2.x
- Python 3（`tools/import-skill.sh`のfrontmatter正規化と`tests/run-evals.py`だけが使う）
- validatorとbehavioral testはnetworkを使わない
- Skill importはnetworkを使わず、`--source`には信頼済みのlocal repositoryを指定する
  （信頼境界は`tools/TOOLS.md#Skill import`）
- Independent Projectのmaterializationは、remote URLをcloneまたはfetchする場合だけ、
  networkと実行環境の標準Git認証を必要とする

## Version

contract versionは`bash tools/validate-agent-directory.sh --version`が返す（現在は`1.1.0`）。
採用versionはGit tag（`v<version>`）で固定する。schemaとvalidator契約のbreaking changeではversionを上げ、
そのときだけ移行手順を`docs`として添える。自動migrationや更新managerは持たない。

## 正本

| 正本 | 所有する内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 自己定義、Route、Context Loading、共通判断 |
| [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) | Knowledge構造、不変規則、限定取得 |
| [skills/SKILLS.md](skills/SKILLS.md) | Skill schema、選択、実行委譲、自律新設境界 |
| [projects/AGENTS.md](projects/AGENTS.md) | Project作業入口 |
| [projects/PROJECTS.md](projects/PROJECTS.md) | 成果契約、Git ownership、attachment |
| [projects/REPOSITORIES.md](projects/REPOSITORIES.md) | Independent registry |
| [projects/LIFECYCLE.md](projects/LIFECYCLE.md) | 状態遷移と削除 |
| [tools/TOOLS.md](tools/TOOLS.md) | Tool allowlistとCLI |
| [tools/SAFETY.md](tools/SAFETY.md) | 五つの安全不変条件 |

## ライセンス

[MIT License](LICENSE)
