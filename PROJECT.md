---
name: agent-directory
description: 一体の長期稼働AI AgentがKnowledge、Skill、Projectを安全に育てるdurable Agent Workspace仕様を開発・配布する
status: active
mode: continuous
---

# `agent-directory`

## 目的

AI Agentが長期間にわたり正本、責務境界、状態、安全契約を失わず、必要な文脈だけを読んで作業できる
ローカルファーストのWorkspace仕様を提供する。

## 継続的使命

> 一体のAgentごとに、検証可能で移植可能なdurable Agent Workspace仕様と決定的Toolを提供し続ける。

## 成功指標

- **PC-01** Workspaceのidentity、Knowledge、Skill、Project、Runtime Permissionの責務境界が正本と実装で一致する。
- **PC-02** 通常検証と対象変更に必要なtestが、外部AIやHosted CIを必須にせず決定的に合格する。
- **PC-03** 利用者がテンプレートからAgentを導入し、Independent Projectを独立Gitのまま再現・検証できる。

## 見直し・終了条件

- durable Agent Workspaceという目的が別の正本へ完全移管されたとき、継続または終了を利用者と見直す。
- 主要AI RuntimeまたはGitとの接続契約が変わったとき、境界と検証を見直す。

## 判断原則

- 正本を一つに保ち、派生cacheや会話記憶よりrepository contractを優先する。
- Generic Runtime Permissionを所有せず、semantic safetyとWorkspace integrityに集中する。
- 追加より統合・単純化を優先し、通常タスクの読込量を総量から切り離す。

## 非ゴール

- 複数製品を一つのmonorepoへ統合すること。
- Runtime独自のsandbox、approval database、Provider別permission wrapperを実装すること。
- Scheduler Engine、daemon、schedule registryを所有すること。

## 制約・固定決定

- 公開repositoryへの外部作用はClaudAGT rootの公開境界に従う。
- protected変更はrepository固有のguardとfull validationを通し、`--no-verify`を使わない。
- secret、実運用account、個人識別情報を公開履歴へ入れない。

## 品質基準

- `AGENTS.md`を薄いrouterとして保ち、詳細契約は領域正本と決定的Toolが所有する。
- 未検証の契約、成功自己申告だけのeval、互換copyを完成扱いしない。

## 入力

- 利用者指示、Issue、既存のWorkspace運用証拠、対象変更のGit差分。

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

- `AGENTS.md`、`knowledge/`、`skills/`、`projects/`、`evals/`、`tools/`からなる公開Workspace仕様。

## 検証方法

- 実行手順: `bash tools/validate-agent-directory.sh --full`と対象変更の追加testを実行する。
- 合格条件: PC-01からPC-03に関係するvalidator、fixture、参照、Git境界検査がすべてexit 0となる。
- 不合格時の扱い: 未完了として`STATE.md`へ失敗理由と次の一手を残す。
- 必要な環境変数: なし。
- 使用した入力: Git working treeとrepository内fixture。
