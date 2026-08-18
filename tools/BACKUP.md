# BACKUP.md — 遠隔バックアップと復旧

backup trigger、remote分類、失敗、divergence、復旧、マシン移行、監査を扱うときに読む。通常作業では
読まず、設定済み自動backupの実行だけなら`tools/REFERENCE.md#backup-to-github.sh`で足りる。

## 目的と非ゴール

目的は、ローカル正本を最後の確定commitから再構築できる遠隔copyを1つ持つこと。GitHubを正本、queue、
task / deploy / cloud同期基盤、双方向同期・競合解決、CI / hook / daemon / 時刻駆動backupにはしない。
backup状態やremote SHAをGit追跡する正本も作らない。

## 用語

- **Remote Backup** — エージェント1体ごとのGitHub Privateリポジトリ。最後に正常pushされた`main`の
  受動的な復旧コピーで、直接編集しない。
- **Agent Workspace / root repository** — agent-directoryのツリー全体と、そのrootのGit。rootは
  Embedded Projectの履歴とattachment registryを持つ。
- **Embedded / Independent** — attachmentの区別（定義、昇格条件、登録形式は
  `projects/PROJECTS.md#Attachment`）。
- **Materialization** — 登録と採用revisionから`projects/<name>/`のcloneを再現すること。一部だけ
  存在するpartial materializationは、復旧途中のdegraded stateとしてだけ許す。

## バックアップ対象

`main`のコミットから到達可能なGit管理ファイルと履歴を対象とする。永続正本と永続成果物は、領域を問わず
Git追跡されていること。対象外は次で、復旧は別経路で行う。

- `.env`、`.env.local`などの秘密情報、SSH鍵、Git認証情報、ローカルGit設定
- `.tmp/`、`.agent-cache/`、`.DS_Store`、製品側AIメモリ
- 未コミット変更、未追跡ファイル、`git stash`
- `main`から到達できないローカルbranch、reflogだけに存在するコミット
- Independent repository本体。履歴の保全はそのremoteが持ち、rootはregistry entryだけを保全する。

永続正本を`.gitignore`へ追加してバックアップ対象外にすることは禁止する。対象外にしたい情報は、
そもそも正本として置かない。

許可されるnested Gitは登録済みの`projects/<name>/.git/`だけで、それ以外のnested Gitとsubmoduleは
ignore状態にかかわらずToolが停止する（backup対象外の派生領域`.tmp/`・`.agent-cache/`は走査しない。
エージェント側の扱いは`projects/PROJECTS.md#Attachment`）。

## リポジトリ構成

- リポジトリは共用せず、remote名の既定値は`backup`、branchは`main`とする。
- remoteは常にpush先であり、GitHub Web UI、Codespaces、別マシンから直接編集しない。
- Private可視性はセットアップ契約であり利用者が確認する。Toolは可視性を照会・変更しない。

## GitHub認証

認証source、secret境界、HTTPS / SSH判定、doctor、結果語彙は
`tools/REFERENCE.md#GitHub認証Tool`だけが所有する。backupは同じresolverと`git-read` / `git-push` allowlistを使い、認証失敗と
remote未設定・divergence・到達不能・push失敗を区別する。認証失敗でも検証済みlocal commitを取り消さない。
通常backupはcredential repairや別sourceへのfallbackを行わない。

## backup Tool

Toolは1つだけであり、scopeをoptionで選ぶ。別のbackup Toolを追加しない。

### scope

```bash
bash tools/backup-to-github.sh [--dry-run] [--root-only]   # 既定はworkspace scope
```

workspace scope（CLI既定）はroot pushの前に全Independent repositoryを監査し、Independent自体は
pushしない。全repositoryがremoteから復旧可能な場合だけ成功とし、partial materializationでは停止する。
`--root-only`はrootだけを検査・pushする部分結果で（静的metadataとroot ownership違反は検査する）、
workspace全体の成功として報告しない。タスク分類との対応は`tools/TOOLS.md#タスク分類と終端処理`が
所有する。

