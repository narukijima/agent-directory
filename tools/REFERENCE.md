# REFERENCE.md — Tool個別契約

Toolの呼出形・結果・停止reasonの参照。Route、境界、予算、自律実行と一覧は`tools/TOOLS.md`が所有する。

## task.sh

```bash
tools/task.sh context --route <route> [--target <path>]
tools/task.sh verify
tools/task.sh finish --route <route> [--target <path>] --message "変更理由"
tools/task.sh finish --route <route> --target <path> --message "変更理由" --current-work
tools/task.sh status
```

通常タスクの薄い入口。`context`はローカルの読込正本とGit Ownerだけを返し、GitHub remote、Agent `.env`、
process tokenの状態では停止しない。GitHub capabilityは外部操作を所有するToolが操作直前に検査する。
`verify`は`--changed`、`finish`は通常変更の検証・commit・backup、`status`はGit rootと変更件数を扱う。
protected変更は`protected-change`へ返す。結果は`TASK_CONTEXT v2`または`TASK_OK|BLOCKED|FAILED`である。

`--current-work`は明示targetの既存成果専用である。AgentがOwner、契約、Single Writer、secret、固有検証を
確認して対象だけをstageし、下位Toolがtarget外／未stage対象差分を拒否して通常finishへ合流する。

## build-context-cache.sh

```bash
bash tools/build-context-cache.sh [--check|--check-routing|--routing-only]
```

生成物:

- `catalog.tsv` — routeable正本の最小metadata。通常検索のFast Path
- `manifest.tsv` — 全正本のinventory。full検証・boundary専用のSlow Path監査物
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

検索backendはlexical catalog、必要時のSQLite FTS5、`rg` / `grep` fallbackの三経路で閉じる。
新しいbackendは、実測された検索欠落または性能上限と、既存経路では満たせない合格条件がある場合だけ追加する。

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
backup（none|root-only|workspace|push-policy）のprofileを決定的に返す（`finalize-task.sh`と同一語彙）。
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

## check-runtime-readiness.sh

```bash
bash tools/check-runtime-readiness.sh [--profile ask|auto|full]
  [--require-codex] [--require-claude]
  [--require-capability <name>]
  [--capability-state <name>=declared|unavailable]
  [--probe-workspace-write]
```

`--profile`はOperatorが選んだProvider非依存の`ask / auto / full`を宣言する。未指定時は`auto`を
`runtime_profile_source=recommended-default`として表示するだけで、Runtime設定を変更しない。
`--require-capability`は`filesystem_read`、`filesystem_write`、`network`、`localhost`、`process_spawn`、`git`、
`github`、`browser`、`api`を反復指定できる。`--capability-state`はRuntimeが知る未実測の`declared`または
既知の`unavailable`を渡す。filesystem writeは要求時または`--probe-workspace-write`指定時に一時fileで実測する。

現在のcwd、filesystem read、process spawn、Gitを観測し、Codex / Claude Codeのexecutable、version、provider authenticationを
別fieldでprobeする。未検査capabilityを`ready`とせず`not-probed`で返す。requiredが`not-probed`なら
`RUNTIME_READINESS_UNVERIFIED`、`unavailable`ならlayer付き`RUNTIME_READINESS_BLOCKED`を返す。
credential environmentは存在だけを報告し、値や認証commandの出力はstdout / stderrへ転送しない。
GitHubの実ready判定はrepository / operationが必要なので、外部操作直前のGitHub認証Toolへ委ねる。
詳細なsetup、Provider mapping、Trust、credential契約は`SETUP.md`が所有する。

## finalize-task.sh

```bash
tools/finalize-task.sh --route project --target projects/<name> --class work --message "変更の一文" [--current-work]
```

