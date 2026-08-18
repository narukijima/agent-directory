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
- secret、不変原資料、protected変更を守るGit境界
- 外部AI、Hosted CI、特定Providerを必要としない静的validator
- Route、Context、Knowledge、Project、安全境界の小型behavioral Core eval

本製品が提供しないもの:

- Runtime、Provider、model routing、permission、認証、machine setup
- Skill discovery / invocation、subagent、worktree isolation、MCP、hook、product-side memory
- Git / GitHub操作、backup、Issue / PR、publish、deploy、scheduler
- Provider間の分業・fallback
- 常駐daemon、外部DB、Tool broker

## 利用開始

1. エージェント1体につき1つcopyまたはcloneする。
2. [AGENTS.md](AGENTS.md)の自己定義placeholderを置換する。
3. 必要なSkill sourceまたはProjectだけを各`_template/`から作る。
4. Runtime、Provider、認証、permissionをそのAgentの環境で設定する。
5. `bash tools/install-git-hooks.sh --install`を実行する。
6. `bash tools/validate-agent-directory.sh --strict --full`を実行する。

テンプレート配布状態では通常validatorは合格し、`--strict`は自己定義置換まで失敗する。

## 設計方針

- 通常経路は`Route → Target → Work → Verify`。
- Repository正本を会話履歴、製品側memory、Runtime側cacheより優先する。
- 全件をLLMへ渡さず、active metadataから候補を最大5件へ絞る。
- 原資料と閉鎖済みlogを変更しない。
- 状態変更を物理archiveで表さない。
- Runtimeと外部操作は各Agent / Operator / Projectが所有する。
- 新しいTool、Skill、恒久的仕組み、抽象化、依存は原則追加しない。既存Ownerへ統合できず、
  新設が必要な場合だけ事前にOwnerへ確認する。

## Route

| Route | 対象 | 入口 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) |
| `skill` | 再利用手順・研究方法 | [skills/SKILLS.md](skills/SKILLS.md)と対象`SKILL.md` |
| `project` | 固有作業、成果物、研究 | [projects/AGENTS.md](projects/AGENTS.md) |
| `meta` | 構造、規約、Tool | 対象正本 |
| `none` | 永続変更のない回答 | 追加ロードなし |

## 構造

```text
agent-directory/
├── AGENTS.md
├── README.md
├── knowledge/
│   ├── KNOWLEDGE.md
│   ├── raw/{internal,external}/
│   └── wiki/{INDEX.md,LOG.md,logs,_template,sources,topics}/
├── skills/
│   ├── SKILLS.md
│   └── _template/
├── projects/
│   ├── AGENTS.md
│   ├── PROJECTS.md
│   ├── DOCS.md
│   ├── REPOSITORIES.md
│   ├── LIFECYCLE.md
│   ├── RECOVERY.md
│   ├── .gitignore
│   ├── _template/
│   └── <project-name>/
├── evals/                        # Core cases、最小fixture、trace契約
└── tools/
    ├── TOOLS.md
    ├── SAFETY.md
    ├── CONTROL.md
    ├── control-policy.tsv
    └── 6 executable Tools + 5 internal files
```

## RuntimeとProvider

Runtime、Provider、認証、permission、machine-local setupは各Agent / Operatorが所有する。
本仕様は固有adapter、推奨Profile、Provider間の分業、fallback、認証設定を持たない。導入後の各Agentは、
必要なら`.codex/`、`.claude/`、`CLAUDE.md`等の薄いadapterを追加・追跡してよい。validatorはそれらを
違反として拒否しない。Repository Knowledgeが正本で、製品側memoryは任意のRuntime cacheである。

`skills/`はPortableなSkill sourceであり、発見・選択・起動を行うRuntimeではない。利用するRuntimeの標準配置
（例: Codexの`.agents/skills/`、Claude Codeの`.claude/skills/`）へ、consumer側の薄いadapterまたは明示importで
接続する。同じ規則をProvider固有ファイルへ複製しない。

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

## 検証

```bash
bash tools/validate-agent-directory.sh --changed
bash tools/validate-agent-directory.sh
bash tools/validate-agent-directory.sh --strict --full
bash tools/validate-agent-directory.sh --full --base main
python3 tools/run-evals.py score --case evals/fixtures/eval-runtime/case.yaml --trace evals/fixtures/eval-runtime/pass.jsonl
```

validatorは必須構造、frontmatter、サイズ、Project / Knowledge / Skill境界、Tool allowlist、script構文、
Markdown参照、Independent Project整合を検査する。networkと外部AIを必要としない。
behavioral evalは[evals/EVALS.md](evals/EVALS.md)の小型Core profileだけを扱う。

commit・push境界は`tools/check-boundary.sh`とmanaged hooksが執行する。protected変更の手順は
[tools/CONTROL.md](tools/CONTROL.md)が所有する。

## Tool

`tools/`は14ファイル固定で、実行Toolは6本、内部実装は5ファイルである。完全な一覧とCLIは
[tools/TOOLS.md](tools/TOOLS.md)が所有する。

新しいToolを追加する前に、既存Toolまたは対象Ownerへの統合を優先する。新設が不可避な場合は、
追加前にOwner確認を得る。

## Remoteと公開

remoteは稼働正本ではない。push、PR、merge、branch cleanup、公開、backup、認証の実行はRuntime、Operator、
対象Projectが所有し、Agent Directory Coreは固有Toolや実行workflowを持たない。Coreが持つのはGit ownership、
repository / revisionによる再現性、送信対象に対するsecret・不変原資料・protected contractの境界検査である。

## 正本

| 正本 | 所有する内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 自己定義、Route、Context Loading、共通判断 |
| [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) | Knowledge構造、不変規則、限定取得、LOG |
| [skills/SKILLS.md](skills/SKILLS.md) | Skill schema、選択、Owner確認 |
| [projects/AGENTS.md](projects/AGENTS.md) | Project作業入口 |
| [projects/PROJECTS.md](projects/PROJECTS.md) | 成果契約、Git ownership、attachment |
| [projects/DOCS.md](projects/DOCS.md) | 任意Project docs |
| [projects/REPOSITORIES.md](projects/REPOSITORIES.md) | Independent registry |
| [projects/LIFECYCLE.md](projects/LIFECYCLE.md) | 状態遷移と削除 |
| [projects/RECOVERY.md](projects/RECOVERY.md) | Project復旧 |
| [evals/EVALS.md](evals/EVALS.md) / [evals/TRACE.md](evals/TRACE.md) | Core behavioral evalとtrace |
| [tools/TOOLS.md](tools/TOOLS.md) | Tool allowlistとCLI |
| [tools/SAFETY.md](tools/SAFETY.md) | 六つの安全不変条件 |
| [tools/CONTROL.md](tools/CONTROL.md) | Git境界、ack、receipt |

## ライセンス

[MIT License](LICENSE)
