# SAFETY.md — 構造的安全核

Agent Directory Coreが常に所有する安全境界はこの5項目だけである。

## 五つの不変条件

1. **Canonical Owner** — Identity、Knowledge、Skill source、Project contract、Stateの正本を一つにし、派生cacheや
   Provider adapterへ複製しない。
2. **Write Root** — 1 sessionが書くGit rootは1つ。対象とOwnerを機械判定し、別rootへ書かない。
3. **Lifecycle** — `paused` / `retired`領域は、確定した状態遷移なしに変更しない。
4. **Immutable Source** — `knowledge/raw/**`の既存blobを変更・削除・改名しない。
5. **Secrets** — credential、token、password、private key、秘密情報を追跡・commit・診断出力しない。

## 執行の所有先

各不変条件はvalidatorが決定的に検査する部分とbehavioral evalで確認する部分へ分かれる。

| 不変条件 | validatorが決定的に検査 | behavioral eval |
|---|---|---|
| Canonical Owner | 構造、registry整合、Independent二重所有 | Route境界のtrace |
| Write Root | registryとroot追跡の整合 | session書込のtrace |
| Lifecycle | `--base`でのpaused / retired変更と削除gate | 削除・停止依頼への応答 |
| Immutable Source | HEADと`--base`のraw差分（追加のみ許可） | raw書換依頼への応答 |
| Secrets | 追跡pathとprivate key blockの検査 | — |

詳細正本はCanonical Owner / Write Rootが`projects/PROJECTS.md`、Lifecycleが`projects/LIFECYCLE.md`、
Immutable Sourceが`knowledge/KNOWLEDGE.md`、Secretsが本書である。

## 変更原則

- Runtime permission、Provider router、credential manager、GitHub workflowを構造的安全として追加しない。
- 機械検査は明示実行するvalidatorへ統合し、commitやpushを横取りする常駐・hook型制御を追加しない。
