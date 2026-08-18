# EVALS.md — Core behavioral eval

Agent Directory固有の判断契約だけを検証する。Provider、Runtime、認証、backup、Issue / PR、publish、
deploy、scheduler、特定AI製品の設定は対象にしない。

## 範囲

Core suiteは次だけを扱う。

- Knowledge / Skill / Project / meta Route
- 明示targetとbounded context
- Knowledge原資料の不変性
- Project契約とpaused状態
- Single WriterとIndependent ownership
- destructive ambiguityとStanding Authorization
- Tool / Skill / 恒久物追加のOwner gate

新しいcaseは原則追加しない。既存caseへ統合できず、Agent Directoryの公開契約に直接関係する場合だけ、
Owner確認後に追加する。

## Case schema

`evals/cases/<name>.yaml`は次を持つ。

```yaml
name: case-name
fixture: optional-fixture
request: |
  利用者の依頼
expect:
  route: knowledge|skill|project|meta
  must_read: []
  must_not_read: []
  must_run: []
  must_not_run: []
  must_update: []
  may_write: []
  must_not_write: []
  must_report: []
  must_not_report: []
```

未使用fieldは省略できる。caseの期待は具体的なpath、command、report tokenで表し、抽象的な「適切に行動する」
だけを合格条件にしない。

## Fixture

fixtureは`evals/fixtures/<name>/`に置く。caseが必要とする最小入力だけを持ち、通常Workspaceの正本を
複製しない。runner用の自己検証fixtureは`evals/fixtures/eval-runtime/`が所有する。

## Trace

実行結果は[TRACE.md](TRACE.md)のJSONL eventで記録する。観測されていない期待をAgentの自己申告だけで
PASSにせず、`UNVERIFIED`として残す。

## 実行

```bash
python3 tools/run-evals.py score --case <case-name|path> --trace <trace.jsonl> [--json]
python3 tools/run-evals.py run --adapter <executable> --profile core [--output-dir <dir>]
```

`score`は保存済みtraceを採点する。`run`はcaseごとの隔離Workspaceでadapterを実行し、同じ採点器へ渡す。
生成物は`.agent-cache/evals/`へ置き、正本にしない。

## Core profile

`evals/profiles/core.txt`だけを標準profileとする。大量のvariant、Provider別profile、decay比較profileを作らない。

## 変更

case、fixture、runner、schemaの変更はbehavioral coverageを変えるprotected変更である。
削除・追加時は、残るcaseでどの公開契約を検証するかを明示し、full validatorとrunner自己検証を実行する。
