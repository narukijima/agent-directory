---
name: rollout-operations-2025
description: 2025年の旧ロールアウト判断を保持する完了済みProject。
status: completed
mode: finite
---

# `rollout-operations-2025`

## 目的

過去判断を監査可能に保持する。

## 最終ゴール

> 2025年の判断を履歴として保持する。

## 完了条件

- **PC-01** 2025年の判断が保持される。

## 判断原則

- 現在判断には使わない。

## 非ゴール

- active Projectとして扱わない。

## 制約・固定決定

- 自動再開しない。

## 品質基準

- 監査時だけ読む。

## 入力

- 2025年の記録。

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

- 過去判断。

## 検証方法

- 実行手順: statusを確認する。
- 合格条件: completedである。
- 不合格時の扱い: 未完了とする。
- 必要な環境変数: なし
- 使用した入力: 2025年の記録
