# TOOLS.md — 最小Tool契約

`tools/`はAgent Workspaceの構造、限定取得、Git境界、Independent Project再現だけを支えるmeta層である。
Runtime、Provider、認証、backup、Issue / PR、publish、deploy、scheduler、commit workflowは各Agent、
Operator、対象Projectが所有し、本層へ実装しない。

```text
Tool  = 構造上の決定的処理
Agent = 実行時期、外部操作、成果の判断
Human = 方針、例外、新しい恒久物の承認
```

## 追加禁止

新しいToolは原則追加しない。まず既存Tool、対象Projectの`scripts/`、Skillの`scripts/`へ統合する。
どうしても固定Toolの新設が必要な場合は、追加前にOwnerへ次を示して確認する。

- 目的と呼出元
- 既存Toolへ統合できない理由
- 入出力と停止条件
- 維持・検証コスト

Ownerの明示的な新設依頼は確認を満たす。将来使うかもしれない、便利そう、個別Runtimeで必要という理由では
追加しない。validatorは下記allowlist外のToolを拒否する。

## 通常入口

```bash
tools/task.sh context --route <route> [--target <repository-relative-path>]
tools/task.sh verify
tools/task.sh status
```

`context`はRoute正本、target、Git rootを返す。`verify`は変更範囲をvalidatorへ渡す。
`status`はGit rootと変更件数を返す。commit、push、backup、公開は行わない。

read-only回答で対象正本が明示されている場合はToolを必須にしない。探索時だけ`find-context.sh`を使う。

## Tool一覧

固定実行Toolは次の9本だけとする。9本すべてを通常タスクへ読み込まず、通常入口、条件付きCapability、
開発時保証を分ける。条件付きToolも公開契約の実装であり、ClaudAGT個体、Provider、Runtime、認証、backupの
都合では追加しない。

### 通常Core

| Tool | いつ使う | すること | しないこと |
|---|---|---|---|
| `task.sh` | 通常タスクの開始・検証・状態確認 | Route正本、target、Git rootの表示とvalidator呼出し | commit、push、公開 |
| `find-context.sh` | targetが明示されていない探索時 | active候補を最大5件へ絞る | 正本の代わりに回答すること |
| `build-context-cache.sh` | cache欠損・stale・full検証時 | catalogと任意SQLite索引の再生成 | cacheを正本にすること |
| `validate-agent-directory.sh` | 変更後と公開前 | 構造、参照、サイズ、Tool/eval allowlist、scriptを静的検査 | Agentの行動品質を推測すること |
| `check-boundary.sh` | commit・push直前 | secret、frozen、protected、non-FF境界を差分から検査 | commitやpushの実行 |
| `install-git-hooks.sh` | clone後・control更新後 | managed pre-commit / pre-pushとapproved snapshotを導入 | 未管理hookの上書き |

### 条件付きCapability

該当する公開機能を使うときだけ実行する。通常タスクの前提にはしない。

| Tool | いつ使う | すること | しないこと |
|---|---|---|---|
| `materialize-project-repositories.sh` | Independent cloneの再現・監査時 | registryのURLとrevisionからcloneを再現・検査 | credential保存、reset、merge、clean |
| `append-knowledge-log.sh` | Knowledgeを永続変更したとき | LOG追記と閾値rotation | Knowledge本文の生成・判断 |

### 開発時保証

公開契約やevalを変更するときに使い、通常Agentの作業経路には含めない。

| Tool | いつ使う | すること | しないこと |
|---|---|---|---|
| `run-evals.py` | Core行動契約を評価するとき | trace採点と隔離Workspaceでのadapter実行 | Provider実行、外部送信、static validatorの代替 |

内部部品は5物理ファイル、4責務であり、通常Agentは直接実行しない。

| Path | 責務 |
|---|---|
| `tools/lib/project-registry.sh` | `projects/REPOSITORIES.md`の共通parse |
| `tools/validator/check-markdown-references.sh` | Markdown file / anchor整合 |
| `tools/hooks/pre-commit` / `pre-push` | `check-boundary.sh`への薄いadapter |
| `tools/control-policy.tsv` | Git境界の機械可読policy |

