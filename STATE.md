---
updated_at: 2026-08-15
---

# Current State

## 現在の到達点

公開テンプレートはAgent identity、Project attachment、明示Skill import、決定的validator、boundary hookを持つ。
ClaudAGT AgentのIndependent Projectとして継続開発するProject契約を導入した。
通常開発と明示済み外部作用は途中承認なしで完遂することをCore evalへ固定した。

## 現在の目標

対象契約: `PROJECT.md#PC-01`

Workspace責務境界を壊さず、ClaudAGTエコシステムの変更と整合する公開仕様を維持する。

## 目標の合格条件

- 変更後の正本、Tool、validator fixture、関連Projectへの影響が矛盾しない。
- repository固有のfull validationが合格する。

## 検証結果

- 対象: `PROJECT.md#PC-01`
- 確認日: 2026-08-15
- 方法: `git diff --check`、`bash tools/validate-agent-directory.sh --full`。
- 結果: 無確認完遂evalのCore昇格と`max_escalations: 0`を含む変更が0 warningで合格した。

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
