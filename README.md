# agent-directory

長期稼働するAIエージェント1体ごとに持つ、ローカルファーストのAgent Workspaceテンプレート。
Knowledge、Skill、Projectを正本として育てながら、1タスクの読込量を総量から切り離す。

`AGENTS.md`はブートローダー兼ルーターである。Routeを一つ決めたら、その領域の正本へ引き継ぐ。

## 公開製品の契約

本製品が提供するもの:

- Agent identityと共通判断規則
- Knowledge、Skill、Projectの責務分離
- frontmatterによる状態管理
- bounded context searchと再生成可能cache
- Embedded / Independent ProjectのGit所有境界
- repository / revisionからのIndependent Project再現
- secret、不変原資料、protected変更を守るGit境界
- 外部AI、Hosted CI、特定Providerを必要としない静的validator
- Route、Context、Knowledge、Project、安全境界の小型behavioral Core eval

本製品が提供しないもの:

- Runtime、Provider、permission、認証、machine setup
- backup、Issue / PR、publish、deploy、scheduler
- Provider間の分業・fallback
- 常駐daemon、外部DB、Tool broker

## 利用開始

1. エージェント1体につき1つcopyまたはcloneする。
2. [AGENTS.md](AGENTS.md)の自己定義placeholderを置換する。
3. 必要なSkillまたはProjectだけを各`_template/`から作る。
4. Runtime、Provider、認証、permissionをそのAgentの環境で設定する。
5. `bash tools/install-git-hooks.sh --install`を実行する。
6. `bash tools/validate-agent-directory.sh --strict --full`を実行する。
7. `tools/find-context.sh --route <route> --limit 5 -- "検索語"`で候補を絞る。

テンプレート配布状態では通常validatorは合格し、`--strict`は自己定義置換まで失敗する。

## 設計方針

- 通常経路は`Route → Target → Work → Verify`。
- Repository正本を会話履歴、製品側memory、検索cacheより優先する。
- 全件をLLMへ渡さず、active metadataから候補を最大5件へ絞る。
- 原資料と閉鎖済みlogを変更しない。
- 状態変更を物理archiveで表さない。
- 派生cacheは削除・再生成可能とする。
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
    └── 9 executable Tools + 4 internal files
```

## RuntimeとProvider

Runtime、Provider、認証、permission、machine-local setupは各Agent / Operatorが所有する。
本テンプレートは固有adapter、推奨Profile、Provider間の分業、fallback、認証設定を持たない。
導入後の各Agentは、必要なら`.codex/`、`.claude/`、`CLAUDE.md`等を追加・追跡してよい。
validatorはそれらを違反として拒否しない。

## ProjectとGit

Project rootは常に`projects/<name>/`で、違いは所有Gitだけである。

- Embedded: Workspace root Gitが追跡
- Independent: `projects/<name>/.git/`を持つ通常clone

worktree、submodule、symlink、`.git` file、外部配置、下位`repository/`階層は使わない。
Independent Projectの正本は[projects/REPOSITORIES.md](projects/REPOSITORIES.md)のrepository URLとrevisionである。

```bash
bash tools/materialize-project-repositories.sh --all --check
bash tools/materialize-project-repositories.sh --all
bash tools/materialize-project-repositories.sh --project <name>
```

既存cloneは検査だけを行い、reset、clean、stash、merge、rebase、remote貼替えをしない。
認証とremote操作は各Agent / Projectが所有する。

## コンテキスト探索

```bash
tools/find-context.sh --route knowledge --limit 5 -- "資本配分"
tools/find-context.sh --route project --include-inactive -- "site migration"
tools/task.sh context --route project --target projects/<name>
tools/task.sh context --route meta --target tools/TOOLS.md
```

明示パスを検索より優先する。検索結果は候補であり、採用した正本を読む。
`.agent-cache/`は正本から再生成でき、恒久参照先にしない。

## 検証

```bash
tools/task.sh verify
bash tools/validate-agent-directory.sh --changed
bash tools/validate-agent-directory.sh
bash tools/validate-agent-directory.sh --strict --full
bash tools/validate-agent-directory.sh --full --base main
python3 tools/run-evals.py score --case evals/fixtures/eval-runtime/case.yaml --trace evals/fixtures/eval-runtime/pass.jsonl
```

validatorは必須構造、frontmatter、サイズ、Project / Knowledge / Skill境界、Tool allowlist、script構文、
Markdown参照、cache再生成、Independent Project整合を検査する。networkと外部AIを必要としない。
behavioral evalは[evals/EVALS.md](evals/EVALS.md)の小型Core profileだけを扱う。

commit・push境界は`tools/check-boundary.sh`とmanaged hooksが執行する。protected変更の手順は
[tools/CONTROL.md](tools/CONTROL.md)が所有する。

## Tool

`tools/`は17ファイル固定で、実行Toolは9本だけである。完全な一覧とCLIは
[tools/TOOLS.md](tools/TOOLS.md)が所有する。

新しいToolを追加する前に、既存Toolまたは対象Ownerへの統合を優先する。新設が不可避な場合は、
追加前にOwner確認を得る。

## Remoteと公開

remoteは稼働正本ではない。push、PR、公開、backup、認証、branch cleanupは各Agent / Projectの契約で行い、
Agent Directory固有Toolを持たない。[tools/SAFETY.md](tools/SAFETY.md)のStanding Authorizationと
Remote Integrityは維持する。

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
