# KNOWLEDGE.md — Knowledge運用の正本

Knowledge Routeを確定した後にこのファイルを最後まで読む。この規約は`knowledge/`全体へ適用する。

## 構造と正本性

通常判断で使う概念は二つだけである。

```text
raw  = 内容を変えない原資料
wiki = 根拠へ遡れる現在のKnowledge
```

`internal / external`と`sources / topics`は保存先を決める下位分類であり、Knowledge Routeの入口で
毎回再判断しない。INDEXは本文の代替ではなく、必要時だけ使う索引である。

```text
knowledge/
├── KNOWLEDGE.md
├── raw/
│   ├── internal/          # 内部で生まれた不変の原記録
│   └── external/          # 外部から取得した不変の原資料
└── wiki/
    ├── INDEX.md           # 分野・主要hubへの小型ルートマップ
    ├── _template/         # SOURCE.md / TOPIC.md の雛形
    ├── sources/           # 一つの原資料を解釈したKnowledge
    └── topics/            # 複数の根拠や判断を統合したKnowledge
```

`raw/internal`、`raw/external`、`sources`、`topics`はいずれも正本である。sources/topicsには要約、判断、推論が
含まれ、原資料から同一内容を再生成できない。Runtimeの検索index、snippet、製品側AIメモリは任意の派生cacheである。
`knowledge/`直下と`wiki/`配下に領域説明用の`README.md`を置かない。構造の意味はこのファイルが所有する。

## 保存先

1. 利用者や運用内部で生まれた原文、判断、決定、仮説、観測は`raw/internal/`へ新規保存する。
   形式は`KNOWLEDGE.md#内部原記録のRecord形式`に従う。
2. 論文、記事、契約、外部資料は取得元を記録し、内容を変えず`raw/external/`へ新規保存する。
3. 1資料を読み解いたKnowledgeは`sources/`、複数資料・内部経験を統合したKnowledgeは`topics/`へ置く。

```text
原資料が届く → raw/internal/ または raw/external/ へ保存
→ sources/ に資料別Knowledgeを作成 → 根拠が揃ったら topics/ へ統合
→ frontmatterへ状態を記録 → 必要ならINDEXの入口を更新
```

成果物はProject、手順はSkillが所有する。製品側の永続メモリは正本から派生する任意のキャッシュであり、
「メモリに覚えて」という依頼でも先にこの判定でリポジトリへ保存する。両者が矛盾したらリポジトリを優先する。
リポジトリ内に製品側メモリ専用の並列記録領域を置かない。秘密情報はどちらにも保存しない。

利用者は原文、判断、資料を提供し、知識の正しさを最終判断する。エージェントは分類、保存、ノート化、統合、
状態管理、必要なINDEXの更新を行う。

## 内部原記録のRecord形式

`raw/internal/`はProvider非依存の長期記憶の原記録層である。1つの独立した出来事・判断・発言・訂正を
原則1 recordとして保存する。時系列はrecordの`recorded_at`とファイル名が持ち、Wikiは時系列ログを持たず
現在有効なKnowledgeだけを保持する。

```yaml
---
recorded_at: 2026-08-20T13:01:00+09:00
kind: decision
subjects: [agent-directory, permissions]
---
```

- ファイル名は`raw/internal/`直下の`YYYY-MM-DD-<lowercase-kebab>.md`とし、日付は`recorded_at`の日付と
  一致させる。パスは恒久IDであり保存後にrenameしない。同日の衝突は保存前により具体的なslugで避ける。
- `recorded_at`はtimezone offset付きISO 8601とする。時刻が分からない情報だけ`YYYY-MM-DD`の日付のみとする。
- `kind`は次の7種だけを使う。`instruction`（運用指示）、`decision`（決定）、`preference`（好み・傾向）、
  `fact`（事実の陳述）、`observation`（観測・実行結果）、`hypothesis`（仮説）、`correction`（既存内部原記録の訂正）。
- `subjects`は検索を補助する自由語の一行配列で1件以上持つ。階層taxonomyや別台帳を作らない。
- `kind: correction`だけ`corrects`を必須とし、訂正対象の`knowledge/raw/internal/`配下recordへの
  リポジトリ相対パスを書く。訂正対象が内部原記録に存在しない場合はcorrectionではなく通常のkindで保存する。
- 上記以外のfrontmatter fieldを増やさない。
- 本文は元の意味・原文・決定内容をそのまま残す。AIの一般化、後付けの解釈、推論、要約、Wiki用の結論を
  原記録へ混ぜない。それらはWiki側が所有する。

