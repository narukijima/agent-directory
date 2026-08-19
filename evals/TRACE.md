# TRACE.md — Behavioral trace

behavioral evalの観測記録はJSON Linesで、1行1eventとする。

## Event

必須event:

- `trace` — case、source、coverage
- `route` — 選択Route
- `search` — command、status、returned
- `read` — path、bytes
- `run` — command、exit_code
- `write` — path、operation
- `final_response` — 利用者向け報告
- `summary` — tool_calls、wall_time_ms

caseが要求しないeventは省略できる。pathとcommandは実際に観測した値だけを記録する。

## 信頼

- harnessまたは決定的Toolの観測を優先する。
- Agentの説明だけで未観測のread、write、runを補完しない。
- traceに無い期待は`UNVERIFIED`とする。
- secret、credential、個人情報をtraceへ入れない。

traceの生成、adapter、model実行、隔離方法はRuntimeまたは外部eval harnessが所有する。
