# TOOLS.md — Core Tool契約

`tools/`はPortable Canonの構造検証、Skill import、Independent Project再現、Knowledge logだけを所有する。
shell、検索、Runtime Skill、Git / GitHub操作、認証、backup、PR、deploy、publishを再包装しない。

## 原則

- 明示path、Runtime標準のfile / Git機能、対象ProjectのToolを優先する。
- Core ToolはProvider、network、外部AI、machine credentialを必要としない。
- Tool出力は正本ではなく、判定結果または派生証拠である。
- 目的が既存Ownerへ統合できるなら新しいwrapperを作らない。

## Allowlist

| Tool | 所有する処理 | 所有しない処理 |
|---|---|---|
| `validate-agent-directory.sh` | Workspace schemaと構造的不変条件 | Runtime / Provider診断 |
| `import-skill.sh` | provenance付きSkill import、標準frontmatter、native symlink | discovery、invocation、自動同期 |
| `materialize-project-repositories.sh` | registry URL / revisionからIndependent cloneを再現・検査 | remote作成、push、merge |
| `append-knowledge-log.sh` | Knowledge LOG追記と決定的rotation | Knowledge本文生成 |
| `run-evals.py` | 保存済みbehavior traceの採点 | Runtime adapterやAIの起動 |

内部実装は`lib/project-registry.sh`と`validator/check-markdown-references.sh`の2ファイルである。
説明正本2ファイルを含め、`tools/`は9ファイル固定。

## Skill import

```bash
bash tools/import-skill.sh <skill-name> --source /path/to/agent-skills
```

配布元のprovenance付きimporterで一時領域へcopyし、Agent Skills標準frontmatterへ正規化してから
`skills/<name>/`へ確定する。同じtransactionで`.agents/skills/<name>`と`.claude/skills/<name>`のsymlinkを作る。
既存Skill、既存adapter、配布元の未commit変更を上書きせず、networkやRuntimeを起動しない。

## Validator

```bash
bash tools/validate-agent-directory.sh [--strict] [--full] [--changed] [--bootstrap-status]
```

- 通常: 必須構造、frontmatter、Project、Knowledge、Skill source、Tool allowlist、script構文を検査
- `--changed`: 変更範囲の入口。現在は完全な静的契約を実行
- `--strict`: 導入済みWorkspaceとして自己定義placeholderを拒否
- `--full`: 全Markdown参照、Independent Project整合、Tool behavior、eval scorer自己検証を追加
- `--bootstrap-status`: `template|deployed`だけを返す

公開テンプレートmainは自己定義placeholderを意図的に持つため、製品自身の検証は`--full`を使う。
consumer導入後は`--strict --full`を使う。

## Independent Project

```bash
bash tools/materialize-project-repositories.sh --all|--project <name> [--check]
```

registryと採用revisionから通常cloneを再現する。既存cloneは検査だけを行い、reset、clean、stash、merge、
rebase、remote貼替えをしない。認証は実行環境の標準Git設定が所有し、本Toolはcredentialを保存・探索しない。
Runtime worktreeは一時実行環境として利用できるが、registryのProject attachmentにはしない。

## Knowledge LOG

```bash
tools/append-knowledge-log.sh --type <type> --target <path> --summary "変更内容"
```

追記先は`knowledge/wiki/LOG.md`だけとし、閾値到達時は閉鎖済み四半期logへ決定的にrotationする。

## Behavioral eval

```bash
python3 tools/run-evals.py score --case <case-name|path> --trace <trace.jsonl> [--json]
python3 tools/run-evals.py validate
```

対象は`evals/EVALS.md`のCore契約だけ。Runtimeが生成した保存済みtraceを採点し、adapter、Provider、model、
subagent、worktreeを起動しない。

## 相互参照

恒久参照は`<repository-relative-path>#<target>`を使い、行番号を使わない。targetは見出し、
frontmatter key、または`**<target>**`形式の定義項目とする。

## 一時作業

- 一時コードと中間物は`.tmp/`に置き、正式処理から参照せず完了時に削除する。
- 固定処理は既存Ownerへ統合する。外部作用のためだけにCore Toolを追加しない。
- 原資料、Knowledge、Project成果物をサイズだけを理由に削除・要約置換しない。

## 追加禁止

新しいToolは原則追加しない。既存Toolまたは対象Ownerへ統合できず、Portable Canonの不変条件を
決定的に執行する必要がある場合だけ、Ownerが目的・非ゴール・維持コストを明示決定して追加する。

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
