# REFERENCE.md — Tool個別契約

`tools/TOOLS.md#Tool一覧`に登録された固定Toolの呼び出し形・入出力・生成物・停止reasonの正本。
条件付きロード専用とし、扱うToolの節だけを読む（一括読込しない）。Route、境界、予算、
自律実行の規約は`tools/TOOLS.md`が所有し、本書はTool個別の契約だけを持つ。下流Workspaceの
固有Toolも、登録は`tools/TOOLS.md#Tool一覧`へ1行、詳細は本書へ節を追加して所有させる。

## task.sh

```bash
tools/task.sh context --route <route> [--target <path>]
tools/task.sh verify
tools/task.sh finish --route <route> [--target <path>] --message "変更理由"
tools/task.sh status
```

通常タスクの薄い入口。`context`は互換実装の`prepare-context.sh`からtask classとprofileを隠して
読む正本とGit所有境界だけを返す。`verify`は変更集合から`--changed`検証を起動し、meta変更はvalidatorが
full staticへ自動fallbackする。`finish`は通常変更だけを`finalize-task.sh`へ委譲し、protected変更は
`TASK_BLOCKED reason=protected-change`として手動の安全経路へ返す。`status`はGit rootと変更件数だけを返す。

正規結果は`TASK_CONTEXT v2`、`TASK_OK`、`TASK_BLOCKED`、`TASK_FAILED`のいずれかである。下位Toolの
診断はstderrへ保持し、既存consumer向けの結果語彙を変更しない。

## build-context-cache.sh

```bash
bash tools/build-context-cache.sh [--check|--check-routing|--routing-only]
```

生成物:

- `catalog.tsv` — routeable正本の最小metadata。通常検索のFast Path
- `manifest.tsv` — 全正本のinventory。Maintenance・full検証・boundary専用のSlow Path監査物
- `cache.meta` — schema、generator hash、fingerprint、件数、検索backend
- `stat.meta` — warm fast path用stat指紋。`--check`の比較対象にしない
- `search.sqlite` — routeable Knowledge 1,000件またはcatalog 5,000行で自動生成するFTS5 trigram派生索引

`--routing-only`はcatalog系だけをpath順で決定的に再生成し、manifestへ触れない。
`--check-routing`はstat指紋（path+size+mtime）一致なら本文再読なしで即PASSし、不一致・欠損時だけ
routeable正本を再計算して比較する（Git HEADは鮮度入力にしない）。

`ARCHITECTURE.md`、Project docs、`knowledge/raw/`はrouteable catalogへ入れず、通常検索結果へ
全件投入しない。Embeddedはroot indexの`projects/*/PROJECT.md`、Independentは
`projects/REPOSITORIES.md`から列挙し、採用revisionのfrontmatterだけを`git show`で読む。
登録済み`projects/<name>/`の本体はmanifest・fingerprint・SQLite body・fallback grepへ入れない。

`search.sqlite`はGit管理外で毎回正本から作り、外部content table、DBだけへの保存、ベクトルDBの
既定導入は行わない。閾値上書き（`AGENT_SQLITE_*_THRESHOLD`）はfixture検証専用。
`AGENT_DIRECTORY_ROOT`は各Toolの対象root、`AGENT_CACHE_DIR`はcache出力先を差し替える（既定値運用）。

## find-context.sh

```bash
tools/find-context.sh --route knowledge|skill|project|meta [--limit 1..5] [--include-inactive] -- "検索語"
```

- 通常はactiveだけを返す。
- name完全一致、alias完全一致、metadata部分一致、本文一致の順に候補を決め、pathで同順位を固定する。
- cacheが欠損・stale・破損なら`--routing-only`で一度だけ再生成し、manifestを作らない。
- 本文検索はFTS5 trigramが使えれば`search.sqlite`、なければ`rg`、それもなければ警告して
  `grep`/`find`へfallbackする。
- 出力は最大5件のmetadataだけ（確定後の正本読込は`AGENTS.md#Context Loading`が所有）。