## 個別CLI

### Context cache

```bash
bash tools/build-context-cache.sh [--check|--check-routing|--routing-only]
tools/find-context.sh --route knowledge|skill|project|meta [--limit 1..5] [--include-inactive] -- "検索語"
```

`.agent-cache/`は正本から再生成できるGit管理外の派生物である。cacheだけに情報を保存しない。
`find-context.sh`はcache欠損・stale時にrouting部分だけを一度再生成し、本文ではなくmetadataだけを返す。
生成物は`catalog.tsv`、`cache.meta`、規模閾値を超えた場合の`search.sqlite`だけとし、利用されない
workspace全件inventoryを保持しない。

### Validation

```bash
bash tools/validate-agent-directory.sh [--strict] [--full] [--changed] [--base <ref>] [--bootstrap-status]
```

- 通常: 必須構造、frontmatter、Project、Knowledge、Skill、Tool allowlist、script構文を検査
- `--changed`: 変更範囲の入口。meta変更時は全体静的検査へfallback
- `--strict`: 導入後の自己定義placeholderを拒否
- `--full`: 全Markdown参照、cache再生成、materialization整合を追加検査
- `--base`: frozen領域とsecret境界を指定refから検査
- `--bootstrap-status`: `template|deployed`だけを返す

合格は`PASS: agent-directory structure is valid`、失敗は`FAILED`と具体的理由を返す。
protected変更の`--full` PASSはstage済みindex treeへreceiptを発行する。

### Git boundary

```bash
tools/check-boundary.sh [--staged | --base <ref> | --range <old> <new>]
bash tools/install-git-hooks.sh --install|--status|--remove
```

意味論は[CONTROL.md](CONTROL.md)が所有する。hookはnetwork、validator、commit、pushを起動しない。

### Independent Project

```bash
bash tools/materialize-project-repositories.sh --all|--project <name> [--check]
```

registryと採用revisionから通常cloneを再現する。既存cloneは検査だけを行い、reset、clean、stash、merge、
rebase、remote貼替えをしない。認証は実行環境の標準Git設定が所有し、本Toolはcredentialを保存・探索しない。

### Knowledge LOG

```bash
tools/append-knowledge-log.sh --type <type> --target <path> --summary "変更内容"
```

追記先は`knowledge/wiki/LOG.md`だけとし、閾値到達時は閉鎖済み四半期logへ決定的にrotationする。

### Behavioral eval

```bash
python3 tools/run-evals.py score --case <case-name|path> --trace <trace.jsonl> [--json]
python3 tools/run-evals.py run --adapter <executable> --profile core [--output-dir <dir>]
```

対象は`evals/EVALS.md`のCore契約だけとする。Provider、Runtime、認証、backup、外部送信のevalを追加しない。

## 相互参照

恒久参照は`<repository-relative-path>#<target>`を使い、行番号を使わない。targetは見出し、
frontmatter key、または`**<target>**`形式の定義項目とする。

## 一時作業

- 一時コードと中間物は`.tmp/`に置き、正式処理から参照せず完了時に削除する。
- 固定処理は既存Ownerへ統合する。外部作用のためだけにCore Toolを追加しない。
- 原資料、Knowledge、Project成果物をサイズだけを理由に削除・要約置換しない。

## サイズ予算

| 対象 | hard limit |
|---|---:|
| root `AGENTS.md` | 8KiB |
| `projects/AGENTS.md` / Project個別`AGENTS.md` | 2KiB |
| `knowledge/KNOWLEDGE.md` / `skills/SKILLS.md` / `tools/*.md` | 20KiB |
| `projects/PROJECTS.md` / `projects/DOCS.md` | 24KiB |
| `STATE.md` / `knowledge/wiki/INDEX.md` | 8KiB |
| active Wiki | 64KiB。24KiB超はRetrieval Map必須 |
| `knowledge/wiki/LOG.md` | 128KiB・1,000記録 |

入口正本が上限へ近づいたら、重複除去、既存Ownerへの移管、条件付きロード、責務単位の分割の順で
80%以下へ戻す。上限拡大をvalidator通過の手段にしない。
