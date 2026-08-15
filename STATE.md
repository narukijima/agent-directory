---
updated_at: 2026-08-16
---

# Current State

## 現在の到達点

公開テンプレートはAgent identity、Project attachment、明示Skill import、決定的validator、boundary hookを持つ。
ClaudAGT AgentのIndependent Projectとして継続開発するProject契約を導入した。
通常開発と明示済み外部作用は途中承認なしで完遂することをCore evalへ固定した。
モデル更新に伴う包括的再監査で、テスト・フィクスチャ環境におけるTMPDIR伝播の不備（GitHub authテスト、routine fixture）、
routine-reasonerのローカルエンドポイント接続堅牢化、およびisolated snapshotにおけるGit境界初期化（git init）を実施し、
full validation（静的検査、全fixture、正本参照、boundary検査）が0 warningで完全合格する状態を確立した。
公開Issue #87〜#90に対し、未公開privacy履歴の限定訂正契約、説明文付きSTATE契約anchorの抽出、raw CRを持たない
router判定、blob一回読込による決定的なrange privacy検査と回帰fixtureを導入し、通常・full validationを
0 warningで合格させた。
capability-firstのRecommended Multi-AI Operating Profileを独立正本として追加し、Codex、Claude Code、
optional ChatGPT、決定的Toolの推奨分担、単一runtime fallback、Single Owner、repository state、
business-level orchestrationとMaintenance Routineの境界、交換可能な現行モデル推奨をCore compatibilityと
分離した。README入口、委譲境界、Routine参照、validator、Core evalを同じ責任モデルへ追従させた。
公開remoteがPR必須ruleを持つ場合に通常push拒否で停止する運用欠陥を修正し、head branch、PR、expected head、
remote merge、default branch確認を一つの完了経路にした。local merge禁止とremote rule準拠を分離し、
同じ失敗をCore evalとvalidatorで再発防止した。
さらにmerge済みsource branchの残存を未完了として扱い、PR metadata、expected head、default branch反映を
確認した後にexact remote branchと一致するlocal branchを削除・不在確認するところまで同じ完了経路へ含めた。
raw ref削除の一般解禁はせず、PR cleanupだけを限定例外としてCore evalとvalidatorで固定した。

## 現在の目標

対象契約: `PROJECT.md#PC-01`

Workspace責務境界を壊さず、ClaudAGTエコシステムの変更と整合する公開仕様を維持する。

## 目標の合格条件

- 変更後の正本、Tool、validator fixture、関連Projectへの影響が矛盾しない。
- repository固有のfull validationが合格する。

## 検証結果

- 対象: `PROJECT.md#PC-01`
- 確認日: 2026-08-16
- 方法: `git diff --check`、`bash -n tools/check-boundary.sh tools/validate-agent-directory.sh`、
  `bash tools/validate-agent-directory.sh --changed`、`bash tools/validate-agent-directory.sh --full`。
- 結果: Recommended Profileの正本構造、provider-neutral fallback、Routine境界、PR必須remote完了経路、
  merge後branch cleanup、Core eval schemaを含むfull validationが0 warning / 0 failureで完全合格した。

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
