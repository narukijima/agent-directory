# agent-directory

長期稼働するAIエージェント1体ごとに持つ、ローカルファーストのAgent Workspaceテンプレート。
Knowledge、Skill、Projectを正本として育てながら、1タスクの読込量は総量から切り離す。

これは複数の外部リポジトリを束ねる集約点ではなく、一体のAgent Workspaceである。独立したremote identityが
必要なProjectも、cloneはこのツリー内の`projects/<name>/`へ置く。

`AGENTS.md`は百科事典ではなく、ブートローダー兼ルーター兼目次である。Routeを一つ決めたら、その領域を
所有する正本へ引き継ぐ。詳細契約は各正本が持ち、READMEはそこへの入口だけを持つ。

## 利用開始

1. このリポジトリをエージェント1体につき1つコピーまたはクローンする。
2. [AGENTS.md](AGENTS.md)の`<agent-name>`、役割、使命、ビジョン、`<operator-language>`（運用者応対言語）を置換する。
   Agent名・役割はbacktickを保ったまま置換する。自己定義の名乗り行（`- あなたは…`）のbacktick語だけが
   上流報告の匿名化遮断語になり、応対言語・使命・ビジョンは遮断語にならない。
3. `skills/_template/`または`projects/_template/`を、明示された必要に応じてコピーする。
4. Codex DesktopまたはClaude Codeで開く。どちらも`tools/setup-local-environment.sh`を共通の初期化入口に使う。
5. `bash tools/install-git-hooks.sh --install`でcommit・push境界の検査hookを導入する。
6. `bash tools/validate-agent-directory.sh --strict --full`を実行する。
7. `tools/find-context.sh --route <route> --limit 5 -- "検索語"`で対象候補を絞って運用する。

テンプレートのままではプレースホルダーが残るため、通常の検証は合格し、`--strict`は導入完了まで失敗する。

## 設計方針

- 通常経路は`Route → Target → Work → Verify`に固定し、`tools/task.sh`を共通入口にする。
- 常時守る安全境界は[tools/SAFETY.md](tools/SAFETY.md)の6項目だけとし、実装詳細は条件付きで読む。
- Human-on-the-loopで運用する。内部で完結する可逆な操作はAIが判断、実行、検証、commitまで完結し、
  人間は方針・成果契約の変更、不可逆操作、外部影響、安全性と正本衝突だけを見る。
- リポジトリ内の正本を会話記憶、製品側AIメモリ、検索結果より優先する。
- `raw/internal/`と`raw/external/`の既存原資料は同じ強さで保護し、変更・削除しない。
- 完了・停止・廃止を物理archiveで表さず、frontmatterの状態で検索から除外する。
- 全件台帳をLLMへ渡さず、状態付きの決定的検索で候補を絞る。
- 派生catalogと自動生成DBは削除・再生成可能とし、恒久参照先にしない。
- ベクトルDB、常駐サービス、CI、外部課金は既定で導入しない。

## Route

| Route | 対象 | 着手後に読む正本 |
|---|---|---|
| `knowledge` | 取り込み、記憶、照会、統合 | [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) |
| `skill` | 分析・判定手順、再利用可能な研究方法 | [skills/SKILLS.md](skills/SKILLS.md)と対象`SKILL.md` |
| `project` | 固有の仕事・成果物、具体的な研究活動 | [projects/AGENTS.md](projects/AGENTS.md)、対象`PROJECT.md`、`STATE.md` |
| `meta` | 規約、テンプレート、eval、tool | 対象領域の大文字正本と変更対象 |
| `none` | 永続変更のない回答・一時作業 | 必要最小限。中間物は`.tmp/` |

## 構造

固定ファイルは大文字名、利用者が作るKnowledgeページとProjectの詳細文書は小文字ケバブケースとする。

```text
agent-directory/
├── AGENTS.md                     # ブートローダー兼ルーター兼目次
├── CLAUDE.md                     # @AGENTS.md
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
├── routines/
│   ├── ROUTINES.md               # Routine Trigger層の正本
│   └── maintenance/ROUTINE.md    # Maintenance Routineの契約
├── evals/                        # EVALS.md、cases/、fixtures/
└── tools/                        # task.sh、SAFETY.md、固定ToolとOptional capability
```

