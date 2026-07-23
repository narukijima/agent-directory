# evals/ — 振る舞いの品質保証

エージェントが `AGENTS.md` の規約どおりに振る舞うかを検証するケースを置く。

## Skillのscriptsとの分離

```text
skills/<skill>/scripts/ = そのSkill固有の実行・検証   → スキル単位
evals/                  = ルーティングと規約遵守の検証 → エージェント全体
```

## ケースの書き方

`cases/` に1ケース1ファイルで置く。文章の完全一致ではなく、構造上の不変条件を検証する。
判定をパスと分類に限定することで、モデルや文章表現が変わってもテストが壊れない。

```yaml
name: <case-name>

request: |
  <エージェントへの依頼文>

expect:
  route: knowledge | skill | temp | project   # AGENTS.md の4分類
  must_read:        # 着手前に読むべきファイル
    - AGENTS.md
  may_write:        # 書き込みが許される場所
    - projects/**
  must_not_write:   # 書き込んではならない場所
    - knowledge/raw/**
  must_not_modify:  # 既存ファイルの編集・上書き・削除の禁止 — 必要な場合のみ
    - knowledge/raw/**
```

## 実行

ケースの `request` をエージェントに与え、実際に読み書きしたパスが `expect` を満たすか確認する。
ケースが参照する入力データは `fixtures/` に置く。
