# SAFETY.md — 構造的安全核

Agent Directory Coreが常に所有する安全境界はこの6項目だけである。shell、filesystem、network、sandbox、
tool approval、Provider選択、認証、remote操作はRuntime、Operator、対象Projectが所有し、本書は設定・診断しない。

## 六つの不変条件

1. **Canonical Owner** — Identity、Knowledge、Skill source、Project contract、Stateの正本を一つにし、派生cacheや
   Provider adapterへ複製しない。
2. **Write Root** — 1 sessionが書くGit rootは1つ。対象とOwnerを機械判定し、別rootへ書かない。
3. **Lifecycle** — `paused` / `retired`領域は、確定した状態遷移なしに変更しない。
4. **Immutable Source** — `knowledge/raw/**`と閉鎖済みlogの既存blobを変更・削除・改名しない。
5. **Secrets** — credential、token、password、private key、秘密情報を追跡・commit・診断出力しない。
6. **Control Integrity** — 本安全核、判定器、hook、validatorの弱体化や迂回を通常変更として扱わない。

## Git境界

| 経路 | 対象 | 必須処理 |
|---|---|---|
| ordinary | 通常のProject、Knowledge、Skill source、文書、コード | 対象検証、secret検査、差分確認 |
| protected | 上記6項目を定義・執行する正本とTool | full検証、明示ack、index-bound receipt |
| outbound | remoteへ送るcommit | secret、immutable source、protected contractの再検査 |

`guarded`は「重要そうなファイル全部」ではなく、構造的不変条件の定義・執行だけへ限定する。
pre-pushは送信を実行せず、送信予定commitの内容だけを検査する。ref policy、branch protection、PR、merge、
approvalはRepository、Runtime、Operatorが所有する。

## 執行の所有先

| 不変条件 | 機械的なOwner | 詳細正本 |
|---|---|---|
| Canonical Owner | validator | 各領域正本 |
| Write Root | `tools/lib/project-registry.sh`、validator | `projects/PROJECTS.md` |
| Lifecycle | validator、Project契約 | `projects/LIFECYCLE.md` |
| Immutable Source | `tools/check-boundary.sh` | `knowledge/KNOWLEDGE.md` |
| Secrets | `tools/check-boundary.sh`、validator | `tools/CONTROL.md` |
| Control Integrity | `tools/control-policy.tsv`、managed hooks | `tools/CONTROL.md` |

## 変更原則

- 安全核を変える変更は、利便性やvalidator通過だけを理由に弱めない。
- 新しいguarded対象は、上の不変条件のどれを機械的に執行するか説明できる場合だけ追加する。
- Runtime permission、Provider router、credential manager、GitHub workflowを構造的安全として追加しない。
- 既存の安全性を削る場合は、同じ事故を別の機械境界が拒否する検証を先に用意する。
