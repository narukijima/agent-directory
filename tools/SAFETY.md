# SAFETY.md — 安全核

通常作業で常に意識する安全境界はこの6項目だけである。実装詳細は必要時だけ
`tools/CONTROL.md`、`tools/BACKUP.md`、`projects/LIFECYCLE.md`を読む。

shell、filesystem、network、sandbox、tool approval、Providerのpermission modeはRuntime側が所有し、
本安全核は許可・拒否しない。本書が扱うのは操作の意味、対象、Repository整合性だけである。

## 六つの不変条件

1. **Write Root** — 1 sessionが書くGit rootは1つ。対象とOwnerを機械判定し、別rootへ書かない。
2. **Lifecycle** — `paused` / `retired`領域は明示的な状態遷移なしに変更しない。
3. **Secrets** — credential、token、password、秘密情報を追跡・commit・出力しない。
4. **Standing Authorization** — 公開、送信、本番、課金、権限変更、通常push、削除は、利用者の明示依頼
   または既存契約によるauthorizationと一意なtarget / destinationなしに実行しない。明示依頼があれば
   同じ操作の追加承認を求めない。
5. **Remote Integrity** — remoteの目的とSHAを確認し、divergence、宛先不明、非fast-forwardを自動解決しない。
6. **Control Integrity** — 本安全核、判定器、hook、validatorの弱体化や迂回を通常変更として扱わない。

## リスク別の経路

| 経路 | 対象 | 必須処理 |
|---|---|---|
| ordinary | 通常のProject、Knowledge、Skill、文書、コード | 対象検証、secret検査、差分確認 |
| protected | 上記6項目を実装・定義する正本とTool | full検証、明示ack、index-bound receipt（receiptはworkspace rootのみ） |
| external | push、公開、送信、本番、課金、権限、破壊操作 | Standing Authorization、一意なtarget / destination、実行後照合 |

`guarded`は「重要そうなファイル全部」ではなく、protected経路の実装だけへ限定する。
通常の失敗、文書改善、eval追加、非安全Toolの修正を境界違反にしない。

## 執行の所有先

| 不変条件 | 機械的なOwner | 詳細正本 |
|---|---|---|
| Write Root | `tools/lib/project-registry.sh`、validator | `projects/PROJECTS.md` |
| Lifecycle | validator、Project契約 | `projects/LIFECYCLE.md` |
| Secrets | `tools/check-boundary.sh`、validator | `tools/CONTROL.md` |
| Standing Authorization | 対象固有Toolとallowlist | `AGENTS.md`、`tools/UPSTREAM.md`、各Project契約 |
| Remote Integrity | backup / push Tool | `tools/BACKUP.md` |
| Control Integrity | `tools/control-policy.tsv`、managed hooks | `tools/CONTROL.md` |

通常タスクは`tools/task.sh`を入口にし、この表の実装詳細を再推論しない。境界で停止した場合だけ
対応する詳細正本を読み、拒否理由を解消して同じ操作を再実行する。

## 変更原則

- 安全核を変える変更は、利便性やvalidator通過だけを理由に弱めない。
- 新しいguarded対象は、上の不変条件のどれを機械的に執行するか説明できる場合だけ追加する。
- 防いだ実事故を説明できない規則は、まずordinaryまたはoptionalへ降格して観測する。
- 既存の安全性を削る場合は、同じ事故を別の機械境界が拒否するfixtureを先に用意する。