work/state専用の決定的終端。staged差分の確認、境界検査、profile準拠の検証（scoped=`--changed`、
meta=`--full`）、commit、backupを1回で実行し、段階ごとの再判断を排除する。profile写像は
`prepare-context.sh`と同一。guarded / contract差分とboundary classは扱わず`tools/CONTROL.md`の
手動経路へ返し、ack環境変数が設定済みの呼び出しは拒否する。Independent Projectでは検証を
Projectの固定検証に委ね（`project-owned`）、pushはPush Policyに従いここから実行しない。
合格は`FINALIZE_OK commit=<sha> validation=<profile> backup=<status>`、拒否は
`FINALIZE_BLOCKED reason=<reason>`をstdoutへ1行で出し非0で終了する。backup失敗はcommit成功を
取り消さない（`tools/BACKUP.md#backupが失敗したとき`）。
`root-only` / `workspace` profileで設定済み`backup`へ到達した後に、Agent側の宛先・送信対象・credential利用の
再承認stepを挟まない。semantic stopは本Toolまたはbackup Toolの決定的reasonだけである。
`--current-work`は明示target必須で、現在の変更がすべてtarget内にあり、その全差分がstage済みであることを
検査する。意味的なownership、secret、別Writer、Project固有検証はAgentが呼出前に判定し、Toolは
それらを推測しない。

## run-evals.py

```bash
python3 tools/run-evals.py score --case <case-name|path> --trace <trace.jsonl> [--baseline <summary.json>] [--json]
python3 tools/run-evals.py run --adapter <executable> (--case <name>... | --all | --profile <core|decay>) \
  [--output-dir <dir>] [--allow-dirty] [--fail-on-regression] [--regression-percent <n>] [--fail-on-unverified]
```