## prepare-context.sh

```bash
tools/prepare-context.sh --route project --target projects/<name> --class work
```

Route確定後の初期読込を1回のContext Packetへまとめ、Git root、attachment、Required参照、
読込順序を決定的に列挙する（本文は出力しない）。classからvalidation（none|scoped|full）と
backup（none|root-only|workspace|independent-origin）のprofileを決定的に返す。
Conditionalの成立判断はエージェントが行い、読込予算・読込順序の規約は変えない。
出力は`TASK_CONTEXT v1`のkey=value行と`READ:`/`CONDITIONAL:`/`MISSING:`のpath列。

## setup-local-environment.sh

```bash
bash tools/setup-local-environment.sh
```

Codex Desktopの`.codex/environments/agent-directory.toml`とClaude Codeの共有
`.claude/settings.json`が呼ぶ唯一のローカル初期化Tool。`bash`、`git`、`python3`とGit rootを検査し、
worktree固有の検索cacheを冪等に生成する。`user.name`は明示override、既存repo-local値、
`AGENTS.md#自己定義`の推奨Agent名の優先順で扱い、推奨名はlocal値が無い場合だけ既定設定する。
明示overrideは`--git-author-name <name>`または`AGENT_DIRECTORY_GIT_AUTHOR_NAME`で渡せる。
emailと既存履歴は変更しない。
新鮮なcacheはstat指紋のfast pathで再利用する。
依存packageの追加、`.env*`のコピー、Git hook・remote・
scheduleの変更、ネットワーク接続は行わない。成功は`LOCAL_ENVIRONMENT_READY`、停止は
`LOCAL_ENVIRONMENT_BLOCKED reason=<reason>`を返す。

## finalize-task.sh

```bash
tools/finalize-task.sh --route project --target projects/<name> --class work --message "変更の一文"
```

work/state専用の決定的終端。staged差分の確認、境界検査、profile準拠の検証（scoped=`--changed`、
meta=`--full`）、commit、backupを1回で実行し、段階ごとの再判断を排除する。profile写像は
`prepare-context.sh`と同一。guarded / contract差分とboundary classは扱わず`tools/CONTROL.md`の
手動経路へ返し、ack環境変数が設定済みの呼び出しは拒否する。Independent Projectでは検証を
Projectの固定検証に委ね（`project-owned`）、pushはPush Policyに従いここから実行しない。
合格は`FINALIZE_OK commit=<sha> validation=<profile> backup=<status>`、拒否は
`FINALIZE_BLOCKED reason=<reason>`をstdoutへ1行で出し非0で終了する。backup失敗はcommit成功を
取り消さない（`tools/BACKUP.md#backupが失敗したとき`）。

## run-evals.py

```bash
python3 tools/run-evals.py score --case <case-name|path> --trace <trace.jsonl> [--baseline <summary.json>]
python3 tools/run-evals.py run --adapter <executable> (--case <name>... | --all)
```

`score`は保存済みtraceだけを採点し、`run`はcaseごとにGit管理対象とfixtureを一時workspaceへ重ねて
adapterを実行後、同じ採点器へ渡す。adapterは`--request`、`--workspace`、`--trace`を受ける実行可能
ファイルで、Providerや特定クライアントはToolの依存ではない。生成trace、request、summaryは既定で
`.agent-cache/evals/`へ置き、正本にしない。traceの観測・信頼・regression契約は
`evals/EVALS.md#Context trace`が所有する。採点完了は0、期待違反・adapter失敗・指定hard gateは1、
入力・schema・依存adapterの不備は2で終了する。

## append-knowledge-log.sh

```bash
tools/append-knowledge-log.sh --type ingest --target knowledge/wiki/topics/example.md --summary "変更内容"
```

