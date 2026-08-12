---
name: rollout-operations-paused
description: 休止中の類似ロールアウトProject。
status: paused
mode: continuous
---

# `rollout-operations-paused`

## 目的

休止中の旧運用を保持する。

## 継続的使命

> 明示再開まで休止状態を維持する。

## 成功指標

- **PC-01** 休止状態が保持される。

## 見直し・終了条件

- 明示再開時だけ見直す。

## 判断原則

- 通常候補にしない。

## 非ゴール

- 現行運用を所有しない。

## 制約・固定決定

- 自動再開しない。

## 品質基準

- pausedを維持する。

## 入力

- 過去状態。

## 使用するKnowledge

### Required

- なし

### Conditional

- なし

## 使用するSkill

### Required

- なし

### Conditional

- なし

## 成果物

- 休止状態。

## 検証方法

- 実行手順: statusを確認する。
- 合格条件: pausedである。
- 不合格時の扱い: 停止する。
- 必要な環境変数: なし
- 使用した入力: 過去状態
