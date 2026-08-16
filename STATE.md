---
updated_at: 2026-08-16
---

# Current State

## 現在の到達点

公開テンプレートはAgent identity、Project attachment、明示Skill import、決定的validator、boundary hookを持つ。
ClaudAGT AgentのIndependent Projectとして継続開発するProject契約を導入した。
通常開発と明示済み外部作用は途中承認なしで完遂することをCore evalへ固定した。
公開Issue #87〜#90に対し、未公開privacy履歴の限定訂正契約、説明文付きSTATE契約anchorの抽出、raw CRを持たない
router判定、blob一回読込による決定的なrange privacy検査と回帰fixtureを導入し、通常・full validationを
0 warningで合格させた。
capability-firstのRecommended Multi-AI Operating Profileを独立正本として追加し、Codex、Claude Code、
optional ChatGPT、決定的Toolの推奨分担、単一runtime fallback、Single Owner、repository state、
Scheduled Executionの交換可能な現行mappingをCore compatibilityと分離した。
定期実行はOperator / Runtime / OS側の外部triggerとし、Agent内部では通常の
`Route → Target → Work → Verify → Finish`だけを使う。独自executor、schedule管理、provider adapter、
専用lock / state / log、専用evalを廃止し、変更時validationと必要時のcache再生成へ集約した。
Issue #92に対しroot `AGENTS.md`のOwner側詳細を縮約し、routerを4,925B、soft budget残余を1,219Bにした。
導入先が小さな固有契約を追加してもwarning 0となる回帰fixtureをfull validatorへ固定した。
公開remoteがPR必須ruleを持つ場合に通常push拒否で停止する運用欠陥を修正し、head branch、PR、expected head、
remote merge、default branch確認を一つの完了経路にした。local merge禁止とremote rule準拠を分離し、
同じ失敗をCore evalとvalidatorで再発防止した。
さらにmerge済みsource branchの残存を未完了として扱い、PR metadata、expected head、default branch反映を
確認した後にexact remote branchと一致するlocal branchを削除・不在確認するところまで同じ完了経路へ含めた。
raw ref削除の一般解禁はせず、PR cleanupだけを限定例外としてCore evalとvalidatorで固定した。
Operator / machine setupを`SETUP.md`へ集約し、Claudeの長期OAuth認証、Workspace / Git root起動、
secret非表示のruntime preflight、scheduled executionの事前条件を正本化した。Multi-AI Profileには
Claude CLIのavailability failure時にCodexがobjectiveとproduction responsibilityを引き取る宣言済みfallback、
partial execution照合、Desktopのmanual alternative、Single Owner / Single Writer維持を追加した。

## 現在の目標

対象契約: `PROJECT.md#PC-01`

Workspace責務境界を壊さず、ClaudAGTエコシステムの変更と整合する公開仕様を維持する。

## 目標の合格条件

- 変更後の正本、Tool、validator fixture、関連Projectへの影響が矛盾しない。
- repository固有のfull validationが合格する。

## 検証結果

- 対象: `PROJECT.md#PC-01`
- 確認日: 2026-08-16
- 方法: `git diff --check`、`bash -n tools/check-runtime-readiness.sh tools/validate-agent-directory.sh`、
  `bash tools/check-runtime-readiness.sh`、`bash tools/validate-agent-directory.sh --changed`、
  `bash tools/validate-agent-directory.sh --full`。
- 結果: Codex / Claude availabilityとsecret非表示、誤cwd拒否、Multi-AI fallback、partial execution、Markdown参照、
  adapter、boundary、Core eval schemaを含むfull validationが0 warning / 0 failureで完全合格した。

## 未完了・ブロッカー

- 既知のブロッカーはない。

## 現在有効な決定

- `agent-directory`はClaudAGT rootではなく、その配下のIndependent Projectである。
- 現在判断ではactiveなKnowledgeとSkillを優先し、非activeな参照は履歴確認時だけ使う。
- 明示依頼は通常完了経路全体のStanding Authorizationであり、工程ごとの再承認を要求しない。

## 失敗・却下済み

- ClaudAGT全製品のmonorepo化: remote identity、公開境界、製品責務を混同するため採用しない。

新しい根拠または利用者の明示指示がない限り、ここにある方法を繰り返さない。

## 次の一手

1. 次の利用者scopeに対して対象正本と影響するClaudAGT Projectを特定する。