- 入力は例のとおり（任意で`--date YYYY-MM-DD`）。
- 出力: `APPENDED: <date> <target>`、ローテーション時は`ROTATED: <path> (<記録数>, <byte数>)`を追加。
- 追記先は`knowledge/wiki/LOG.md`だけとし、サイズ予算表のLOG閾値で`logs/YYYY-QN[-NN].md`へ閉じ、
  現在のLOGをヘッダーだけへ戻す。閉鎖済みlogは以後変更しない。
- 記録の種別と意味的な運用規則は`knowledge/KNOWLEDGE.md#LOG`が所有する。

## backup-to-github.sh

```bash
bash tools/backup-to-github.sh [--remote backup] [--branch main] [--dry-run] [--root-only]
```

有効なPrivate backup remoteが設定済みなら、`tools/BACKUP.md`のtriggerで確認を求めず実行する。
scopeはタスク分類表に従う。root backup remoteへpushする唯一の標準経路であり、Independent remoteへは
pushせず、`--dry-run`はremoteへ書き込まない。成功とdry-runはstdoutへ1行の機械可読結果、停止は
`BACKUP_BLOCKED reason=<reason>`をstderrへ出して非0で終了する。trigger、scope、前提条件、
停止reason、divergence、Independent監査項目、復旧・移行手順は`tools/BACKUP.md`が所有し、
扱うときだけ読む。

## GitHub認証Tool

`tools/lib/github-auth.sh`はIssue送信とbackupが共通利用する唯一のresolverで、process `GH_TOKEN` →
process `GITHUB_TOKEN` → Workspace `.env` → マシン共通`github.env` → `gh`保存認証の順に解決する。
値は出力せず、machine directory `0700`・file `0600`以外をfail closedする。APIは`gh api user`、Gitは
実remote readで能力を判定し、GitHub HTTPSだけ`gh auth git-credential`をchild Gitへ適用する。
SSHとGitHub以外のhostへGitHub credentialを渡さない。

```bash
bash tools/setup-github-auth.sh --install-from-gh
bash tools/setup-github-auth.sh --check
bash tools/setup-github-auth.sh --repair-from-gh
bash tools/migrate-github-auth.sh --workspace /absolute/path [--check]
bash tools/test-github-auth.sh
```

doctor成功は`GITHUB_AUTH_OK source=<source> login=<login> api=ok git=ok`、失敗は
`GITHUB_AUTH_BLOCKED reason=<reason>`。migrationはsignature、Git root、auth fileのclean状態、対応version、
patch適用可否を先に検査し、tokenやAgent固有設定を扱わない。
`--expected-login <github-login>`はaccountを固定したい場合だけ使う任意の厳格照合である。
`--remote`未指定時は`remote.pushDefault`、`backup`、`origin`の順で実在remoteを解決し、存在しなければ
`remote-not-configured`を返す。

## report-upstream-issue.sh

許可リスト内の公開上流（既定`claudagt/agent-directory`、`--repo`でリスト内から選択）へ
Issueを送る唯一の経路。宛先は許可リスト固定・添付なし。契約、宛先許可リスト、匿名化検査、
停止reasonは`tools/UPSTREAM.md`が所有し、扱うときだけ読む。

## materialize-project-repositories.sh

```bash
bash tools/materialize-project-repositories.sh --all|--project <name> [--check]
```

registryの登録と採用revisionから`projects/<name>/`へ通常cloneを再現する（復旧、移行、partial解消）。

- 入力: `--all`か`--project <name>`と任意の`--check`（cloneせず整合だけを検査）。列挙は
  `projects/REPOSITORIES.md`だけを正本とし、`PROJECT.md`のfrontmatterを走査しない。
- 出力: 成功は`MATERIALIZATION_OK total=<n> cloned=<n> verified=<n>`をstdoutへ1行、停止は
  `MATERIALIZATION_BLOCKED reason=<reason> project=<name>`をstderrへ出し非0で終了する
  （停止reasonの正本はTool出力とvalidator隔離fixture）。
