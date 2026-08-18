# CONTROL.md — Git境界

commit・push境界の機械検査、protected変更のreceipt、違反時の処理を扱うときだけ読む。
通常のKnowledge・Skill・Project作業では、導入済みhookの検査を受けるだけでよい。

## 目的と非ゴール

目的は、`AGENTS.md`と各正本が定める境界のうち機械判定できるものを、実行前に拒否することである。
判定は特定のAI、Provider、Runtime、外部サービスに依存しない。

本層は次を実装しない。

- Runtime permission、sandbox、network、Provider、認証の設定・診断
- commit、push、backup、公開、Issue / PR、deployの実行
- 常駐daemon、ACL database、Tool broker、外部監査LLM
- validatorの代替

## 三層

```text
Policy    tools/control-policy.tsv
Verifier  tools/check-boundary.sh
Adapter   tools/hooks/pre-commit / pre-push
```

```bash
tools/check-boundary.sh [--staged | --base <ref> | --range <old> <new>]
bash tools/install-git-hooks.sh --install|--status|--remove
```

verifierは次を検査する。

- tracked secret、credential、private key、authorization / cookie、秘密値代入
- 個人home pathと未許可の直接メール
- frozen領域の変更・削除・改名
- guarded / contract変更のack
- staged差分のmixed-scope
- push対象のref削除とnon-fast-forward

値そのものは診断へ出力しない。networkへ接続しない。

## 承認済みsnapshot

hookはworking treeのverifier・policyを実行しない。`.git/agent-control/`に置いた承認済みsnapshotを使う。
workspace rootではHEAD blobだけから更新し、未commitのpolicy変更で判定を差し替えられないようにする。

materialize済みIndependent Projectには同じsnapshotをpath prefix付きで配る。control正本を更新したら、
workspace rootでinstallerを再実行する。

## Policy

`tools/control-policy.tsv`はtab区切りの`tier pattern note`で、上から先勝ちとする。

| tier | 意味 |
|---|---|
| `exempt` | 後続規則を適用しない明示例外 |
| `forbidden` | 追跡・stagingを常に拒否 |
| `frozen` | 新規追加だけを許し、既存blobの変更・削除・改名を拒否 |
| `guarded` | 安全核と構造を執行する正本・Tool |
| `contract` | Humanが決定するProject成果契約 |

`guarded`は[SAFETY.md](SAFETY.md)の不変条件を直接定義・執行する最小集合だけにする。
説明文書や「重要そうなもの」を一律にguardedへ入れない。Tool allowlistの新設・拡張は、
[TOOLS.md](TOOLS.md#追加禁止)のOwner確認を先に満たす。

## Protected commit

`guarded`変更は`AGENT_GUARDED_COMMIT=true`、`contract`変更は
`AGENT_CONTRACT_COMMIT=true`を、その1回のcommitだけへ付与する。現在の明示依頼が該当変更を含む場合、
追加確認は不要である。

workspace rootではackに加えて、stage済みindex treeへ束縛したfull-validation receiptを要求する。

```text
stage protected paths only
→ bash tools/validate-agent-directory.sh --full
→ AGENT_GUARDED_COMMIT=true git commit ...
```

receipt後にindexを変更すると無効になる。protectedとordinaryを同じcommitへ混ぜない。
Independent Projectはroot validatorを持たないため、external snapshotのackだけを使う。

## Push境界

pre-pushはref削除とnon-fast-forwardを拒否し、送信予定blobをapproved policyで再検査する。
新規remote refでは、同じremoteのtracking refからlocal SHAの最も近いancestorを選ぶ。
ancestorを証明できなければempty treeから全履歴を検査する。

remote側のPR必須、FF-only、branch protection、merge policyは対象Repositoryが所有する。

## 違反と回復

| 事象 | 処理 |
|---|---|
| validator失敗 | 原因を直し、同じ検証を再実行 |
| forbidden / frozen | 違反差分を除去 |
| ack不足 | task classと明示依頼を確認して正しいackを1回だけ付与 |
| mixed-scope | protectedとordinaryを別commitへ分割 |
| receipt不足 | stageを固定してfull validatorを再実行 |
| verifier / hook迂回 | 制御系違反として停止 |

hookが通常の誤操作を実害前に拒否しただけなら、正しい手順でやり直す。正本やvalidatorの欠陥が原因なら、
既存validatorへ最小の再発防止検査を統合する。新しいevalやfixture fileを自動追加しない。

## 委譲

通常は単一主体で完結する。独立した読み取り調査など、分割利益が明確な場合だけ委譲する。
同一Git rootのWriterは常に1つ、委譲の深さは1段、final ownerも1つとする。

## 将来拡張

Runtime permission、Provider router、credential manager、backup、外部送信ToolはCoreへ戻さない。
新しいsemantic safety機構が必要になった場合も、Ownerの明示決定後に既存Policy / Verifierへ統合する。