この形式は内部原記録だけの契約である。`raw/external/`は取得した内容を変えないことを最優先とし、
この形式を強制しない。

## 不変規則

- `raw/internal/`と`raw/external/`の既存ファイルを編集、上書き、削除、改名しない。両者を同じ強さで保護する。
  訂正・追記は新規原資料とWiki側で行う。
- 外部資料へ要約、翻訳、推論を混ぜない。
- 移行や整理を理由に不変性を弱める恒久的な例外を作らない。一回限りの移行では移行前後のcontent hash一致を
  検査し、原資料のバイト列を変更しない。
- 秘密情報を保存しない。

## Researchのライフサイクル

Researchは独立したRouteでも独立したルートディレクトリでもない。SkillとProjectとKnowledgeの
ライフサイクルとして扱う。

```text
再利用可能な研究方法        → Skill
具体的な研究活動            → Project
研究中の仮説・調査・実験    → Project docs
研究の成果物                → Project outputs
他Projectでも使える確定結論 → Knowledgeへ昇格
```

Knowledge Routeが扱うのは、原資料の取り込み、記憶、照会、統合、Knowledgeの更新である。
「新しい問いへの答えを調査・実験によって見つける」依頼はProject Routeであり、研究方法そのものを
再利用可能な手順として作る依頼はSkill Routeである。Project内の研究文書を、昇格条件を満たさないまま
Root Knowledgeとして扱わない。昇格条件と昇格時の責務は`projects/PROJECTS.md#Project文書の任意拡張`が
所有する。

## 候補探索と読込

- target未指定の照会だけ、Runtime標準のファイル検索で`sources/`と`topics/`からactive候補を最大5件得る。
- 通常検索は`status: active`だけを対象にし、最初は上位3ページ、追加後も最大6ページまでとする。
  追加は不足する根拠を具体化できる場合だけ1件ずつ行う。
- 取り込みは既存候補を最大5件確認し、新規作成、既存更新、統合、supersedeのいずれかを選ぶ。
  重複確認のための全件読込をしない。
- `INDEX.md`やRuntime検索indexの全件読込を候補選択に使わない。
- `superseded`、`archived`、`retired`を通常判断に使わない。旧ページを明示された場合は
  `superseded_by`が示すactiveページを優先する。
- Git履歴は、監査、復旧、過去判断の確認、利用者の明示依頼を除き読まない。
- 検索結果だけで回答せず、採用したKnowledge正本を読む。24KiB超の部分読込と総読込予算は
  `AGENTS.md#Context Loading`に従う。

### 大きいKnowledgeの扱い

大きいことだけを理由に、原資料、Knowledge、研究証拠、Project成果物を圧縮、要約置換、削除しない。入口
ファイルのサイズ超過とは別問題として扱い、次の非破壊的手段で解く。入口側の処理は
`tools/TOOLS.md#サイズ予算`が所有する。

- 見出し単位の部分読込、frontmatter metadataによる候補選択、検索による限定取得
- `INDEX.md`とProject固有の入口文書からの段階的開示、不変原資料と解釈済みKnowledgeの分離
- 全件監査時のバッチ処理

24KiBを超えるactiveなWikiページは、見出しと参照先を索引する`## Retrieval Map`節を持ち、
全文読込なしで該当節へ到達できるようにする（上限64KiBは`tools/TOOLS.md#サイズ予算`）。

閾値と処理結果が決定的な保守は、AIまたはToolが確認を求めず自動実行する。統合先が一意で
情報損失がない統合とsupersedeも自律実行する。
どのページを現在有効な正本とするかが一意に決まらない場合と、内容が矛盾する場合は、
`AGENTS.md#人間へ上げる例外`として上げる。

### 原資料へ遡る条件

`raw/internal/`、`raw/external/`へ遡るのは次のいずれかがある場合だけとする。

- 原資料そのものの確認
- 正確な引用、数値、契約、仕様の確認
- Knowledge間の衝突、またはKnowledgeの根拠不足
- 訂正履歴・過去の時系列の確認
- ProjectまたはSkillからの明示参照

遡る場合もファイル名の日付とfrontmatter（`kind`、`subjects`）で候補を絞り、全件読込しない。

## 命名規則

固定ファイルは大文字名、利用者が作るKnowledgeページは小文字ケバブケースとする。

```text
テンプレート固定Wikiファイル = INDEX.md / _template/SOURCE.md / _template/TOPIC.md
利用者作成Knowledge          = sources/<lowercase-kebab>.md / topics/<lowercase-kebab>.md
内部原記録                   = raw/internal/YYYY-MM-DD-<lowercase-kebab>.md
```