`--profile`は`evals/profiles/<name>.txt`のcase集合を実行する。

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
# finish内部専用: --root-only --fixed-commit <full-sha>
```

有効なPrivate backup remoteが設定済みなら、`tools/BACKUP.md`のStanding Authorizationとtriggerに従い、
宛先・送信対象・credential利用を再確認せず実行する。
scopeはタスク分類表に従う。root backup remoteへpushする唯一の標準経路であり、Independent remoteへは
pushせず、`--dry-run`はremoteへ書き込まない。成功とdry-runはstdoutへ1行の機械可読結果、停止は
`BACKUP_BLOCKED reason=<reason>`をstderrへ出して非0で終了する。trigger、scope、前提条件、
停止reason、divergence、Independent監査項目、復旧・移行手順は`tools/BACKUP.md`が所有し、
扱うときだけ読む。
`--fixed-commit`は正規finishが直前に作ったcommitだけを渡す内部optionで、`--root-only`、full SHA、現在HEADとの
完全一致を必須とする。隔離したcommit treeを監査・pushするため、呼出元のindex、worktree、untracked、stashは
保持・除外される。通常のraw backupとworkspace backupはこの例外を使わずcleanlinessを要求する。

## GitHub認証Tool

通常localは現在のAgent Workspace rootの`.env`だけを使い、明示CIだけprocess tokenを許す。値はisolated childだけへ渡し、
OS home / machine store / 別Agent / global environment / Keychainへfallbackしない。保存は[SETUP.md](../SETUP.md#initial-setup)、
riskは[threat model](THREAT_MODEL.md)が所有する。

```bash
bash tools/setup-github-auth.sh --install-token
bash tools/setup-github-auth.sh --install-from-gh
bash tools/setup-github-auth.sh --workspace-ready --remote backup --operation git-push
bash tools/setup-github-auth.sh --check
bash tools/test-github-auth.sh
```

`--workspace-ready`はnetworkなしでAgent rootの`.env`と必要keyを検査する。
`--check`はAPI / Gitをprobeし`GITHUB_AUTH_OK`、失敗は`GITHUB_AUTH_BLOCKED`を返す。診断
`GITHUB_AUTH_DIAGNOSTIC`はsecretなしでlayer、target、transport、source、enrollment、試行面、到達、reason、status、evidenceを持つ。

reasonはRuntime=`runtime-denied|executable-missing|credential-helper-missing|github-dns-failure|github-network-failure|github-timeout`、
local policy=`agent-env-*|workspace-token-not-fine-grained|github-remote-invalid`、provider=`github-authentication-failed|github-authorization-failed|git-transport-mismatch`、unknown=`github-unknown-failure`。
401/403以外の一般的な`Permission denied`をPAT拒否へ一般化せず、unknownを到達不能へ丸めない。

## report-upstream-issue.sh

許可リスト内の公開上流（既定`claudagt/agent-directory`、`--repo`でリスト内から選択）へ
Issueを送る唯一の経路。宛先は許可リスト固定・添付なし。契約、宛先許可リスト、匿名化検査、
停止reasonは`tools/UPSTREAM.md`が所有し、扱うときだけ読む。

## materialize-project-repositories.sh

```bash
bash tools/materialize-project-repositories.sh --all|--project <name> [--check]
```

registryと採用revisionからcloneを再現し、`--check`は整合だけを検査する。成功は`MATERIALIZATION_OK`、停止は
`MATERIALIZATION_BLOCKED`。欠落時だけ採用SHAへcheckoutし、既存cloneは変形しない。GitHub HTTPS clone / fetch直前に
共有resolverの`git-read`を要求する。`project`は両契約も検査する。

## validate-agent-directory.sh

```bash
bash tools/validate-agent-directory.sh [--strict] [--full] [--changed] [--base <ref>] [--bootstrap-status]
```

- 通常: 必須構造、`AGENTS.md`/`CLAUDE.md`階層、metadata、Project契約とdocs境界、STATE、
  attachmentとroot ownership、サイズ、INDEX/LOG、eval schemaの静的検査
- `--changed`: Git差分で変更されたProject・Knowledge・Skillだけを検査するFast Path。meta正本
  （tools、evals、領域正本、registry、template）へ及ぶ変更は全体静的検査へ自動fallbackする
- `--strict`: 導入後に残してはいけない自己定義・Skillプレースホルダーも失敗にする
  （full静的経路専用。`--changed`とは併用不可で、組合せはusageエラーになる）
- `--bootstrap-status`: 検査せず配布状態（`template|partial|deployed`）だけを1行で返す照会mode。
- `--full`: 全参照、全Knowledge/Skill/Projectに加え、cache再生成、実Git・backup・materializer・
  context Toolの隔離fixtureを検査。Tool、eval、正本規約を変更した作業では必須とする
- `--base <ref>`: Git差分から`knowledge/raw/`、閉鎖済みlog、Project物理移動の禁止を検査
- 終了コード0と`PASS: agent-directory structure is valid`が合格条件。

`AGENT_VALIDATOR_METRICS=true`を明示した計測runだけ、`static`、`full-core`、
`control`、`epilogue`の所要時間と全体wall timeを`.agent-cache/metrics/*.jsonl`へ記録する。通常runは
時刻取得processもmetrics書込も行わず、計測結果は削除・再生成可能な派生物として扱う。

機械検査する境界の網羅的な正本はvalidator本体、`evals/EVALS.md`の各最低条件、`tools/BACKUP.md`で
ある。AGENTS三層とProject docsの完全な構造規則は`projects/PROJECTS.md`が所有し、validatorは
その境界・必須見出し集合・サイズを機械検査する。どのmodeも実GitHub接続、`gh` CLI、認証情報を必要としない。

## check-boundary.sh / install-git-hooks.sh

commit・push境界のPortable Verifierと、managed hook・承認済みsnapshotのinstaller。usage、
結果line、導入・除去の契約、tier意味論、ack・receipt条件、違反分類は`tools/CONTROL.md`が
所有し、扱うときだけ読む。hookは境界検査だけを行い、backup・validator・ネットワーク操作を
起動しない（`tools/BACKUP.md`の非ゴールを変更しない）。

## 内部実装ライブラリ

単体の呼び出し契約を持たず、上記Toolからsourceされる共有実装。直接実行しない。

- `tools/lib/project-registry.sh` — `projects/REPOSITORIES.md` registryの正規parseを単一実装として
  提供し、validator・boundary検査・materializerが共有する。
- `tools/lib/github-auth.sh` — GitHub認証の共有実装（契約は`#GitHub認証Tool`）。
- `tools/validator/check-context-meta.sh` — routeableなmeta正本のcatalog登録漏れとretired path混入を検査する。
- `tools/validator/check-markdown-references.sh` — Markdown参照・anchor整合検査の実体。validatorと
  receipt発行が呼ぶ。
- `tools/validator/test-router-boundaries.sh` — 自己定義を除くrouter予算、CRLF / EOF境界、STATE anchorを
  full検証から独立してfixture検査する。
