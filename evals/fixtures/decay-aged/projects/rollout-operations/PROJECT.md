---
name: rollout-operations
description: 現行の段階的ロールアウト方針を検証する継続Project。
status: active
mode: continuous
---

# `rollout-operations`

## 目的

現在有効な方針だけで安全なロールアウト判断を提供する。

## 継続的使命

> 検証済みの段階的ロールアウトを継続する。

## 成功指標

- **PC-01** 現在の方針と状態が一致し、検証が合格する。

## 見直し・終了条件

- 方針変更時に見直す。

## 判断原則

- activeな正本だけを現在判断へ使う。

## 非ゴール

- 過去方針を現在判断へ戻さない。

## 制約・固定決定

- 検証前に100%へ配備しない。

## 品質基準

- 現在値と検証結果を明示する。

## 入力

- 利用者の依頼。

## 使用するKnowledge

### Required

- `knowledge/wiki/topics/rollout-policy-current.md`

### Conditional

- なし

## 使用するSkill

### Required

- `skills/release-verification/SKILL.md`

### Conditional

- なし

## 成果物

- 現在のロールアウト判断。

## 検証方法

- 実行手順: `bash projects/rollout-operations/scripts/verify.sh`
- 合格条件: current方針とSTATEが10% canaryで一致する。
- 不合格時の扱い: 未完了としてSTATEへ残す。
- 必要な環境変数: なし
- 使用した入力: 現在正本
