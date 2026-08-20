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

各不変条件は、validatorが決定的に検査する部分、behavioral evalで確認する部分、
Runtime / Operatorが所有する部分へ分かれる。validatorの検査が全体を保証すると扱わない。

| 不変条件 | validatorが決定的に検査 | behavioral eval | Runtime / Operator所有 |
|---|---|---|---|
| Canonical Owner | 構造、registry整合、Independent二重所有 | Route境界のtrace | Runtime cacheの規律 |
| Write Root | registryとroot追跡の整合 | session書込のtrace | commit実行、approval |
| Lifecycle | `--base`でのpaused / retired変更と削除gate | 削除・停止依頼への応答 | 状態遷移の意思決定 |
| Immutable Source | HEADと`--base`のraw差分（追加のみ許可） | raw書換依頼への応答 | 履歴書換、erasure実行 |
| Secrets | 追跡pathとprivate key blockの検査 | — | 内容レビュー、rotate |

詳細正本はCanonical Owner / Write Rootが`projects/PROJECTS.md`、Lifecycleが`projects/LIFECYCLE.md`、
Immutable Sourceが`knowledge/KNOWLEDGE.md`、Secretsが本書である。

## 変更原則

- Runtime permission、Provider router、credential manager、GitHub workflowを構造的安全として追加しない。
- 機械検査は明示実行するvalidatorへ統合し、commitやpushを横取りする常駐・hook型制御を追加しない。
