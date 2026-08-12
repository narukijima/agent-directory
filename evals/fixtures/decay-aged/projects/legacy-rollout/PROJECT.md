---
name: legacy-rollout
description: 廃止済みの旧ロールアウトProject。
status: retired
mode: finite
---

# `legacy-rollout`

## 目的

廃止済み方式の存在だけを保持する。

## 最終ゴール

> 旧方式を廃止状態で保持する。

## 完了条件

- **PC-01** retiredが保持される。

## 判断原則

- 現在判断には使わない。

## 非ゴール

- 再開しない。

## 制約・固定決定

- 廃止済み。

## 品質基準

- retiredを維持する。

## 入力

- 旧方式。

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

- 廃止記録。

## 検証方法

- 実行手順: statusを確認する。
- 合格条件: retiredである。
- 不合格時の扱い: 停止する。
- 必要な環境変数: なし
- 使用した入力: 旧方式
