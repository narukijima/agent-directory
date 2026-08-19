# SKILLS.md — Portable Skill sourceの正本

Skill sourceを作成・更新するときに読む。Knowledgeは「何が分かっているか」、Skillは「どう処理するか」、
Projectは「何を作り残すか」を所有する。再利用可能な研究方法そのものを手順として作る依頼はこのRouteであり、
具体的な研究活動と研究中の仮説はProjectが所有する。

このディレクトリはSkill discovery、選択、起動、subagent実行を行わない。それらは各Runtimeが所有する。
`skills/<name>/`はAgent Skills公開標準に従うProvider間共有sourceであり、consumerはRuntime標準のSkill配置へ
薄いadapterまたは明示importで接続する。Provider固有frontmatterは共有sourceの必須契約にしない。

## 共有Skillライブラリ

Agent間で再利用する汎用Skillは、別リポジトリの [`agent-skills`](https://github.com/claudagt/agent-skills) が配布元である。
このWorkspaceへSkillを標準で自動導入・自動同期はしない。必要なタスクで利用者が明示したときだけ、target側のimport
transactionで`skills/<skill-name>/`をコピーし、取り込んだSkillをこのWorkspaceの正本にする。

```bash
bash tools/import-skill.sh <skill-name> --source /path/to/agent-skills
```

インポート先には `skills/<skill-name>/agents/upstream.yaml` が作られ、配布元repository、commit SHA、Skill version、
インポート時刻を記録する。target側はfrontmatterをAgent Skills標準の6 fieldへ正規化し、CodexとClaude Codeの標準pathへ
同じ正本のsymlinkを作る。既存Skillは上書きせず、更新時は上流との差分を確認してから明示的に再インポートする。

## Runtime接続

- root `CLAUDE.md`は`@AGENTS.md`だけをimportし、Claude Code用の規則本文を複製しない。
- Runtimeが発見する配置、発動条件、invocation policyはRuntime側設定が所有する。
- Codex用`.agents/skills/<name>`とClaude Code用`.claude/skills/<name>`は、必要なSkillだけを
  `../../skills/<name>`へ結ぶper-Skill symlink adapterとする。Skill本文、references、scriptsを複製しない。
- 共有Skillのadapterは`tools/import-skill.sh`がimportと同じtransactionで作る。固有Skillはsource作成後に同じlinkを作る。
- adapterを利用できないRuntimeでは、そのRuntime自身の標準導入経路をconsumerが所有する。Core独自の
  discovery、同期、copy daemon、fallbackを追加しない。
- Skillを実行するときはRuntimeが選んだ`SKILL.md`を最後まで読み、descriptionだけで代用しない。

## frontmatterと状態

```yaml
---
name: skill-name
description: 発動条件が分かる簡潔な一行説明
metadata:
  agent-directory.status: "active"
  agent-directory.aliases: "別名1,別名2"
---
```

- `name`はSkillディレクトリ名と一致させる。
- `description`のhard limitはAgent Skills標準の1,024文字とし、発見時の短縮に耐えるよう200文字以内を推奨する。
- top-levelはAgent Skills標準の`name`、`description`、任意の`license`、`compatibility`、`metadata`、
  experimental `allowed-tools`だけを使う。`allowed-tools`は対応Runtimeを確認したSkillだけが宣言でき、
  CoreのRuntime Permissionやapprovalの代替にはしない。
- `metadata.agent-directory.status`は`active | deprecated | retired`だけを使う。
- `metadata.agent-directory.aliases`はcomma-separated stringとし、別名がなければ空文字列にする。
- deprecatedはactiveな後継`SKILL.md`への`metadata.agent-directory.replaced-by`を持たせる。
- retiredは実行しない。deprecatedは明示的な互換性確認以外では後継を使う。
- 状態変更のために物理移動せず、パスを維持する。
- 旧consumerのtop-level `status` / `aliases`は非strict検証で移行互換として読めるが、新規作成・更新・importでは書かない。

## Knowledge参照

`SKILL.md`の「使用するKnowledge」を次に分ける。

- **Required** — 実行時に必ず読む。最大3件。リポジトリ相対パスで指定する。
- **Conditional** — `条件:`と`参照:`を組にし、条件成立時だけ読む。

通常判断ではactive Knowledgeだけを使う。原資料へ遡る条件は`knowledge/KNOWLEDGE.md#原資料へ遡る条件`、
総読込予算は`AGENTS.md#Context Loading`が所有する。

## 新規作成・更新

- Skillの新設は既存Skillの更新・統合で目的を満たせない場合だけ候補とし、作成前にOwnerへ確認する。
  明示的な新規Skill作成依頼はこの確認を満たす。将来使うかもしれないという理由では追加しない。
- `_template/`をコピーし、frontmatter、発動条件、手順、出力契約、Knowledge参照を置換する。
- `_template/`自体はSkillではない。`SKILL.md`だけを持ち、空の下位フォルダを常設しない。
- Skill固有の決定的処理はSkillの`candidates/`または`scripts/`が所有する。
  一時コードから固定コードへの段階は`tools/TOOLS.md#一時作業`に従う。
- 同じ目的の方法を2回目に使ったタスクの差分判定（`AGENTS.md#差分判定`）では、`candidates/`への
  記録可否を判定する。単発の成功をactive Skillへ直接昇格しない。
- 詳細方法は`references/`、再利用テンプレートは`assets/`へ委譲し、`SKILL.md`を入口として短く保つ。
- `SKILL.md`は20KiBを超えない。超える詳細は明示参照された補助ファイルへ分ける。
- 下位フォルダへ`README.md`を置いて領域説明の正本にしない。各フォルダの責務はこの節が所有する。

## 基本構造

必要になったSkillだけが下位フォルダを作る。空のフォルダを先に生成しない。

```text
skill-name/
├── SKILL.md      # 入口。発動条件、手順、出力契約、Knowledge参照
├── agents/       # import provenance等、配布契約が要求する場合だけ
├── references/   # SKILL.mdに収まらない詳細な分析方法。必要時だけ読む
├── assets/       # 繰り返し使うテンプレートと出力雛形
├── candidates/   # 同じ目的で2回目に使う未安定な再利用候補。3回目の前に固定化を判断する
└── scripts/      # 入出力と検証方法が安定した固定処理
```