正規finishはcommit直後のfull SHAを内部option `--fixed-commit <full-sha>`で渡す。`--root-only`専用で、
指定SHA=現在HEAD、到達不能local branchなし、処理中のHEAD不変を要求する。隔離commit snapshotへ通常の
root検査を行うため、別targetに残るindex、worktree、untracked、stashを保持・除外できる。raw実行と
workspace scopeのcleanlinessは緩めない。

| scope | 成功（終了コード0） | dry-run成功 |
|---|---|---|
| workspace | `WORKSPACE_BACKUP_OK remote=<r> branch=<b> sha=<sha> independent=<n>` | `WORKSPACE_BACKUP_READY …` |
| `--root-only` | `ROOT_BACKUP_OK remote=<r> branch=<b> sha=<sha> scope=root-only` | `ROOT_BACKUP_READY …` |

### 共通

停止は両scopeとも`BACKUP_BLOCKED reason=<reason>`をstderrへ出し非0で終了する。stdoutの1行が
機械可読結果、stderrの`DETAIL:`が人間向け補足。

root前提条件は次である。ひとつでも満たさない場合、Toolは何も変更せず停止する。

1. `AGENTS.md`と`tools/validate-agent-directory.sh`を持つGitリポジトリrootで、現在branchが
   指定branch（detached HEADでない）、指定remoteが設定済みである。
2. index、tracked working tree、未追跡の非ignoreファイル、`git stash`がすべて空である
   （正規finishのroot-only fixed-commit modeだけは呼出元状態を隔離snapshotから除外・保持する）。
3. 指定branchから到達できないローカルbranch commitがない。
4. `.tmp/`、`.agent-cache/`、`.env`実値、`.DS_Store`がGit追跡されていない。
5. 登録済みIndependent以外のnested Git、submodule、Git LFSがなく、100MiB以上の到達可能blobもない。
6. `projects/REPOSITORIES.md`の構造と、`projects/.gitignore`のmanaged blockが登録集合と一致する。
7. root indexが登録済み`projects/<name>/`配下のpathもmode 160000のgitlinkも持たない。
8. 旧`projects/<name>/repository/`、旧repository frontmatter、旧`## Repository State`が残っていない。
9. rootのremote branchが未作成であるか、remote SHAがbackup開始時に固定した監査対象SHAのancestorである。

`--root-only`でも6〜8の静的境界は検査する。workspace scopeでは、さらに各Independent repositoryを
次の順で監査する。remote refsとlocal refsの到達性は一時bare repositoryで検査する。

1. **attachment** — `projects/<name>/`に存在し、targetと`.git`がsymlinkでなく`.git`が実directory
   （`.git` fileは非対応）で、toplevelと`remote.origin.url`が登録と完全一致する。
2. **構造** — submodule、追加のnested Git、Git LFSがない。`repository_role`が既定の`project`なら
   HEADに`PROJECT.md`と`STATE.md`が存在し、`public-foundation`ならOwner Agent rootがactive状態を
   所有するため両ファイルを要求しない。
3. **cleanliness** — staged、tracked dirty、非ignoreのuntracked、stashがない。
4. **到達性** — remoteへ到達でき採用revisionをfetchでき、HEADが採用revisionと一致し、HEADと全local
   branch tipがremote headまたはtagから到達でき、local-onlyなtagがない。

構造的に非対応な状態（2）はcleanliness（3）より先に判定し、原因を未追跡ファイル報告で隠さない。

停止reasonの網羅的な正本はTool出力とvalidatorの隔離fixtureである。

