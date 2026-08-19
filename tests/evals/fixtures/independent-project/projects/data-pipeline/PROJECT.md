---
name: data-pipeline
description: 外部automationが独立repoを必要とするIndependent Projectの有効な契約fixture。
status: active
mode: continuous
---

# `data-pipeline`

## 目的

独立repoで実行されるpipelineの目的と採用revisionをAgent Workspaceから追跡する。

## 継続的使命

> 検証済みのpipeline revisionを一意に採用し続ける。

## 成功指標

- **PC-01** 採用revisionと検証結果を第三者が確認できる。

## 見直し・終了条件

外部automationが廃止された場合にIndependent境界を監査する。

## 判断原則

- 同じ契約と状態をroot GitとProject固有Gitの両方へ置かない。

## 非ゴール

- root sessionからIndependent Projectの本体を直接編集しない。

## 制約・固定決定

- Project rootは`projects/data-pipeline/`であり、本体作業はそこをGit top-levelとする別sessionで行う。

## 品質基準

- remoteへ存在する完全SHAだけを採用する。

## 入力

- Independent sessionの検証済みhandoff。

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

- `STATE.md`

## 検証方法

- 実行手順: validatorを実行する。
- 合格条件: registry entryとProject rootのGit所有境界が整合する。
- 不合格時の扱い: 未完了としてSTATE.mdへ残す。
- 必要な環境変数: なし
- 使用した入力: なし
