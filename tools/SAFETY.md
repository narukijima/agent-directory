# SAFETY.md — 構造的安全核

Agent Directory Coreが常に所有する安全境界はこの5項目だけである。shell、filesystem、network、sandbox、
tool approval、Provider選択、認証、remote操作はRuntime、Operator、対象Projectが所有し、本書は設定・診断しない。

## 五つの不変条件

1. **Canonical Owner** — Identity、Knowledge、Skill source、Project contract、Stateの正本を一つにし、派生cacheや
   Provider adapterへ複製しない。
2. **Write Root** — 1 sessionが書くGit rootは1つ。対象とOwnerを機械判定し、別rootへ書かない。
3. **Lifecycle** — `paused` / `retired`領域は、確定した状態遷移なしに変更しない。
4. **Immutable Source** — `knowledge/raw/**`の既存blobを変更・削除・改名しない。
5. **Secrets** — credential、token、password、private key、秘密情報を追跡・commit・診断出力しない。

Git、commit、push、branch、PR、merge、approvalはRepository、Runtime、Operatorの標準機能が所有する。
Coreは独自hook、ack、receipt、permission layerを追加しない。

## 執行の所有先

| 不変条件 | 機械的なOwner | 詳細正本 |
|---|---|---|
| Canonical Owner | validator | 各領域正本 |
| Write Root | `tools/lib/project-registry.sh`、validator | `projects/PROJECTS.md` |
| Lifecycle | validator、Project契約 | `projects/LIFECYCLE.md` |
| Immutable Source | Knowledge契約とGit差分確認 | `knowledge/KNOWLEDGE.md` |
| Secrets | `.gitignore`、validator | 本書 |

## 変更原則

- Runtime permission、Provider router、credential manager、GitHub workflowを構造的安全として追加しない。
- 機械検査は明示実行するvalidatorへ統合し、commitやpushを横取りする常駐・hook型制御を追加しない。