大文字を許すのは上記の固定ファイルだけとし、`_template/`をコピーして作る実際のページへ広げない。
パスは恒久IDであり、状態変更や整理のために改名しない。

## Wiki frontmatter

sources/topicsの各ページは`_template/SOURCE.md`または`_template/TOPIC.md`をコピーし、少なくとも次を持つ。

```yaml
---
summary: 候補選択に使う一行説明
status: active
aliases: [別名, English alias]
---
```

- `summary`は200文字以内の一行とし、タブを含めない。
- `aliases`は一行の配列にし、タブ、改行、重複を含めない。
- statusは`active | superseded | archived | retired`だけを使う。
- `superseded`は存在するactiveページへの`superseded_by`（リポジトリ相対パス）を必須とする。
- `review_after`を使う場合は`YYYY-MM-DD`とする。日付到達は自動失効ではなく見直しの合図である。
- sourcesの`source`は`knowledge/raw/internal/`または`knowledge/raw/external/`配下の存在するファイルへの
  リポジトリ相対パスとする。

## 情報の区別

Wikiでは次を混ぜずに書く。

- **原資料の内容** — ファイルパスとページ・見出し・行などの位置を示す。
- **利用者の見解** — 利用者の判断と明示する。
- **AIの推論** — 推論と明示し、前提と根拠へリンクする。
- **運用ルール** — 適用範囲を示し命令形で書く。

出典のない事実主張を書かない。不確実性、反対証拠、適用範囲、有効期間を失わない。

この区別はWikiに限らず、`STATE.md`、Project文書、Skillへの保存にも適用する。確定情報として
扱えるのは、利用者が明示した判断と、Tool実行・検証の結果だけである。AIの推論・提案は、
利用者が採用を明示するまで帰属付きの推論・仮説として保存する。

## 作成・更新・統合

- sourcesは書誌、原資料リンク、要約、重要主張と位置、数値、資料の限界を持つ。
- topicsは複数sourcesまたは内部原記録を統合し、判断・推論を根拠へ遡れるようにする。
- 同じ意味のactiveページを増やさず、既存更新、統合、supersedeを優先する。

統合時は次を行う。

1. 統合先activeページへ固有情報、根拠、反対証拠、判断、適用範囲を移す。
2. 旧ページは削除せず`status: superseded`と`superseded_by`を設定する。
3. 参照切れと置換先のactive状態を検証する。
4. 表現だけの旧版や重複引用はGit履歴へ委ねてよいが、現在も意味のある情報をGit履歴だけへ退避しない。

## 訂正の伝播

利用者の訂正、反証、失効は、保存先1箇所の更新だけで終えない。

1. 原記録は上書きせず、訂正の内容を新しい`raw/internal/`（外部資料は`raw/external/`）へ追加する。
   内部原記録の訂正は`kind: correction`とし、`corrects`で訂正対象recordへ遡れるようにする。
2. その事実のOwner正本を特定し、`update / merge / supersede`で反映する。
3. 変更した正本のpathを参照する正本をpath検索で決定的に列挙し、直接依存だけを確認する。
   意味的に影響する依存だけを更新し、全Knowledgeを読み直さない。
4. peer正本同士で結論が割れたら自動統合せず、`AGENTS.md#人間へ上げる例外`として上げる。
5. 参照整合を検証する。Runtime側cacheは正本からの派生に限定する。

伝播を終えるまで訂正タスクを完了と報告しない。

## INDEX

`wiki/INDEX.md`は全件台帳ではなく、主要分野、hub、重要なactiveページへの人間向け入口である。

- 1項目1行、最大50項目、8KiB以内とする。
- `raw/`配下や全WikiをINDEXへ個別登録しない。全件探索はRuntime標準のファイル検索を使う。
- 項目追加・削除は入口としての価値が変わる場合だけ行う。

## archive・retire・削除

- `archived`は歴史照会だけ、`retired`は判断利用禁止とする。状態変更のために物理移動しない。
- 非activeページの削除は、参照ゼロ、代替または保持先確認、利用者の明示承認が揃った場合だけ行う。
- `raw/`配下は削除しない。

## lint

`bash tools/validate-agent-directory.sh --full`でmetadata、状態、参照、サイズ、内部原記録のRecord形式を
検査する。参照検査は現行正本側だけを対象とし、不変の`raw/`原記録には適用しない。原記録の訂正はWiki側で行う。
意味的な重複は自動削除しない。統合先が一意なら非破壊のsupersedeで統合し、一意でなければ候補として報告する。
