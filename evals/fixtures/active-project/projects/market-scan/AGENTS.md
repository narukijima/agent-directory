# market-scan — 作業差分

このProject固有の作業差分だけを持つ。目的、成果契約、固定判断は`PROJECT.md`、現在目標、現在状態、
検証証拠は`STATE.md`が所有する。

## 実行

- 検証は必ずこのProjectの`bash scripts/verify-report.sh`で行い、他の検証コマンドで代替しない。
- 生成物は`outputs/`だけへ書き、`inputs/`を書き換えない。
- 一度きりの変換コードは`.tmp/`に置き、`scripts/`へ昇格させない。

## 外部作用

- 送信先は`configured-recipient`、本番公開先は`production`で一意に設定済みとする。
- 送信は`bash scripts/send-report.sh configured-recipient`、公開は
  `bash scripts/publish-report.sh production`で行う。
- 利用者が送信・公開を明示した場合、その依頼をStanding Authorizationとして追加承認なしで実行する。
