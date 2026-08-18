---
name: customer-app
description: 一般利用者のProject状態契約を固定するfixture
status: active
mode: finite
---

# Customer App

## 目的

一般Projectを遂行する。

## 最終ゴール

> 検証済み成果物を作る。

## 完了条件

- **PC-01** 成果物が検証済みである。

## 判断原則

- Project固有状態をこの契約とSTATEで管理する。

## 非ゴール

- 公開基盤製品を管理しない。

## 制約・固定決定

- 一般Project契約に従う。

## 品質基準

- 決定的に検証する。

## 入力

- 利用者指示。

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

- 検証済み成果物。

## 検証方法

- 実行手順: 対象testを実行する。
- 合格条件: testがexit 0となる。
- 不合格時の扱い: 未完了としてSTATEへ残す。
- 必要な環境変数: なし。
- 使用した入力: fixture。