## ローカル実行環境

`AGENTS.md`を共通の判断規約、`tools/`を決定的処理の正本とし、AIクライアント固有設定は薄いadapterにする。

| 層 | 共有入口 | 責務 |
|---|---|---|
| 共通 | `AGENTS.md` / `tools/setup-local-environment.sh` | 規約と冪等な初期化 |
| Codex Desktop | `.codex/environments/agent-directory.toml` | worktree作成時のSetupと共通Actions |
| Claude Code | `.claude/settings.json` | 新規`SessionStart`から同じSetupを呼ぶ |

Setupは`bash`、`git`、`python3`とGit rootを確認し、Git管理外の検索cacheを生成する。
`--git-author-name`または`AGENT_DIRECTORY_GIT_AUTHOR_NAME`の明示overrideがあれば適用し、なければ既存の
repo-local `user.name`を保持する。local値も未設定のときだけ`AGENTS.md#自己定義`の推奨Agent名を
既定値にする。emailと既存履歴は変更しない。既存cacheが新鮮なら本文を再読しないfast pathを使う。
`.env*`のコピー、package追加、
Git hook・remote・scheduleの変更、ネットワーク接続は行わない。Git hookの導入は利用開始手順の
明示コマンドとして分離する。CodexのActionsは限定検証、full検証、Maintenance dry-run、hook状態確認を
既存Toolへ直接つなぎ、GitHub認証状態は既存の`tools/setup-github-auth.sh --check`へ明示的に接続する。
GitHub認証Actionは実APIと実remoteを検査するが、Setupからは呼ばない。判定ロジックをadapterへ複製しない。
Claude Codeの`.worktreeinclude`も既定では置かず、
`.env*`などGit管理外ファイルをworktreeへ複製する必要が確認されたWorkspaceだけで個別に設計する。

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

| 所有 | 対象 |
|---|---|
| root Gitが追跡 | 全Embedded Project、`projects/REPOSITORIES.md`、`projects/.gitignore` |
| Independent Gitが追跡 | `PROJECT.md`、`STATE.md`、`AGENTS.md`、`ARCHITECTURE.md`、`docs/`、コード、tests、Git履歴 |
| root Gitがignore | 登録済みの`projects/<name>/`。gitlinkもmanifest登録も検索候補も持たない |

`PROJECT.md`はattachmentを宣言しない。root側の正本は`projects/REPOSITORIES.md`のattachment registryだけで、
name、`repository_url`、`repository_reason`、採用`revision`を持つ。`projects/.gitignore`のmanaged blockは
その派生projectionである。statusにかかわらず全Independent repositoryがmaterialize済みであることを健全な
状態とする。

```bash
bash tools/materialize-project-repositories.sh --all --check
bash tools/materialize-project-repositories.sh --all
bash tools/materialize-project-repositories.sh --project <name>
```

昇格条件、`repository_reason`、session rootとSHA handoff、remote操作の境界とpush policy（`auto` / `gated`）は
[projects/PROJECTS.md](projects/PROJECTS.md)が所有する。Independentの`origin`はworkspace backupと別物であり、
外部影響を持ちうるためProjectごとに一度push方針を決める。旧`projects/<name>/repository/`方式と
agent-directory外へcloneを置く旧方式は現役構造として許可せず、移行対象としてだけ
[tools/BACKUP.md](tools/BACKUP.md)が扱う。

> [!WARNING]
> **Git Clean の注意:** 登録済み Independent Project は root Git から ignore されています。root リポジトリで `git clean -x` や `git clean -ffdx` を実行すると、ignore されている Independent リポジトリの未コミット作業やクローンが不可逆的に削除される危険があります。root での非破壊的でない `git clean` は原則行わないでください。


## コンテキスト探索

```bash
# active Knowledgeを最大5件
tools/find-context.sh --route knowledge --limit 5 -- "資本配分"

# 明示的な監査時だけ非activeも含める
tools/find-context.sh --route project --include-inactive -- "site migration"

# 対象確定後の通常入口。Owner、Git root、class、profileは内部解決する
tools/task.sh context --route project --target projects/<name>
tools/task.sh context --route meta --target tools/TOOLS.md
```

