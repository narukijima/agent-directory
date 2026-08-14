# LIFECYCLE.md — Projectの状態遷移と削除

Projectの状態遷移、完了、停止、廃止、削除を扱うときだけ読む。通常のactive Project作業では読まない。

## 状態

- `active` — 進行中。通常検索の対象。
- `paused` — 停止中。明示的な再開・監査以外では変更しない。
- `completed` — finiteの全完了条件を検証済み。追加作業を行わない。
- `retired` — 利用者が廃止を決定済み。通常検索から除外する。

continuousに`completed`は使わない。completed Projectの拡張は、新しいProjectまたは利用者が明示した次フェーズとして扱い、
AIが自動でactiveへ戻さない。

## 状態遷移

- finiteをcompletedにする前に、すべての`PROJECT.md#PC-xx`の検証証拠を確認する。
- completed時は`STATE.md`の現在目標と次の一手を「なし（Project完了）」にし、対象契約を
  `PROJECT.md#status`へ変更し、検証結果を現在の完了証拠へ更新する（`#status`は状態遷移作業を
  対象とする契約参照で、validatorが完了Projectに要求する形）。
- continuousの現在目標は、合格条件が検証済みで、次目標が正本から一意に決まる場合だけAIが更新できる。
- 次目標に新しい戦略、優先順位、予算、品質上のトレードオフが必要なら利用者へ確認する。
- paused、retiredへの変更と再開は利用者の明示指示を必要とする。

## 人間が決める遷移

次の遷移は利用者の意思決定を必要とする。依頼にその決定が明示されていれば、それをStanding Authorization
として実行し、同じ遷移を再確認しない。決定内容が不足する場合だけ不足点を確認する。

- mission、vision、目的、最終ゴール、継続的使命の変更。
- `PROJECT.md`の成果契約、`PC-xx`、成功指標、完了条件、固定制約、判断原則、非ゴールの変更。
- 新しい戦略、優先順位、予算、期限、品質と速度のような重要なトレードオフの決定。
- Projectの新設、`paused`と`retired`への変更、再開、廃止、統合、Independent化、削除、物理移動。

次は確認を求めず実行し、事後に報告する。

- 合格条件が検証済みで、次目標が正本から一意に決まるcontinuousの現在目標更新。
- 全`PC-xx`の検証証拠が揃ったfiniteの`completed`化と、`STATE.md`の完了状態への更新。
- 状態変化の同じ作業内での`STATE.md`反映と、`tools/TOOLS.md#自律実行の標準完了`に従うcommit。

## 物理位置

検索除外のためにProjectを`_archive/`へ移動しない。completed、paused、retiredも元のパスに残し、状態で絞る。
別パスへの移行が必要な場合は、すべての参照先、移行表、復旧方法を用意し、利用者の明示指示に基づいて行う。

## statusとIndependent repository

statusは検索候補と書込可否を決める属性であり、cloneの物理的な有無を決めない。

- `active`、`paused`、`completed`、`retired`のすべてで、Independent cloneを
  `projects/<name>/`へmaterialize済みのまま保持する。
- `paused`、`completed`、`retired`は、cloneが存在していても既存のread-only規約を維持する。
  再開、監査、保守の明示がない限り書き込まない。
- 検索から外す目的でcloneを削除、移動、archiveしない。削除はProject削除ゲートを通った場合だけ行う。
- archive pathを作らない。cloneの退避先や世代ディレクトリも作らない。

cloneが欠けている状態はstatusの表現ではなく、復旧途中のdegraded stateである。
`bash tools/materialize-project-repositories.sh --all`で`projects/<name>/`へ戻す。

## 削除

Project削除は次をすべて満たす場合だけ行う。

1. `status: retired`である。
2. 利用者が一意なProject削除を明示指示しており、そのStanding Authorizationを
   `PROJECT.md`の`deletion_approved: true`として記録して一度コミットしている。記録のために再承認を求めない。
3. リポジトリ内からの参照がゼロである。
4. 保持すべき成果物と監査証拠の保存先を`artifacts_retained_at: <repository-relative-path>`として記録している。
   保持対象がなく、`outputs/`にも追跡ファイルがない場合だけ`artifacts_retained_at: none`を使う。
5. 削除対象をread-only検査で確定し、Gitで復元可能である。

Independent Projectでは、この削除ゲートを通るまでcloneを先に削除しない。ゲートを通った後は、
`projects/REPOSITORIES.md`のentry、`projects/.gitignore`のmanaged entry、Project cloneを一体として
削除する。削除前に採用revisionと全local refがremoteから復旧可能であることを確認する。

削除は、上記metadataを持つretired状態をbase commitに残した次の変更で行う。validatorは`--base`で
base側の状態、承認、成果物保持先、現在の参照ゼロ、ディレクトリ全削除を検査する。

pausedやcompletedを「古い」「動きがない」という理由だけで削除しない。
