# TOOLS.md — 構造保守と限定取得

`tools/`は利用者の成果を作るSkillではなく、このAgent Workspace自体を保守するmeta層である。
固定Toolは`tools/TOOLS.md#Tool一覧`の登録だけとし、依存関係を増やさず、入出力、fallback、検証方法を
Tool個別契約の所有正本へ明記する。
macOS標準のbash 3.2を最低条件とし、GNU専用option、associative array、`mapfile`を
使わずBSD `find`と`sed`で動かす。`set -u`下の空配列は件数で守ってから展開する。変更時は
`/bin/bash tools/*.sh`とvalidator隔離fixture（実GitHub接続なしのbare remote）で検証し、
`shellcheck`があれば併用する（必須依存にしない）。

責務は次で固定する。Toolへ判断を持たせず、Agentへ決定的操作を再実装させない。

```text
Tool  = 決定的な操作を安全に実行する
Agent = いつ実行するかを規約に従って判断し、検証と記録まで完結する
Human = 例外と方針変更を決定する
```

## 通常入口

通常タスクでAgentが使う入口は`tools/task.sh`に一本化する。

```bash
tools/task.sh context --route <route> [--target <path>]
tools/task.sh verify
tools/task.sh finish --route <route> [--target <path>] --message "変更理由"
tools/task.sh finish --route <route> --target <path> --message "変更理由" --current-work
tools/task.sh status
```

Agentが渡すのはRouteとTargetであり、必要な読込、Git root、検証、終了処理は既存の決定的Toolが
解決する。read-only回答は入口Toolを必須とせず、明示対象を必要最小限だけ読む。

安全境界の要約は`tools/SAFETY.md`が所有する。通常作業では`tools/CONTROL.md`、`tools/BACKUP.md`、
本書の互換実装節を読まず、Toolが返した停止reasonに該当するときだけ読む。

## 正本と派生物

Markdown、原資料、Project入出力、eval、Toolコードが正本である。`.agent-cache/`はGit管理外の派生物で、
削除して正本から再生成できる。cacheだけに情報を保存せず、恒久参照先にもGit追跡対象にもしない。

## 相互参照

恒久参照は`<repository-relative-path>#<target>`を使い、行番号を使わない。targetは見出し、
frontmatter key、または`**<target>**`形式の定義項目（`PC-01`等）とする。見出しtargetは表示文字列の
完全一致に加え、inline backtickを除いた文字列、またはASCII英字の小文字化・空白の`-`化・inline
backtick除去によるslugを使える。同じProject内でも対象ファイル名を省略しない。instance文書
（`PROJECT.md`、`STATE.md`等）へのslashなし参照は、sourceファイルの兄弟をrepository rootより先に
解決する。validatorが参照の解決を静的検査する。

## 一時作業と固定化

- 一時コードと中間ファイルは`.tmp/`に置き、正式処理から参照せず、完了時に削除する。
- 2回目に使う不安定なコードは所有先の`candidates/`へ、3回目の前に固定化を判断する。
- 固定コードはProjectまたはSkillの`scripts/`、構造保守はこの`tools/`が所有し、実行・検証方法を持つ。
- 外部共有、本番、金銭、権限、機密へ影響する処理は初回から固定コード相当の品質を要求する。
- 全件監査でも同時入力せず、バッチで検査して`.tmp/`の集約結果と必要な正本だけを次段階へ渡す。

## 自律実行の標準完了

work/stateの終端は`tools/task.sh finish`（実体は`finalize-task.sh`）の1回で検証・commit・backupまで完結させ、
可否を質問しない。設定済みworkspace `backup`への処理はこのfinish内のStanding Authorization済みstepであり、
宛先・送信対象・credential利用を再確認しない。次をすべて満たすとき自動commitする。

- 依頼範囲内の変更であり、変更対象のOwnerが明確である。
- 必須検証が合格している（未検証・不合格を完了commitとして扱わない）。
- 秘密情報を含まず、unrelated changeを混ぜていない。
- 作業ツリーから自分の変更を安全に分離できる（書込Git rootはsession毎に1つ）。
- commitが意味的に一つの作業単位である。

hooks導入済み環境では、commit・push境界を`tools/check-boundary.sh`が機械検査する（正本は
`tools/CONTROL.md`。安全核としてguarded / contractの変更だけが明示エスカレーションと`--full`検証を要する）。
このackはRepository integrityの記録であり、Runtime Permissionでも利用者への追加承認要求でもない。

