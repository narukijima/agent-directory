# TOOLS.md — Core Tool契約

`tools/`はPortable Canonの構造検証、Skill import、Independent Project再現だけを所有する。
shell、検索、Runtime Skill、Git / GitHub操作、認証、backup、PR、deploy、publishを再包装しない。

## 原則

- 明示path、Runtime標準のfile / Git機能、対象ProjectのToolを優先する。
- Core ToolはProvider、外部AI、machine credentialを必要としない。networkを使うのは
  materializerがremote URLをclone / fetchする場合だけである。
- Tool出力は正本ではなく、判定結果または派生証拠である。
- 目的が既存Ownerへ統合できるなら新しいwrapperを作らない。

## Allowlist

| Tool | 所有する処理 | 所有しない処理 |
|---|---|---|
| `validate-agent-directory.sh` | Workspace schemaと構造的不変条件 | Runtime / Provider診断 |
| `import-skill.sh` | provenance付きSkill import、標準frontmatter、native symlink | discovery、invocation、自動同期 |
| `materialize-project-repositories.sh` | registry URL / revisionからIndependent cloneを再現・検査 | remote作成、push、merge |

内部実装は`lib/project-registry.sh`と`validator/check-markdown-references.sh`の2ファイルである。
説明正本2ファイルを含め、`tools/`は7ファイル固定。

## Skill import

```bash
bash tools/import-skill.sh <skill-name> --source /path/to/agent-skills
```

配布元のprovenance付きimporterで一時領域へcopyし、Agent Skills標準frontmatterへ正規化してから
`skills/<name>/`へ確定する。同じtransactionで`.agents/skills/<name>`と`.claude/skills/<name>`のsymlinkを作る。
既存Skill、既存adapter、配布元の未commit変更を上書きせず、networkやRuntimeを起動しない。

importは配布元の`tools/import-skill.sh`を実行する。これが信頼境界であり、`--source`には内容を確認済みの
信頼できるlocal repositoryだけを指定する。sandboxや署名検証は持たない。

## Validator

```bash
bash tools/validate-agent-directory.sh [--strict] [--full] [--changed] [--self-test] [--base <ref>]
  [--bootstrap-status] [--version]
```

- 通常: 必須構造、frontmatter、Project / Knowledge / Skill schema、registry整合、Independent二重所有、
  Tool allowlist、script構文、HEADに対するraw不変性（`raw/internal/`と`raw/external/`の原記録。
  `knowledge/raw/`直下のCore文書と構造保持用placeholderは対象外）を検査
- `--changed`: 作業ツリーで変更したProject / Knowledge / Skillだけへ対象別検査を絞るFast Path。
  workspace全体に比例しない構造検査は常に実行する。変更がmeta正本へ届く場合、削除・renameを含む場合、
  Git作業ツリーでない場合は全体検査へ戻す。変更targetを参照するtargetもscopeへ含める
- `--base <ref>`: 指定revisionから現在までの差分で、commit済みを含むraw不変性、paused / retired Projectの
  変更禁止、Project削除gateを追加検査。Gitのrename検出で`projects/LIFECYCLE.md#物理位置`の
  明示的なProject物理移行を削除と区別する
- `--strict`: 導入済みWorkspaceとして自己定義placeholderを拒否
- `--full`: 全Markdown参照（`projects/<name>/runs/`は対象外）とIndependent Project整合を追加
- `--self-test`: Tool behaviorと負条件の自己検査を追加。Workspaceの内容を検査しないため通常運用では使わない
- `--bootstrap-status`: `template|deployed`だけを返す
- `--version`: contract versionだけを返す

rawの削除は`knowledge/KNOWLEDGE.md#Secret・privacy削除の限定例外`に限り、
`AGENT_ALLOW_RAW_ERASURE=true`を明示した実行だけが許容する。

公開テンプレートmainは自己定義placeholderを意図的に持つため、製品自身の検証は`--full --self-test`を使う。
consumer導入後は、通常の作業終了時に`--changed`、契約・構造を変更したときと定期点検で`--strict --full`を使う。
自己検査はToolの回帰用であり、consumerの毎回の検証コストに載せない。

## Independent Project

```bash
bash tools/materialize-project-repositories.sh --all|--project <name> [--check]
```

registryと採用revisionから通常cloneを再現する。既存cloneは検査だけを行い、reset、clean、stash、merge、
rebase、remote貼替えをしない。認証は実行環境の標準Git設定が所有し、本Toolはcredentialを保存・探索しない。
Runtime worktreeは一時実行環境として利用できるが、registryのProject attachmentにはしない。

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
| `projects/PROJECTS.md` | 24KiB |
| `STATE.md` / `knowledge/wiki/INDEX.md` | 8KiB |
| active Wiki | 64KiB。24KiB超はRetrieval Map必須 |

入口正本が上限へ近づいたら、重複除去、既存Ownerへの移管、条件付きロード、責務単位の分割の順で
80%以下へ戻す。上限拡大をvalidator通過の手段にしない。
