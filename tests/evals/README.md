# Behavioral tests

Agent Directory repository自体の開発QAであり、利用WorkspaceのCoreではない。静的validatorでは判定できない
Route、bounded context、原資料・Project・Independent ownershipの行動契約を、Runtimeまたは外部harnessが
生成した保存済みtraceから検証する。Provider、model、認証、permission、Git / GitHub操作、deploy、schedulerは
対象にしない。

`tests/evals/cases/*.yaml`はrequestと期待するread / write / run / reportを持つ。fixtureは
`tests/evals/fixtures/<name>/`に必要な最小入力だけを置き、通常Workspaceの正本を複製しない。caseは既存caseへ
統合できず、公開契約の回帰を検出する場合だけ追加する。全caseはdirectoryから自動検出し、別の一覧を持たない。

## Trace

traceはJSON Linesの1行1eventで、実際に観測した値だけを記録する。

- `trace` — case、source、coverage
- `route` — 選択Route
- `search` — command、status、returned
- `read` — path、bytes
- `run` — command、exit_code
- `delegate` — `skill`（Runtime標準のSubagentへ委譲したSkill名）、同時実行を観測した場合だけ`parallel_group`
- `write` — path、operation
- `state` — path、field、value
- `final_response` — 利用者向け報告
- `summary` — tool_calls、wall_time_ms

traceの先頭eventは`trace`でなければならない。`route` eventが複数ある場合は、すべてが期待Routeと
一致しない限り不合格とする。harnessまたは決定的Toolの観測を優先し、traceにない期待は`UNVERIFIED`とする。
`parallel_group`は同じ値のdelegate同士が実際に同時実行されたことをharnessが観測した場合だけ記録する。
Agentの説明から未観測eventを補完せず、secret、credential、個人情報を入れない。trace生成、adapter、model実行、隔離はRuntimeまたは外部harnessが
所有する。

## 実行

```bash
python3 tests/run-evals.py validate
python3 tests/run-evals.py score --case <case-name|path> --trace <trace.jsonl> [--json]
```

runnerはAIやRuntimeを起動せず、保存済みtraceを決定的に採点する。case、fixture、runner、schemaを変える場合は、
残るcaseがどの公開契約を検証するか確認し、schema validationとrunner自己検証を実行する。
