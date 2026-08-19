# REPOSITORIES — Independent Repository Registry

Independent repositoryのattachment、役割、復旧情報だけを持つ。
一般Projectの目的、成果契約、status、mode、現在状態は各Project自身の`PROJECT.md`と`STATE.md`が所有する。
Owner Agentが開発する公開基盤製品のactive状態はOwner Agent rootが一元管理し、製品repositoryへ複製しない。

Project rootはEmbeddedもIndependentも`projects/<name>/`であり、pathはnameから自明なので保持しない。
`projects/.gitignore`のmanaged blockはこの登録集合から導出する派生projectionであり、正本ではない。
昇格条件、session境界、remote操作、移行手順は[projects/PROJECTS.md](PROJECTS.md)が所有する。

### entry形式

```markdown
## `data-pipeline`

- repository_url: `git@github.com:owner/data-pipeline.git`
- repository_reason: `automation`
- revision: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- repository_role: `project`
```

- 見出しは``## `<name>` ``だけとし、`<name>`は`projects/<name>/`のディレクトリ名と一致させる。
- entryはname昇順。名前を重複させない。
- fieldは`repository_url`、`repository_reason`、`revision`を各1回持つ。`repository_role`は省略時
  `project`であり、公開基盤製品だけ`public-foundation`を明示する。他のfieldは追加しない。
- `repository_url`は認証情報、query、fragment、`file://`、絶対・相対のローカルpathを含まない。
  `git@host:owner/repository.git`、`ssh://git@host/owner/repository.git`、
  `https://host/owner/repository.git`の形だけを使う。
- `revision`はremoteへpush済みの40文字lowercase commit SHA。Independent sessionのhandoff後に
  root sessionだけが更新する。
- `repository_default_branch`とpathは持たない。description、status、mode、現在目標を複製しない。
- entryが0件でもこのファイルは存在してよい。

### 派生projection

`projects/.gitignore`のmanaged blockは、この登録集合からnameを`/<name>/`の形で昇順に写したものである。
registryを変更した同じroot commitで更新し、集合が完全一致しない状態を残さない。

```gitignore
# Derived from projects/REPOSITORIES.md.
# BEGIN INDEPENDENT PROJECTS
/data-pipeline/
# END INDEPENDENT PROJECTS
```

### 復旧境界

登録済みcloneがない場合は`bash tools/materialize-project-repositories.sh --project <name>`で採用revisionを
`projects/<name>/`へ再現する。既存cloneは同Toolの`--check`で検査し、次の不一致を自動修正しない。

- `origin`が`repository_url`と異なる
- HEADが登録済み`revision`と異なる
- dirty、staged、untracked、stashがある

不一致時は登録値と実測値を報告して止まり、remote貼替え、reset、checkout、pull、clone削除を行わない。
認証とremoteからの復旧は各Agent / Projectが所有する。

### repository_reason

独立repoが必要になる境界だけを理由にする。

- `automation` — Actions、Pages、Packages、Dependabot、Webhook、外部デプロイ
- `distribution` — OSS公開、tag、Release、packageやbinaryの配布
- `collaboration` — 外部共同編集、Pull Request、Issue運用
- `access` — 異なるvisibility、権限、Secrets、branch protection
- `identity` — 外部サービスや利用者が固定repo URLを参照
- `upstream` — fork、upstream追従、他システムからの依存
- `retention` — rootと異なる履歴保持・export・削除・監査方針、または実測されたGit履歴上の復旧問題

### repository_role

- `project` — 一般Project。採用revisionのrepository rootに`PROJECT.md`と`STATE.md`を持ち、従来の
  Project Route、検索、状態管理契約をそのまま使う。field省略時もこの値として扱う。
- `public-foundation` — Owner Agentが設計・開発・維持する公開基盤製品。製品repositoryは公開目的、仕様、
  repository-local規約、validator、test、fixture、配布文書だけを所有する。現在目標、優先順位、相互影響、
  次の一手、採用revision、handoff状態はOwner Agent rootの単一active正本が所有するため、製品repository rootの
  `PROJECT.md` / `STATE.md`を要求せず、Project検索候補へ入れない。作業Routeは`meta`とする。

`repository_role`は成果の重要度や公開・非公開だけで選ばない。Owner Agent自身が一般利用者向け基盤製品を
所有し、そのactive開発状態をrootへ集約する場合だけ`public-foundation`を使う。

### 登録

現在、Independent repositoryは登録されていない。