Toolはbackup開始時のroot HEADを監査対象SHAとして固定し、object監査、Independent repository監査後の
push source、事後検証を同じSHAへ束縛する。push後に`git ls-remote`でremote SHAと監査対象SHAの完全一致を
確認する。remote通信はこのpushと事後検証だけで、無条件の事前照会はdry-runに限り、push拒否時だけ
remoteを読んで`remote-diverged`等へ分類する（拒否はremoteを変更しない）。実行中にroot HEADが動いた場合、
新しいcommitを送信せず、または既に監査対象SHAだけを送信した後に`head-moved-during-backup`で停止し、
checkpointを更新しない。事後検証済みSHAは
`.agent-cache/`のcheckpoint（削除可能な派生状態。remote URLはhash保持）へ記録し、次回の
oversized object監査を新規範囲だけにする。欠損・破損・不一致・非ancestorでは全履歴監査へ
fallbackする。

`AGENT_BACKUP_MAX_BLOB_BYTES`は隔離fixture検証だけで使う閾値上書きであり、通常運用では設定しない。

## Toolが行わないこと

対象を確定するのは検証済みcommitであり、Toolはadd / commit / stash、pull / merge / rebase / reset / clean、
worktree変更、force系・mirror・全ref push、ref削除、競合解決、secret保存、remote作成・可視性変更、Actions、
Independent remote書込、子cloneの変形を行わない。

## remoteの分類

remoteを目的ごとに分け、許可操作とauthorizationを混同しない。Runtimeのnetwork・credential利用可否は
本表の責務ではない。

| remote | 目的 | 許可操作 | Authorization source |
|---|---|---|---|
| workspace `backup` | 受動的な復旧コピー | このToolのfast-forward pushだけ | 設定済みなら自動 |
| skeleton `origin` | 公開スケルトンの開発remote | 読み取り専用fetch、検証済みcommitの通常push、PR必須rule時の限定remote mergeとsource branch削除 | スケルトン保守の依頼範囲内 |
| workspace `template` | 導入後に残す上流スケルトン参照 | 読み取り専用fetch（上流比較・first-push検証） | 設定済みなら自動 |
| Independent `origin` | Project固有remote | Independent sessionのfetchと通常push、PR必須rule時の限定remote mergeとsource branch削除 | Projectのpush policyまたは明示push依頼 |

設定済みworkspace `backup`への正規finishは、検証済み固定SHAのfast-forward pushとremote SHA照合まで
Standing Authorization済みで、Agentは宛先・内容・credential利用を再承認させない。Runtime promptはRuntimeが
所有する。対象は本Toolの操作だけであり、remote / credential不明、secret、未確定状態、対象漏れ、divergence、
Writer / ownership衝突、境界違反では停止する。force、remote変更、開発remote push、PR操作へは拡張しない。

実運用のAgent Workspaceは開発remoteを持たず`backup`だけを持つ。公開スケルトンへ実運用データをpushせず、
導入時にスケルトンの`origin`を`template`へ改名するか削除する。`AGENTS.md#禁止事項`のlocal pull / merge / rebase、
force push禁止は全分類へ適用する。PR必須ruleのremote完了経路とIndependent側のpush policyは
`projects/PROJECTS.md#Remote操作の境界`が所有する。

本Toolはremote branchを削除しない。PR source branchの限定cleanupは同節のmerge確認後だけ行う。

registryの`repository_url`規則は`projects/REPOSITORIES.md`が所有する。Toolは違反と`-`で始まるURLを
`invalid-registry`で拒否し、報告経路でもuserinfoのpasswordを伏せる。

## Single Writer

Single WriterはAgent単位ではなくGitリポジトリ単位の制約である。同じrepositoryへ同時に書き込む
Writerを持たない。異なるIndependent repositoryは並行して進めてよいが、materializationまたは
migrationの実行中は対象repositoryのWriterを停止する。

## root での `git clean`

rootからignoreされるIndependent Projectを消しうるため、rootで`git clean -x`、`-X`、二つ以上の`-f`を
使わない。曖昧な掃除は停止し、一意なpathと未所有・未push状態を検査した最小操作だけを明示依頼に基づき行う。
危険性の検証は破棄前提fixtureに限定する。

## 実行trigger

有効なPrivate backup remoteが設定済みなら、次のタスク境界で宛先・送信内容・credential利用の再確認をせず
backupを実行する。
未設定なら実行せず、その事実を報告する。

