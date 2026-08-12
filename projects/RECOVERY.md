# RECOVERY.md — Projectの復旧手順

利用者から間違い、重複、目的不一致、過去決定の見落としを指摘された場合、または
Independent repositoryの接続不一致（missing clone、origin mismatch、head not adopted等）を
検出した場合だけ読む。

1. 対象の`PROJECT.md`、`STATE.md`、指摘された成果物を再読する。
2. 期待、現在結果、食い違い、原因を具体的に特定する。
3. 既存成果物を不要に破壊せず、食い違いを解消する最小範囲を修正する。
4. `PROJECT.md`の検証方法と現在目標の合格条件を再実行する。
5. 原因、無効になった方針、再発防止、次の一手を`STATE.md`へ反映する。
6. 失敗・却下済みの方法は、新しい根拠または利用者の明示指示なしに繰り返さない。

問題が成果契約そのものにある場合でも、利用者の明示なしに契約を変更しない。変更提案と復旧実装を分ける。

## Independent repositoryの復旧

Project rootは`projects/<name>/`である。次の不一致は成果ではなく接続の問題として扱う。

- **missing clone** — registryに登録があるがcloneがない。`bash tools/materialize-project-repositories.sh
  --project <name>`で`projects/<name>/`へcloneし、採用revisionをdetached checkoutする。
- **partial materialization** — 一部のIndependent Projectだけが揃っている。復旧途中のdegraded stateであり、
  workspace backupの成功として扱わない。全件が揃うまで報告に部分状態と残件を明記する。
- **origin mismatch** — `remote.origin.url`が`projects/REPOSITORIES.md`の`repository_url`と一致しない。
  既存cloneを勝手に貼り替えず、両方のURLと`git -C projects/<name> log --oneline -1`の結果を報告して止まる。
- **head not adopted** — HEADがregistryの`revision`と違う。正常扱いせず、reset、checkout、pullで
  合わせにいかず、両方のSHAを報告して止まる。
- **adopted revisionの復旧** — branchの現在tipではなく、まずregistryの採用SHAを再現する。
  tipへ進めるかどうかは別のProject作業として利用者が決める。

復旧中に既存のsource cloneを勝手に削除しない。dirty、staged、untracked、stashが残るcloneは、
clone仕直しではなくdirectory全体の移動で保全する。マシン単位の復旧、移行、backup scopeは
[tools/BACKUP.md](../tools/BACKUP.md)が所有する。
