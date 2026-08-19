---
name: market-scan
description: 指定四半期の市場動向レポートを作る停止中の有限Project。
status: paused
mode: finite
---

# `market-scan`

## 目的

経営判断に必要な市場動向を四半期単位で確認できるようにする。

## 最終ゴール

> 指定四半期の市場動向レポートを、経営判断に使える検証済みの状態で一度提供する。

## 完了条件

- **PC-01** 四半期レポートが`outputs/`に保存されている。
- **PC-02** 指定の検証方法が合格している。

## 判断原則

- 未検証の網羅性より、検証済みの判断材料を優先する。

## 非ゴール

- 日次速報は作成しない。

## 制約・固定決定

- 再開は利用者の明示指示後に行う。

## 品質基準

- 未検証のレポートを完成扱いにしない。

## 入力

- `inputs/quarter.csv`

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

- `outputs/quarterly-report.md`

## 検証方法

- 実行手順: `test -s outputs/quarterly-report.md`
- 合格条件: 四半期レポートが存在し、空ではない。
- 不合格時の扱い: 未完了として`STATE.md`に残す。
- 必要な環境変数: なし
- 使用した入力: `inputs/quarter.csv`