利用者が「今ある作業をバックアップして」と明示しtargetが一意な場合も、新しいbackup経路へ分岐せず
同じwork終端を使う。`task.sh context`でGit rootとOwnerを解決し、変更一覧、Project契約、Single Writer、
secret、target外差分を確認してProject固有検証を通す。今回対象だけをstageした後、
`task.sh finish ... --current-work`を呼ぶ。`--current-work`はtarget外差分と未stageの対象差分をfail closedで
再検査し、検証・commit後にprofileどおりbackupする。dirtyを見ただけでraw `backup-to-github.sh`を先に
呼ばず、同じ操作の追加承認も求めない。所有者不明、別Writer、secret、target外差分、同じ成果物で
分離不能な競合はstageせず停止する。

commit messageは変更内容と理由が分かる一文を先頭に置く。中断時は残件を明記した
checkpoint commitを作ってよいが、完了報告にも成果契約の達成にもしない。commit後は`tools/BACKUP.md`の
triggerとpolicyが許す場合だけbackupまたは通常pushへ進む。通常pushがPR必須ruleだけで拒否された場合は、
`projects/PROJECTS.md#Remote操作の境界`の限定経路でremote default branch反映とmerge済みsource branchの
remote / local削除まで完了する。このPR経路は開発remote専用で、workspace `backup`へ適用しない。

次のいずれかでは自動commitせず停止し、`AGENTS.md#人間へ上げる例外`として報告する。

- 秘密情報を含む、または所有者不明の変更と安全に分離できない。
- 同じ行や成果物で別sessionと競合している。
- 不可逆操作のtargetが一意でない、または成果契約に必要な利用者の決定が依頼に含まれない。
- 何を正本とするか決定できない。

## 自己修復と停止

安全で可逆な内部エラーは利用者へ判断を返さず、原因を調査して自律修正し再検証する。対象は
サイズ超過、参照切れ、lint/format失敗、stale cache、validatorが示した構造違反、再生成漏れ、
Toolへの決定的な入力不備、自分の変更が壊したtestである。

失敗原因は観測が直接示す範囲だけ確定し、timeout、接続断、一つの経路の失敗から能力・権限全体の欠如を
推論しない。利用者の訂正または新しい検証結果と矛盾した旧推論は失効させる。再試行前に状態、入力、手段、
接続のいずれかを再観測し、前回からの意味ある差分を一つ以上作る。差分のない同一試行は繰り返さない。

検証は終端の1回に集約する。変更の途中でvalidatorを反復実行せず、編集直後の確認は対象の最小検査
（構文、lint、対象test）に限る。finalize検証の失敗後の再finalizeは1回まで。2回目の失敗は停止し、
事実・試行・推奨判断を報告する。その他の内部エラーへの修正再試行は3回まで。次のいずれかは
試行回数によらず停止する。

- 修正方法が成果契約、目的、優先順位を変える。
- 解決策が複数あり、選択で成果や安全性が変わる。
- 不可逆操作または外部状態の変更が必要だが、Standing Authorizationまたは一意なtarget / destinationがない。
- 所有者不明の変更へ触れる必要がある。
- 二つの正本が矛盾し、正本が一意に決まらない。

正本同士が矛盾した場合は片方を推測で書き換えない。両方のpath、矛盾する記述、`AGENTS.md#参照順序`上の
上位、影響範囲を示し、推奨する一つの解決を添えて停止する。

### タスク分類と終端処理

以下は互換実装の内部契約であり、通常のAgent判断へ露出させない。

| class | 対象 | 終端処理 |
|---|---|---|
| read | 照会、監査、説明 | 検証・STATE・commit・backup・manifest生成なし |
| work | 成果物・コード・文書の変更 | `finalize-task.sh` 1回（`--changed`検証、commit、`--root-only` backup） |
| state | 目標・到達点・検証結果の変化 | STATE更新後に同じfinalize 1回 |
| boundary | 契約、attachment、registry、移行、復旧 | full検証、必要な承認、workspace backup（手動経路） |

明示された現在作業のbackupは`work`であり、`--current-work`を付けた同じfinish経路を使う。
Private backup設定済みのroot所有workは`--root-only`、未設定は`not-configured`、Independentは
`push-policy`である。workspace scopeはboundary監査だけに使う。

この表は`task.sh`配下の互換実装用であり、通常のAgent判断へ露出させない。直接呼び出す既存consumerの
ために`prepare-context.sh --class`と`finalize-task.sh --class`は維持する。現在目標、到達点、検証結果、
ブロッカー、次の一手が変わらなければ`STATE.md`は不変とし、実行した事実や日付だけで更新しない。

## Tool一覧

固定Toolの登録は本表が正本である。呼び出し形・入出力・生成物・停止reasonなどTool個別の契約は
「詳細正本」列の所有先だけが持ち、扱うToolの節だけを条件付きロードで読む。下流Workspaceの
固有Toolも本表へ1行で登録し、詳細は`tools/REFERENCE.md`へ節を追加する（本書へ詳細を書き戻さない）。

### Core

通常タスクと6つの安全不変条件を支える。Agentが通常直接使うのは`task.sh`と`find-context.sh`だけである。

