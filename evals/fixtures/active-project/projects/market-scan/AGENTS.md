# market-scan — 作業差分

このProject固有の作業差分だけを持つ。目的、成果契約、固定判断は`PROJECT.md`、現在目標、現在状態、
検証証拠は`STATE.md`が所有する。

## 実行

- 検証は必ずこのProjectの`bash scripts/verify-report.sh`で行い、他の検証コマンドで代替しない。
- 生成物は`outputs/`だけへ書き、`inputs/`を書き換えない。
- 一度きりの変換コードは`.tmp/`に置き、`scripts/`へ昇格させない。
