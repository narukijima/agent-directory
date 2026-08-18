# data-pipeline — 作業差分

このProject固有の作業差分だけを持つ。成果契約は`PROJECT.md`、現在状態と検証証拠は`STATE.md`が所有する。

## 実行

- 検証は`PROJECT.md`の`## 検証方法`に従い、他のコマンドで代替しない。
- 生成物は`outputs/`だけへ書き、`inputs/`を書き換えない。

## Push Policy

auto

`origin`のActionsはtestだけを実行し、deploy、release、Webhookを起動しない。したがって検証済みcommitの
通常pushを自律実行してよい。この方針は一度決めたものであり、pushのたびに確認しない。
