# ROUTINES.md — Routine Trigger Control Layer

RoutineはCoreではなく、SchedulerがAgentの作業を起動するOptional Trigger層の正本である。
Routine関連の作業時だけ読み、通常のHuman起点タスクのcontext、検証、終了処理へ読み込まない。

## 位置づけ

- RoutineはRouteではない。Knowledge、Skill、Project、Metaと並ぶ成果物分類を追加せず、
  既存Routeを起動するTrigger起点である。Trigger起点がHumanでもRoutineでも、
  Route、Owner、Target、Verify、`AGENTS.md#人間へ上げる例外`の規則は同一に適用する。
- 1回のRoutine実行は有限タスクである。反復はSchedulerが所有し、同一LLM sessionや
  同一プロセス内で無限ループしない。実行ごとにプロセスを終了する。
- 毎回リポジトリ正本から開始する。前回実行の会話記憶、派生キャッシュ、runtime状態を
  正本として引き継がない。
- 初期版のRoutineはMaintenance（`routines/maintenance/ROUTINE.md`、Route=`meta`）だけである。
  Research Routineは未実装であり、先回りの雛形も置かない。

## 責務分離

```text
Scheduler（cron / launchd） = いつ起動するかだけを所有する
Executor（tools/run-routine.sh） = 決定的な検査・保守・検証・commitを所有する
Model Provider（任意） = 決定的検査が示した異常の分析と低リスク修復候補だけを所有する
```

- deterministic phaseは推論モデルなしで完結する。Provider・APIキー未設定はエラーではなく、
  推論層だけを`disabled` / `unconfigured`として区別する。
- 一般的なUnix環境の標準Schedulerはcron、macOSの推奨はlaunchdである。CI、GitHub Actions、
  常駐daemon、AI製品固有SchedulerをRoutine実行基盤にしない。

## 標準フロー

```text
Scheduler
  → Routine instance lock
  → Git・working tree・base SHA preflight
  → deterministic maintenance
  → 必要な場合だけoptional reasoning
  → isolated verification（一時snapshot）
  → real workspace再確認（HEAD・対象hash・cleanliness）
  → 適用
  → verification
  → tracked変更がある場合だけscoped commit
  → commitができた場合だけ`tools/BACKUP.md`のpolicyに基づくbackup
  → machine-readable report（stdout 1行）
  → process終了
```

## Single Writerと競合防止

- Routineの多重起動と同一Git rootへの並行書込は、Git rootに1つのatomicなwriter lockで防ぐ。
  lockは`.agent-cache/routines/locks/`に置き、routine id、PID、hostname、Git root、開始時刻、
  base SHAを記録する。
- 有効なlock、または所有者を判定できないlock（info欠損・不正PID等）があれば、何も変更せず
  `SKIPPED`する。staleとして除去できるのは、同一hostnameでPIDの死を機械的に証明できる
  場合だけである。他hostのlockは除去しない。
- Human-triggered AgentはRoutine lockを持たないため、lockだけを信用しない。開始時に
  working treeがcleanでなければ`SKIPPED`し、所有者不明の変更を上書きしない。
- tracked変更の適用直前とcommit直前に、HEADがbase SHAのままであること、対象ファイルの
  content hashが開始時と一致すること、working treeに混入がないことを再確認する。
  変化を検出したら適用せず`SKIPPED`または`BLOCKED`する。
- 1回のRoutineが書くGit rootは自分の1つだけである。登録済みIndependent repositoryは
  read-only監査対象にでき、root Routineから修正・commit・pushしない。

## 派生状態

`.agent-cache/routines/`はGit管理外の派生領域であり、lock、run log、実行状態
（最終full検証時刻など）だけを置く。正本をここへ保存せず、Git追跡もしない。

Routineが削除・整理してよいのは、自分が生成した`.agent-cache/routines/**`の派生物だけである。
`.tmp/`の所有者不明作業、Project outputs、runs、Knowledge原資料・wiki、Git branch・stash・reflog、
Independent repository、利用者の未追跡ファイルを「古そう」という理由で削除しない。

## 予算と上限

