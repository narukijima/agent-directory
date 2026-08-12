---
name: release-verification
description: 現行ロールアウト方針と状態の一致を検証する。
status: active
aliases: [release check]
---

# `release-verification` — 現行ロールアウト検証

## 発動条件

- ロールアウト前の検証を求められたとき。

## 目的

現在正本とSTATEの一致を確認する。

## 使用するKnowledge

### Required

- `knowledge/wiki/topics/rollout-policy-current.md`

### Conditional

- なし

## 手順

1. current方針とSTATEを照合する。
2. Projectの固定検証を実行する。

## 出力契約

- 検証結果と現在値を返す。

## 禁止事項

- 非activeな方針を現在値として使わない。