明示パスと正本の明示参照を最優先とし、検索結果は候補として扱う。選択後に正本を読む。
`.agent-cache/`は正本から再生成され、検索のstale回復はrouting catalogだけを一度作り直す。
manifest（全体inventory）はMaintenanceとfull検証だけが再生成する。
探索順位と読込予算の原則は[tools/TOOLS.md](tools/TOOLS.md)と[AGENTS.md](AGENTS.md)が、
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

commit・push境界は[tools/CONTROL.md](tools/CONTROL.md)のpolicyを`tools/check-boundary.sh`が判定し、
導入済みのgit hooks（pre-commit / pre-push）が強制する。hookが実行するのはworking tree版ではなく
`.git/agent-control/`の承認済みsnapshot（HEAD追従）であり、安全核・Project成果契約の変更には
明示ackと`--full`検証のreceiptを要求し、push時は送信内容を再検査する。判定はAIハーネスに依存せず、
hookは境界検査だけを行いbackupや検証を起動しない。materialize済みIndependent repositoryへも
同じhookが導入される。

## CoreとOptional

Coreは`AGENTS.md`、Route正本、`tools/task.sh`、validator、[tools/SAFETY.md](tools/SAFETY.md)である。
通常タスクはこの範囲だけで開始できる。backup、GitHub認証repair、Independent repository、Routine、
behavioral eval、上流Issue報告はOptional capabilityであり、該当機能を使うときだけ正本とToolを読む。

既存consumerとの互換性のため`tools/prepare-context.sh`と`tools/finalize-task.sh`は残すが、新しい通常入口を
増やさない。分類と所有先は[tools/TOOLS.md](tools/TOOLS.md)、個別CLIは
[tools/REFERENCE.md](tools/REFERENCE.md)が所有する。

## Routine（自律定期保守）

RoutineはOptionalであり、通常タスクでは読まない。利用時の安全境界、Provider、lock、schedule、結果語彙は
[routines/ROUTINES.md](routines/ROUTINES.md)が所有する。初期版はMaintenanceだけである。

```bash
bash tools/run-routine.sh maintenance --dry-run
bash tools/manage-routine-schedule.sh --routine maintenance --scheduler auto --status
```

推論とschedule導入は明示設定時だけ有効になる。未設定では外部通信せず、clone時にscheduleを
自動installしない。

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
| [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) | 四層構造、保存先、不変規則、命名、限定取得、INDEX、LOG |
| [skills/SKILLS.md](skills/SKILLS.md) | Skillの選択、frontmatter、Knowledge参照、構造 |
| [projects/AGENTS.md](projects/AGENTS.md) | Project作業共通の着手・実行・完了手順 |
| [projects/PROJECTS.md](projects/PROJECTS.md) | 成果契約、Project docs、Domain Canon、Research昇格、attachment、push policy |
| [projects/REPOSITORIES.md](projects/REPOSITORIES.md) | Independent Projectのattachment registryとentry形式 |
| [projects/LIFECYCLE.md](projects/LIFECYCLE.md) / [projects/RECOVERY.md](projects/RECOVERY.md) | 状態遷移と削除条件 / 目的不一致からの復旧 |
| [routines/ROUTINES.md](routines/ROUTINES.md) | Routine Trigger層、Scheduler分離、送信境界、commit/backup条件 |
| [evals/EVALS.md](evals/EVALS.md) | 振る舞いevalの契約、ケースschema、fixture、最低条件 |
| [tools/SAFETY.md](tools/SAFETY.md) | 通常判断で守る6つの安全不変条件とリスク別経路 |
| [tools/TOOLS.md](tools/TOOLS.md) | 通常入口、Core/Optional分類、Tool登録、自律commit、自己修復、サイズ予算 |
| [tools/REFERENCE.md](tools/REFERENCE.md) | 固定Toolの呼び出し形、入出力、生成物、停止reason、fallback |
| [tools/BACKUP.md](tools/BACKUP.md) | backup trigger、remote分類、失敗と復旧、divergence、Single Writer |
| [tools/CONTROL.md](tools/CONTROL.md) | 境界執行の三層、policy tier、明示エスカレーション、違反分類と代謝、委譲境界、導入基準 |

## ライセンス

[MIT License](LICENSE)