| 対象 | 上限 |
|---|---|
| 外部送信payload全体（指示＋診断＋context） | 最大12ファイル・合計32KiB |
| model call | 1回のRoutineで既定1回、絶対上限3回 |
| model timeout | `.env`の設定値。既定900秒。超過は`model-timeout`として報告 |
| model出力token | 既定は上限を送らない（Anthropicのみ`max_tokens`必須のため未設定時8192）。上限超過で切れた応答は`output-truncated`として適用しない |
| 自動patch | 最大3ファイル・32KiB・200変更行 |
| 実行時間 | 1回のRoutineは有限時間で終了し、常駐しない |

上限超過は自動適用せず`BLOCKED`として報告する。

## 外部Providerへの送信

- Providerは`deepseek | openai | anthropic`だけをサポートし、`.env`で利用者が1つを選ぶ。
  モデルIDも利用者が設定し、既定値をハードコードしない。Provider間の自動fallbackを行わない。
- `.env`で`AGENT_ROUTINE_REASONING_ENABLED=true`を明示設定したことを、Maintenanceに必要な
  限定データを選択Providerへ送るstanding approvalとして扱う。それ以外では外部送信しない。
- 有効でも次を送信しない: `.env*`、APIキー・password・token、SSH/Git認証情報、
  `knowledge/raw/**`、`knowledge/wiki/logs/**`、Git履歴・stash・reflog、`.agent-cache/**`全文、
  Project outputsのバイナリ、リポジトリ全件、診断と無関係な正本。
- 送信するのはvalidator診断と、それに直接関係するtrackedテキスト最小ファイルだけとし、
  上記のcontext budgetを超えない。
- モデル出力に含まれる任意shell commandを実行しない。候補は隔離snapshotで検証してから、
  `routines/maintenance/ROUTINE.md`の修復境界内だけでrealへ適用する。

## commitとbackup

- tracked変更がなく派生物しか変わらない実行ではcommitしない。空commitを作らない。
- 安全なtracked修正が必須検証に合格した場合だけ、意味的に1つのscoped commitを作る。
  利用者や別Writerの変更を混ぜない。
- schedule到達はbackup triggerではない。検証済みRoutine commitができた場合だけ、
  `tools/BACKUP.md`の既存event-driven triggerと`tools/TOOLS.md#タスク分類と終端処理`の
  task classに従ってbackupへ進む。
  backup-only Routineは作らない。
- Routineは公開スケルトンの`origin`へ自動pushしない。

## 結果語彙

stdoutの最終1行を機械可読な結果とし、人間向け詳細はstderrとGit管理外のrun logへ出す。

| 結果 | 意味 |
|---|---|
| `ROUTINE_NOOP` | 問題もtracked変更もない正常終了。API・commit・backupを行わない |
| `ROUTINE_OK` | 検証済みのtracked変更をcommitした（`commit=<sha>`） |
| `ROUTINE_SKIPPED` | 競合・lock・dirty treeなどで、何も変更せず安全に譲った |
| `ROUTINE_BLOCKED` | 安全境界（禁止path、上限超過、状態変化）で候補を破棄した |
| `ROUTINE_FAILED` | 検査・修復が失敗し、問題が残っている（`phase=`と`reason=`を付す） |

APIキー、Authorization header、Providerへの完全prompt、秘密を含みうるresponse全文を
logへ出さない。

## Routineが変更しない領域

Routineの自動変更は`routines/maintenance/ROUTINE.md`が定める修復境界内のtracked
UTF-8テキストだけである。ガバナンス正本（`AGENTS.md`、`PROJECT.md`、`STATE.md`、
`TOOLS.md`、`BACKUP.md`、本書ほか）、Tool・validator・evalのコード、`.env*`、`.git*`、
不変原資料、Project outputs、Independent repository、成果契約・使命・優先順位は
自動変更の対象外とし、必要なら`AGENTS.md#人間へ上げる例外`として停止・報告する。

## 将来のRoutine追加

- 新Routineは`routines/<id>/ROUTINE.md`を正本として追加し、`tools/run-routine.sh`の
  既知ID、validator、evalを同じ作業内で更新する。未知IDのままの実行経路を作らない。
- 追加してもRoutineはTriggerのままであり、`AGENTS.md`のRoute表を変更しない。
- Research系Routineを追加する場合も、本書の予算、送信境界、Single Writer、
  commit/backup条件を弱めない。