- 正常に検証・commitされた意味のある変更の後
- 明示された現在作業を、Owner・target・secret・競合確認と固有検証後に正規finish経路でcommitした後
- 復旧可能性に関わるmetadata変更後
- Independent Projectの採用revision更新後
- 破壊的変更前や長い作業を中断する際のcleanな検証済みcheckpoint
- マシン移行前

ファイル1件ごとにpushせず、意味のあるcommit境界で実行する。フルvalidatorの合否はbackupの
必須条件ではない。壊れた状態の保全にもbackupを使う。

外部scheduled triggerの到達自体はbackup triggerではない。通常taskが検証済みcommitを作った場合だけ
上記triggerが成立し、定期実行専用のbackup経路は作らない。

明示された現在作業もraw Toolへ渡さず、`tools/TOOLS.md#自律実行の標準完了`どおり対象だけを検証・stageし、
`task.sh finish --current-work`でcommitする。target外差分、所有者不明、secret、Writer競合はcommitしない。

## backupが失敗したとき

未設定、到達不能、一時失敗でも検証済みlocal commitを取り消さず、次を区別して報告する。

```text
local task: complete
local commit: complete
backup: failed / skipped / blocked
recoverability: degraded
```

remote復旧性が成果契約なら未完了、それ以外はbackup結果をtask / validation結果と混同しない。

秘密情報、未コミット状態、remote divergence、対象漏れ、GitHubのhard limit、Single Writer違反、remoteの
想定外変更は停止条件である。これらを自動解決せず、`AGENTS.md#人間へ上げる例外`として上げる。

## 未公開履歴のprivacy訂正

`unsafe-git-email`または`sensitive-content`が、privacy検査の導入前に作られた未公開commitを原因として
`--range`で停止し、前進commitでは過去のmetadataやblobを除去できない場合だけ、この限定復旧を使う。
allowlistは意図的に公開する値の宣言であり、hostname由来メール、個人home path、誤って入れた値を通す
復旧手段ではない。この復旧だけを通常のrebase・履歴書換え禁止の例外とし、remote base以後の未公開suffixに
限定する。公開済みcommit、曖昧な置換、secret、別Writerが関わる場合は停止する。実行・照合手順は
`tools/BACKUP-RECOVERY.md#未公開履歴のprivacy訂正`を条件付きで読む。

## divergenceの停止

remote SHAがローカルHEADのancestorでない場合、Toolは何も変更せず`remote-diverged`で停止し、
remote SHAとlocal SHAを報告する。分岐は別マシンからの書込、GitHubでの直接編集、Single Writer違反を
意味し、原因特定と採用は利用者が決定する。

## マシン移行

旧Writerが`WORKSPACE_BACKUP_OK`を得て停止した後、新cloneを検証して唯一のWriterへ昇格する。
Independent materialization、cache再生成、secretの別経路復旧を含む手順は
`tools/BACKUP-RECOVERY.md#マシン移行`を条件付きで読む。

## 障害復旧

復旧点は最後に成功したbackup commitであり、それ以後の未commit・未追跡・stashは復元できない。
失われた範囲を明示し、secret、cache、Independent cloneを別経路または正本から再構築する。手順は
`tools/BACKUP-RECOVERY.md#障害復旧`を条件付きで読む。

## 旧構造からの移行

Project rootは`projects/<name>/`だけである。旧`projects/<name>/repository/`方式と、
agent-directory外へcloneを置く旧方式は、残さず併存も認めず、検出時は
`deprecated-repository-layout`として扱う。dirty・未pushを置換せず、rootとchildを別commitに保つ移行手順は
`tools/BACKUP-RECOVERY.md#旧構造からの移行`を条件付きで読む。

## 大容量ファイル

Git LFSは既定構成へ導入しない。submodule、Git LFS、100MiB以上のobjectは停止し、大容量artifactの
保管先とchecksumはProjectが定義する（`tools/BACKUP-RECOVERY.md#大容量ファイル`）。