| Tool | 責務 | 詳細正本 |
|---|---|---|
| `task.sh` | context、変更検証、終端処理の薄い共通入口 | `tools/REFERENCE.md` |
| `build-context-cache.sh` | catalog・manifest・検索索引の再生成 | `tools/REFERENCE.md` |
| `find-context.sh` | Route確定後の候補検索（metadata最大5件） | `tools/REFERENCE.md` |
| `setup-local-environment.sh` | Codex / Claude Code共通のローカル初期化 | `tools/REFERENCE.md` |
| `check-runtime-readiness.sh` | Workspace rootとCodex / Claudeのread-only preflight | `SETUP.md` / `tools/REFERENCE.md` |
| `validate-agent-directory.sh` | 構造・境界・サイズの機械検査 | `tools/REFERENCE.md` |
| `check-boundary.sh` / `install-git-hooks.sh` | commit・push境界検査とhook導入 | `tools/CONTROL.md` |

### Compatibility

既存consumerと`task.sh`の内部実装が使う。新しい通常経路を増やさない。

| Tool | 責務 | 詳細正本 |
|---|---|---|
| `prepare-context.sh` | Context Packetとclass→profile写像 | `tools/REFERENCE.md` |
| `finalize-task.sh` | work/state専用の決定的終端（検証・commit・backup） | `tools/REFERENCE.md` |
| `append-knowledge-log.sh` | LOG追記とローテーション | `tools/REFERENCE.md` |

### Optional

該当機能を明示利用するときだけ読む。存在することを全タスクの必須知識にしない。

| Capability | Tool | 詳細正本 |
|---|---|---|
| behavioral eval | `run-evals.py` | `evals/EVALS.md` |
| backup | `backup-to-github.sh` | `tools/BACKUP.md` |
| upstream report | `report-upstream-issue.sh` | `tools/UPSTREAM.md` |
| GitHub auth | `lib/github-auth.sh`、`setup-github-auth.sh`、`test-github-auth.sh` | `tools/REFERENCE.md` |
| Independent repository | `materialize-project-repositories.sh` | `tools/REFERENCE.md` |

## サイズ予算

モデル非依存で安定するUTF-8 byteをhard limitに使い、行数と見出し数は可読性警告だけに使う。
実行時の読込予算は`AGENTS.md`が所有する。90%到達のwarningは質問事項ではなく、
次節の標準処理を自律実行する合図である。

ルート`AGENTS.md`の8KiB hard limitはfile全体へ適用する。6KiB warningはrouter肥大化を減らす指標であり、
導入先固有のidentityを持つH2 `## 自己定義`節（次のH2またはEOFまで）を除いたbyte数へ適用する。
自己定義もfile全体hard limitの内側にあり、無制限ではない。

| 対象 | hard limit |
|---|---:|
| `AGENTS.md`（ルート） | 8KiB。6KiB超はwarning |
| `projects/AGENTS.md` | 2KiB |
| `projects/<name>/AGENTS.md` | 2KiB |
| `knowledge/KNOWLEDGE.md`・`tools/*.md`・`PROJECT.md` / `SKILL.md` | 20KiB |
| `projects/PROJECTS.md`・`evals/EVALS.md`・`ARCHITECTURE.md`・`docs/<DOMAIN>.md` | 24KiB |
| `skills/SKILLS.md` | 12KiB |
| `STATE.md` | 8KiB |
| `knowledge/wiki/INDEX.md` | 8KiB・50項目 |
| active Wiki | 64KiB。24KiB超はRetrieval Map必須 |
| `knowledge/wiki/LOG.md` | 128KiB・1,000記録 |

### 超過時の標準処理

入口正本が上限またはその90%へ達したら、利用者への質問も残課題報告もせず次の順で処理し、
**上限の80%以下**まで代謝して完了とする。90%直下で止めると次の追記で警告が再発し境界へ
張り付くため、発火点より深く下げる。

1. 同じ意味の重複記述を除去する。
2. 詳細を既存の正しい所有先へ移す。
3. 条件付きロードへ変更する。
4. 残る詳細を責務単位で詳細文書へ分割する。
5. 元の正本には現在有効な原則、境界、Route、参照だけを残す。
6. 移動前後で意味・禁止事項・例外・参照の欠落がないことを確認し、validatorを実行してcommitし報告する。

「圧縮」は曖昧な要約置換ではなく、意味を保持した重複除去、責務移管、段階的開示である。上限拡大は、
既存の責務分離で収容できず、そのファイル自身が所有すべき明確な根拠がある構造変更としてだけ検討し、
validatorを通すためだけの拡大とwarning閾値の変更は禁止する。原資料、Knowledge、研究証拠、
Project成果物は大きさを理由に圧縮・要約置換・削除しない（正本は
`knowledge/KNOWLEDGE.md#大きいKnowledgeの扱い`）。