- targetが無いときだけ採用revisionをdetached checkoutし、branch tipへ勝手に進めない。既存cloneは
  HEADと採用SHAの一致まで検査し（detached HEADは要求しない）、reset、clean、stash、merge、rebaseで
  変形しない。認証情報を保存せず、絶対pathを正本へ書かない。
  `AGENT_ALLOW_LOCAL_REPOSITORY_URL=true`は隔離fixture専用。

## run-routine.sh

```bash
bash tools/run-routine.sh maintenance [--dry-run|--full]
```

Scheduler起点のRoutine Executor。lock、preflight、cache鮮度、検証、任意推論、scoped commit、
policy準拠backupの規則は`routines/ROUTINES.md`と各`ROUTINE.md`が所有する。出力はstdout最終1行の
`ROUTINE_NOOP|OK|SKIPPED|BLOCKED|FAILED`、詳細はstderrと`.agent-cache/routines/logs/`。

## manage-routine-schedule.sh

```bash
bash tools/manage-routine-schedule.sh --routine maintenance --scheduler auto --at 03:00 --print
```

user crontabとuser LaunchAgentだけを扱うSchedule管理。`--scheduler auto|cron|launchd`と
`--print|--install|--status|--remove`を持ち、冪等で無関係entryを保持する。installは利用者の明示操作であり、Routine実行やclone直後に
OS scheduleを変更しない。出力は`SCHEDULE_*`の1行。

## routine-reasoner.py

Python 3標準ライブラリだけの任意推論アダプター（`--request` / `--inspect-patch`）。
Provider（`deepseek | openai | anthropic`）、model ID、APIキーは`.env`が所有し、
未設定でも決定的Maintenanceは動作する。送信境界とpatch上限は`routines/ROUTINES.md`が
所有し、モデル出力のshell commandは実行しない。

## validate-agent-directory.sh

```bash
bash tools/validate-agent-directory.sh [--strict] [--full] [--changed] [--base <ref>]
```

- 通常: 必須構造、`AGENTS.md`/`CLAUDE.md`階層、metadata、Project契約とdocs境界、STATE、
  attachmentとroot ownership、サイズ、INDEX/LOG、eval schemaの静的検査
- `--changed`: Git差分で変更されたProject・Knowledge・Skillだけを検査するFast Path。meta正本
  （tools、evals、routines、領域正本、registry、template）へ及ぶ変更は全体静的検査へ自動fallbackする
- `--strict`: 導入後に残してはいけない自己定義・Skillプレースホルダーも失敗にする
- `--full`: 全参照、全Knowledge/Skill/Projectに加え、cache再生成、実Git・backup・materializer・
  context Toolの隔離fixtureを検査。Tool、eval、正本規約を変更した作業では必須とする
- `--base <ref>`: Git差分から`knowledge/raw/`、閉鎖済みlog、Project物理移動の禁止を検査
- 終了コード0と`PASS: agent-directory structure is valid`が合格条件。

`AGENT_VALIDATOR_METRICS=true`を明示した計測runだけ、`static`、`full-core`、`routine`、`scheduler`、
`control`、`epilogue`の所要時間と全体wall timeを`.agent-cache/metrics/*.jsonl`へ記録する。通常runは
時刻取得processもmetrics書込も行わず、計測結果は削除・再生成可能な派生物として扱う。

機械検査する境界の網羅的な正本はvalidator本体、`evals/EVALS.md`の各最低条件、`tools/BACKUP.md`で
ある。AGENTS三層とProject docsの完全な構造規則は`projects/PROJECTS.md`が所有し、validatorは
境界とサイズだけを固定する。どのmodeも実GitHub接続、`gh` CLI、認証情報を必要としない。

## check-boundary.sh / install-git-hooks.sh

commit・push境界のPortable Verifierと、managed hook・承認済みsnapshotのinstaller。usage、
結果line、導入・除去の契約、tier意味論、ack・receipt条件、違反分類は`tools/CONTROL.md`が
所有し、扱うときだけ読む。hookは境界検査だけを行い、backup・validator・ネットワーク操作を
起動しない（`tools/BACKUP.md`の非ゴールを変更しない）。
