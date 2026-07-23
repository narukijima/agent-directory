# agent-directory

AIエージェントのディレクトリ構造テンプレート。

エージェントに知識を蓄積させ、固有のスキルを習得させることで、育てながらタスクを遂行していく。

## English Overview

A directory-structure template for AI agents — accumulate knowledge, acquire skills, and grow your agent while it works.

- `AGENTS.md` — top-level contract that routes every request (knowledge / skills / temp work / projects)
- `knowledge/` — immutable source records (`raw/`, `research/`) turned into reusable knowledge (`wiki/`)
- `skills/` — analysis procedures with entry points (`SKILL.md`), one directory per skill
- `projects/` — long-lived work and deliverables (`PROJECT.md`), one directory per project
- `evals/` — behavioral QA: cases that verify routing and contract compliance
- `tools/` — scripts that maintain this directory structure itself
- `.tmp/` — temporary workspace, cleaned up when work completes

Getting started:

1. Copy or clone this repository (one copy per agent).
2. Replace the `<agent-name>` / `<project-dir>` placeholders in [AGENTS.md](AGENTS.md).
3. Add your skills by copying `skills/_template/` and register them in [skills/README.md](skills/README.md).
4. Operate the agent, accumulating knowledge under the rules in [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md).

Full documentation is in Japanese. The structure itself (directory names, file layout) is language-neutral, and the rule files are written for LLM agents, which read Japanese natively.

## 利用開始

1. このリポジトリをコピーまたはクローンする。
2. [AGENTS.md](AGENTS.md) の `<agent-name>` などのプレースホルダーを、自分のエージェント名・役割・固有プロジェクトに書き換える。
3. `skills/_template/` をコピーして必要なSkillを追加し、[skills/README.md](skills/README.md) の一覧へ登録する。
4. [knowledge/KNOWLEDGE.md](knowledge/KNOWLEDGE.md) の規約に沿ってKnowledgeを蓄積しながら運用する。

## 利用例

エージェント1体につき、この構造を1つ持たせる。マシンを増やせば水平に拡張できる。

```text
Mac mini 1/
├── Agent-1/agent-directory/   # エージェントごとに独立した知識・スキル・プロジェクト
├── Agent-2/agent-directory/
└── Agent-3/agent-directory/
Mac mini 2/
├── Agent-4/agent-directory/
└── ...
```

## 構成

```text
agent-directory/
├── AGENTS.md               # 最上位規約 — 依頼の振り分け・禁止事項・参照順序
├── README.md               # このファイル
├── LICENSE                 # MIT License
├── .env.example            # 環境変数のプレースホルダー
├── .tmp/                   # 一時作業領域 — Git管理外
├── knowledge/
│   ├── KNOWLEDGE.md        # Knowledge運用の正本
│   ├── raw/                # 内部で生まれた原記録 — 編集・削除しない
│   ├── research/           # 外部から取得した原資料 — 内容を変えない
│   └── wiki/               # 原資料を再利用可能な知識へ変換
│       ├── index.md        # 全体の入口
│       ├── guide.md        # 構造と使い方の案内
│       ├── log.md          # 時系列履歴
│       ├── sources/        # 資料別ノート — 1資料1ページ
│       └── topics/         # 統合知識 — 1トピック1ページ
├── skills/
│   ├── README.md           # スキル分類の正本
│   └── _template/          # 新規スキルの雛形 — コピーして使う
│       ├── SKILL.md        # 入口 — 発動条件・手順・出力契約
│       ├── agents/         # 表示情報
│       ├── references/     # 詳細な分析方法
│       ├── assets/         # テンプレート類
│       └── scripts/        # 検証・テスト処理
├── projects/
│   ├── README.md           # プロジェクト運用の正本
│   └── _template/          # 新規プロジェクトの雛形
│       └── PROJECT.md      # 入口 — 状態・目的・完了条件・成果物・再現方法
├── evals/
│   ├── README.md           # 検証方法の正本
│   ├── cases/              # 検証ケース — 1ケース1ファイル
│   └── fixtures/           # ケース用の入力データ
└── tools/
    └── README.md           # 構造保守スクリプトの置き場 — 必要時に追加
```

## 役割

| 領域 | 役割 |
|------|------|
| `AGENTS.md` | 司令塔 — 依頼を正しい場所へ振り分ける |
| `knowledge/` | 記憶 — 原資料の蓄積と知識化 |
| `skills/` | 能力 — 分析方法と判定 |
| `projects/` | 仕事 — 固有プロジェクトの入力・成果物・実行記録 |
| `evals/` | 品質 — ルーティングと規約遵守の検証 |
| `tools/` | 保守 — この構造自体の点検・自動化 |
| `.tmp/` | 作業机 — 中間ファイル置き場 |

## 流れ

```text
知識を覚える依頼
  AGENTS.md → KNOWLEDGE.md → raw / research → sources → topics

分析の依頼
  AGENTS.md → skills/README.md → SKILL.md →(必要なら Wiki・原資料へ遡る)

データ・成果物の依頼
  AGENTS.md → projects/README.md → projects/<project>/ に保存

一時的な作業
  .tmp/ に置く → 正式保存後に片付ける
```

## License

[MIT](LICENSE)
