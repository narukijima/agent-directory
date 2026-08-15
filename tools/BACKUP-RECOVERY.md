# BACKUP-RECOVERY.md — 条件付き復旧runbook

`tools/BACKUP.md`が停止したprivacy履歴、マシン移行、障害復旧、旧Project構造、大容量fileを実際に扱う
ときだけ読む。原則、remote分類、trigger、通常backup契約は`tools/BACKUP.md`が所有する。

## 未公開履歴のprivacy訂正

この復旧は通常のrebase・履歴書換え禁止に対する唯一の例外であり、次をすべて満たす。

1. backup remoteの現在SHA（未作成ならempty history）と全remote-tracking refを先に読み、訂正対象commitが
   どのremoteからも到達不能であることを証明する。1つでも公開済みなら書き換えず、漏洩対応として停止する。
2. 利用者が訂正する実値と置換後の値を一意に決める。Agentは個人識別子の意味や正しい公開identityを推測しない。
3. 元cloneを読み取り専用にし、権限を限定した隔離copyを唯一のWriterとして、remote baseより後の未公開suffix
   だけを訂正する。author / committerはGitHub noreply等の安全なidentityへ、blobは指定された非識別表現へ
   置換し、対象外のtree内容、commit順序、親子関係を保つ。
4. remote baseが訂正後HEADのancestorであること、元HEADとの差分が指定訂正だけであること、現在treeが期待値と
   一致することを検査する。`bash tools/check-boundary.sh --range <remote-base> HEAD`（remote未作成時は全履歴）、
   `bash tools/validate-agent-directory.sh --full`を通し、元cloneの不要化はpush成功後に別途判断する。
5. hook迂回、privacy allowlistによる事故値の許可、force push、remote ref削除を使わず、通常の
   `bash tools/backup-to-github.sh`だけでfast-forwardまたは初回pushする。

remote baseがancestorでない、訂正範囲・置換値が曖昧、secretの実値を安全に扱えない、別Writerが存在する場合は
自動訂正しない。履歴訂正は実値を含むため一般Toolへ自動化しない。

## マシン移行

1. 旧マシンで作業を確定し、`bash tools/backup-to-github.sh`が`WORKSPACE_BACKUP_OK`を出すまで実行する。
2. 旧マシンの書込を停止し読み取り専用として扱う。
3. 新マシンでPrivate backupから新しいディレクトリへcloneし、`git remote rename origin backup`で名を揃える。
4. `git rev-parse HEAD`と`git ls-remote --heads backup main`が一致することを確認する。
5. `bash tools/materialize-project-repositories.sh --all`で全Independent repositoryを揃える。
6. `bash tools/validate-agent-directory.sh`と`bash tools/build-context-cache.sh`で構造を検証し、cacheを再生成する。
7. secretを別経路から復旧し、新マシンを唯一のWriterへ昇格する。

Independent cloneは`projects/<name>/`自体へ置く。全件が揃うまではpartial materializationであり、昇格完了まで
新旧両方から書き込まない。

## 障害復旧

マシン移行と同じ手順を使うが、復旧点は最後に成功したbackup commitになる。以後の未commit変更、未追跡、
stashは復旧できないため失われた範囲を明示する。secretは別経路、cacheは正本から、Independent cloneは
registryの採用SHAからmaterializerで再構築する。

## 旧構造からの移行

1. rootとchildの全Writerを停止し、rootでcheckpoint commitを確定する。
2. childのdirty、staged、untracked、stash、全branch、全tag、未pushを監査する。
3. 旧repository fieldと`## Repository State`を除いたProject契約・状態をchildへ移し、検証、commit、通常pushする。
4. rootへregistryとignore projectionを追加し、root indexの旧Project契約・状態を削除して別commitにする。
5. clone全体を`projects/<name>/`へ移し、実`.git/`、契約、状態、origin、HEAD、全refを再確認する。
6. validatorとcacheを実行し、`WORKSPACE_BACKUP_OK`まで確認する。

dirty・未pushを置換せず、reset、clean、stash作成、force pushを使わない。旧copyは、新cloneのorigin・全ref・
cleanlinessが一致し、利用者が削除対象を明示した場合だけ削除する。マシン固有pathを正本へ保存しない。

## 大容量ファイル

通常Gitへ入れるのはテキスト、コード、設定、文書、軽量成果物とする。大量の動画、音声、model、dataset、生成物は
Projectが外部artifact保管先とchecksumを定義する。submodule、Git LFS、100MiB以上のGit objectは完全backupを
保証できないため、自動処理せず停止・報告する。
