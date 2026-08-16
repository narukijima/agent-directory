# TRACE.md — Context trace語彙とadapter契約

行動evalのtrace JSONL語彙、信頼規則、event fieldとexpectの機械対応、adapter呼び出し契約の正本。
ケース期待の正本は`evals/EVALS.md#ケースschema`、採点実装は`tools/run-evals.py`が持つ。

## 完全なevent語彙

```json
{"event":"trace","source":"client","case":"route-to-knowledge","coverage":["route","search","read","run","write","state","reference","fallback","escalation","final_response","metrics"]}
{"event":"phase","name":"resolve","duration_ms":42}
{"event":"route","route":"knowledge"}
{"event":"search","command":"tools/find-context.sh","status":"active","selected_statuses":["active"],"returned":5,"duration_ms":120}
{"event":"cache","mode":"stat-fast|full-check|rebuild"}
{"event":"read","path":"knowledge/wiki/topics/example.md","bytes":4200}
{"event":"run","command":"...","exit_code":0,"duration_ms":800}
{"event":"write","path":"knowledge/wiki/topics/example.md","operation":"update"}
{"event":"state","reference":"projects/example/STATE.md#現在の目標","value":"...","preserved":true}
{"event":"reference","target":"knowledge/wiki/topics/old-page.md"}
{"event":"fallback","mode":"grep"}
{"event":"escalation","reason":"contract-change"}
{"event":"final_response","text":"..."}
{"event":"summary","tool_calls":6,"wall_time_ms":21000}
```

## sourceとcoverageの信頼規則

`source`は`client`、`harness`、`agent`のいずれかとし、先頭`trace` eventの値を後続eventが継承する。
`client`はクライアントのTool履歴、`harness`はsandbox・filesystem observer等の外部観測、`agent`は
Agent自身の申告を表す。`coverage`は、そのsourceが当該event種別を漏れなく観測した場合だけ列挙する。
肯定期待は信頼できる一致eventで検証できるが、不在から負条件をPASSにできるのは対応するcoverageが
ある場合だけである。source欠落・未知source・`agent`だけのeventはPASS根拠にせず`UNVERIFIED`とする。

自己申告だけで合格させず、クライアントのTool履歴、sandbox記録、またはadapterのアクセス記録を使う。
クライアントが実トレースを提供しない場合は、その項目を未検証として扱う。

## event fieldとexpectの対応

scorerが機械照合する語彙:

- `search.command`と`search.status`が`must_search` / `must_not_search`、`search.selected_statuses`の
  先頭が`must_prefer`、`search.returned`が`max_candidates`の根拠。
- `state.reference`（`=値`付きなら`state.value`も）が`must_set`、`state.preserved: true`が
  `must_preserve`の根拠。
- `reference.target`が`must_not_reference`、`fallback.mode`が`fallback`許可リスト、
  `escalation` eventの件数が`max_escalations`判定と決定metrics `human_intervention_count`の根拠。
- `final_response.text`を`report_match`へ照合し、`must_report`は全pattern一致でPASS、
  `must_not_report`は全pattern一致でFAILとする。
- 肯定の`must_run`は`exit_code`が0の一致eventだけを合格根拠とする。実行の試みだけでは満たさない。
- 負条件のcoverage名は対応するevent名（`read`、`run`、`write`、`state`、`reference`、`fallback`、
  `search`、`final_response`）を使う。

## 検査対象

- 検索候補数、読込ファイル数、正本byte合計
- 読んだpathと順序、status優先
- 実行commandと終了コード
- 書込・更新・保持・禁止path
- 予算停止時の未読範囲と不確実性の報告
- 最終報告文（`final_response`）への`report_match`照合。traceが`final_response`を
  提供しない場合、当該`must_report` / `must_not_report`は未検証として扱う
- phase別duration、cache mode（stat-fast / full-check / rebuild）、Tool call数、全体wall time
- 明示target時の検索不実行、不要な確認・停止、回答が参照したpath

## 効率指標

効率指標は品質期待の代替にしない。route正解率、必須読込、検証合格、backup保証の正確な報告が
同一水準で維持されることを前提に、wall time、Tool call数、読込byte、統合fixture実行数の悪化を
効率regressionとして扱う。duration系のfieldはクライアントが提供する場合だけ検査し、
自己申告のみの値は未検証として扱う。

## adapter呼び出し契約

`run`モードのadapterは`adapter --request <file> --workspace <dir> --trace <出力path>`で呼ばれる
（cwd=workspace、環境変数`AGENT_EVAL_CASE` / `AGENT_EVAL_FIXTURE`付き）。exit 0かつtraceファイル
生成が成功条件で、それ以外は`INFRA`。隔離copyはrunnerが独立Gitリポジトリとして初期化し
（baseline commit付き）、adapterのgit操作は実checkoutへ届かない。

## 採点と実行

`tools/validate-agent-directory.sh`はschema、必須case、fixture、構造を静的検査し、モデル行動とは分離する。
`tools/run-evals.py score`は既存traceを採点し、`run`はcaseごとの隔離copyへadapterを接続する。
adapter失敗やtrace未生成は`INFRA`、期待違反は`FAIL`、観測不能は`UNVERIFIED`。summaryは採点集計と
route accuracy、escalation、Tool call、read、wall time、phase、cache、baseline比をJSONで持ち、
`.agent-cache/evals/`だけへ置く。

baseline比較は既定20%と短時間noise用の絶対幅（wall / phase 100ms、Tool / read 1件、context 1KiB）を
併用する。比率は`--regression-percent`、hard gateは`--fail-on-regression`、未検証拒否は
`--fail-on-unverified`で明示する。

## Agent Decay比較

```bash
python3 tools/run-evals.py run --adapter <real-model-adapter> --profile decay --fail-on-unverified
```

adapter側でmodel等を固定し、同じ実行ファイル・process環境でClean / Aged対を隔離実行する。
`summary.json#decay_comparison`は成功率、平均read / Context / Tool call、不要escalation、stale reference、
検証成功率と各amplificationを持つ。Aged成功率をClean未満にせず、stale referenceを0、平均readを
`max(Clean×1.2, Clean+1)`、平均Contextを`max(Clean×1.2, Clean+1KiB)`以下にする。比率は
`--regression-percent`に従い、trusted trace不足は`UNVERIFIED`、gate違反は`FAIL`とする。
生成物をKnowledge、STATE、通常Contextへ取り込まない。
