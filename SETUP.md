# SETUP.md — Operator / Machine Setup

この文書は、Agent WorkspaceをOpenAIまたはAnthropicのProvider familyから独立して利用するための
Operator / machine側setupの正本である。Providerとsurfaceの選択、分離、handoff、recoveryは
[OPERATING_PROFILE.md](OPERATING_PROFILE.md)が所有し、本書はruntimeの導入、認証、Workspace Trust、
事前診断、machine-local secretだけを扱う。

## Supported runtimes

- Chat / ChatGPT Work / Codex: OpenAI familyのsurface。primary deliverableと必要capabilityに応じて選ぶ。
- Codex CLI / Desktop: OpenAI familyのrepository / technical runtime。単独でも利用できる。
- Claude / Claude Code: Anthropic familyの独立runtime。OpenAIの自動workerやfallbackとして使わない。
- Claude Desktop / Claude Code Desktop: Anthropic familyのinteractive surface。
- shell、Python、API、DB、既存Tool: 決定的な実行・検証層。

製品名は交換可能なcurrent implementationであり、Agent Workspaceの長期契約ではない。CLIやDesktopの
機能差は各Providerの現行公式文書を確認する。

## Initial setup

1. Agent Workspaceをエージェント1体につき1つcopyまたはcloneする。
2. `AGENTS.md`の自己定義placeholderを置換する。
3. shellでこのWorkspaceのGit rootへ移動する。
4. `bash tools/setup-local-environment.sh`を実行する。
5. `bash tools/install-git-hooks.sh --install`を実行する。
6. GitHubを利用するAgentごとに、そのAgent専用fine-grained PATを発行する。repository accessは
   `Only select repositories`、expirationを必須とし、backupだけなら`Contents: Read and write`を付ける。
   対象Agent rootで`bash tools/setup-github-auth.sh --install-token`を実行し、そのrootの`.env`へ保存する。
   保存済みfine-grained PATをAgent rootへ移す初期setupだけ`--install-from-gh`を使う。続けて
   `bash tools/setup-github-auth.sh --workspace-ready --remote backup --operation git-push`と
   `bash tools/setup-github-auth.sh --check --remote backup`を実行する。別Agent、OS home、machine共通storeへ保存しない。
7. 利用するProviderのruntimeを認証する。OpenAI主運用では
   `bash tools/check-runtime-readiness.sh --profile auto --require-codex`、Anthropic運用では
   `--profile auto --require-claude`を実行する。`auto`は推奨値であり、Operatorが`ask`または`full`を選んでもよい。
8. `bash tools/validate-agent-directory.sh --strict --full`を実行する。

両Providerを同じmachineへ導入していても、一つのtaskに両方を必須にしない。明示的に両runtimeのmachine readinessを
監査するときだけ両flagを指定する。引数なしのpreflightは両runtimeをread-onlyで診断するが、runtime unavailable
だけでは非0にしない。

Agent固有の環境変数、secret、API token、外部サービス設定はAgent Workspace rootの`.env`だけが所有する。
OS home、`~/.config`、Keychain、machine共通file、別Agent root、global process environmentを正本またはfallbackにしない。
`.env`はGit管理外、owner=current user、mode `0600`、no symlink、nlink=1とし、Toolはsourceせず
`tools/lib/agent-env.sh`で必要なkeyだけを読む。他のAgentから自動探索しない。

GitHubでは同じrootの`.env`に`GH_TOKEN=<fine-grained PAT>`を1回だけ置く。`--install-token`はtokenをargvや
remote URLへ入れず非表示入力し、既存の他keyを保ったまま`GH_TOKEN`だけをatomic replaceする。
`--install-from-gh`は初期移行専用、`--workspace-ready`はnetworkなしのlocal検査、`--check`はAPI / Git実probeである。
process tokenは明示CIだけの例外とし、通常localでは消費しない。rotationは同じAgent rootの`.env`だけを更新し、
実probe後に旧tokenをGitHubでrevokeする。classic PATは禁止する。

## Workspace root

CodexまたはClaude CLIは、実際に作業するAgent Workspace / Git rootをworking directoryとして起動する。
Agent Workspace rootで作業するなら、そのrootへ`cd`してから`codex`または`claude`を起動する。
Independent Projectへhandoffした後は、そのProject自身のGit rootをcwdにする。`$HOME`、呼出元不明のdirectory、
または親Workspaceのrootから、別Git rootのProjectを暗黙に操作しない。

Anthropicの[Security](https://code.claude.com/docs/en/security)によれば、Claude Codeをhome directoryから
直接起動した場合のTrust acceptanceはsession限定で、次回起動時にpromptが再表示される。project
subdirectoryではdirectoryごとに保存される。またworking directoryはwrite boundaryでもある。そのため、
`~/.claude.json`の`hasTrustDialogAccepted`等の内部fieldを直接patchする方法はCore recommendationにしない。

初回は実際のWorkspace / Project rootからinteractiveに`claude`を一度起動し、表示されたTrust対象を確認して
acceptする。特に`claude --worktree`は、Anthropicの
[worktree文書](https://code.claude.com/docs/en/worktrees)に従い、対象directoryで事前にTrustをacceptする。
non-interactive modeの挙動だけに依存せず、scheduled launcherやsubprocessでもcwdを明示する。

## Claude authentication

interactive利用では、Claude Codeの`/login`によるsubscription OAuth認証が既定候補である。browser loginを
使えないCI、script、scheduled / unattended環境では、Anthropicの現行
[Authentication文書](https://code.claude.com/docs/en/authentication)に従い、別の安全なinteractive環境で
`claude setup-token`を実行し、発行された長期OAuth tokenを実行環境の`CLAUDE_CODE_OAUTH_TOKEN`として渡す。

現行公式仕様では、このtokenは約1年間利用でき、Claude Pro / Max / Team / Enterprise subscriptionが必要で、
model inferenceに限定される。`claude setup-token`はtokenを保存しないため、Operatorがmachine-local secret store、
OS credential store、CI secret、またはschedulerのsecret機構へ保存する。`--bare`は
`CLAUDE_CODE_OAUTH_TOKEN`を読まないため、利用する場合は公式文書が案内するAPI keyまたは`apiKeyHelper`を使う。

認証状態は、実行runtimeと同じuser・environmentから次で確認する。

```bash
claude auth status
```

interactive loginだけに依存したscheduled executionは推奨しない。scheduled launcherが起動時に必要なcredentialを
環境変数として参照できることを確認する。tokenの実値をcommand line、stdout、log、repository設定へ出さない。

## Provider-specific setup

Codexの導入と認証はOpenAIの現行[Codex CLI文書](https://developers.openai.com/codex/cli)と
[authentication文書](https://developers.openai.com/codex/auth)に従う。CLIの現在状態は次で確認できる。

```bash
codex --version
codex login status
```

ChatとChatGPT WorkはOpenAI Product側で利用し、Agent Workspaceは直接dispatch adapterを提供しない。
Claude Codeは上記の方法で独立して認証する。両Providerを導入していてもtask ownerを共有させない。
`.codex/`と`.claude/`は`tools/setup-local-environment.sh`を呼ぶ薄いadapterのまま保ち、認証token、
Provider選択、handoff policy、Provider別permission logicを複製しない。

### Runtime Profileの現行mapping

Agent DirectoryのProfileとProvider modeは同一概念ではない。Operatorは利用surfaceの現行公式仕様と環境リスクに応じて
近いmodeを選び、Agent Directoryは設定fileを自動変更しない。

| Agent Directory | Codexの現行対応例 | Claude Codeの現行対応例 |
|---|---|---|
| `ask` | `on-request`または`untrusted` approvalと保守的sandbox | `default`（Manual） |
| `auto` | 標準Autoの`workspace-write + on-request`。必要ならworkspace networkを明示し、利用可能ならAuto-reviewを使う | 対応account / model / providerでは`auto`。利用不能なら不足を報告し、`acceptEdits`を同一能力と偽らない |
| `full` | isolated環境でのみ`danger-full-access`と最少approval | isolated環境でのみ`bypassPermissions` |

Codexではsandboxとapprovalが別設定で、`workspace-write`のnetworkは既定offである。Claude Codeの`auto`はavailability条件があり、
現行CLIではproject-local `.claude/settings.json`の`permissions.defaultMode: "auto"`を開始modeとして採用しない。
そのため本テンプレートの`.codex/` / `.claude/`へprofileを固定せず、Operator / Runtime側で選択する。
参照: [OpenAI Agent approvals & security](https://learn.chatgpt.com/docs/agent-approvals-security)、
[Anthropic Permission modes](https://code.claude.com/docs/en/permission-modes)。

## Preflight checks

`tools/check-runtime-readiness.sh`は既定でnetwork mutationを行わず、secret値を表示しないcapability diagnosticである。
`--profile`はOperatorの選択を宣言し、未指定時は`auto`を`recommended-default`として表示するがRuntime設定を変更しない。
taskが必要とする能力は`--require-capability`、Runtimeが既知の未実測状態は`--capability-state`で渡す。
workspace writeを要求またはprobeしたときだけ、一時fileを作成・削除して実測する。

```bash
bash tools/check-runtime-readiness.sh
bash tools/check-runtime-readiness.sh --profile auto --require-codex
bash tools/check-runtime-readiness.sh --profile ask --require-claude
bash tools/check-runtime-readiness.sh --profile auto \
  --require-capability filesystem_write \
  --require-capability network --capability-state network=declared
bash tools/check-runtime-readiness.sh --profile full \
  --require-capability network --capability-state network=unavailable
```

次を確認する。

- 選択profileと、明示指定か推奨defaultか
- cwd、filesystem read、process spawn、Gitの観測結果と、filesystem writeの実測有無
- `codex` / `claude` executable availability、version、provider authenticationを別fieldで表示
- taskのrequired capabilitiesと、各能力の`observed / declared / not-probed / unavailable`
- `CLAUDE_CODE_OAUTH_TOKEN`がprocess environmentに存在するか（値は表示しない）
- `GH_TOKEN` / `GITHUB_TOKEN`の存在と、通常localでは消費しないpolicy（値は表示しない）

最初に`RUNTIME_CAPABILITIES`を1行で返す。required capabilityが`not-probed`なら
`RUNTIME_READINESS_UNVERIFIED`として継続可能な未観測を分け、`unavailable`なら
`RUNTIME_READINESS_BLOCKED reason=capability-unavailable layer=runtime`で停止する。required runtimeの認証失敗は
`external-provider`、cwd / Git root不一致は`repository-integrity`に分類する。これはavailabilityの観測であり、
taskのowner変更やfallback実行は行わない。GitHubが必要な外部操作はこの汎用診断だけでreadyとせず、操作直前に
`setup-github-auth.sh --workspace-ready --operation <operation>`または対象固定Toolで検査する。

## Scheduled / unattended execution

scheduled launcherはOperator / Runtime / OS側が所有し、次の事前条件を満たす。

- objective、target、destination、Project契約を通常taskと同じ形で保持する。
- cwdをAgent Workspaceまたはhandoff先Independent Projectの実Git rootへ固定する。
- 選択した一つのProvider familyに必要なruntime認証を起動userから参照できる。
- interactive promptを必要とするTrust、login、OS permissionを初回実行前に解決する。
- output、作業記録、Git state、外部作用のreceiptを、再開時に確認できる場所へ残す。
- runtime unavailable時は同じProvider内のrecoveryとstate照合を行い、別Providerへ自動移管しない。

## Provider isolation and recovery

OpenAI taskはOpenAI family内、Anthropic taskはAnthropic family内でrecoveryする。
別Providerを自動worker、reviewer、fallbackにしない。executable、認証、startup、runtime availabilityを再観測し、同じProvider内のresume、意味のある
再試行、利用可能な別surfaceを検討する。

partial execution後はfile、Git、output、external side effect、receipt、idempotencyを照合する。Provider family全体が
利用不能なら未完了と次の一手を報告し、必要なら明示handoff packageを準備する。所有権移管はHumanまたはProject契約に
従う。詳細は[AvailabilityとRecovery](OPERATING_PROFILE.md#availabilityとrecovery)を正本とする。

## Machine-local secrets

- token、API key、password、credential実値をrepository、tracked settings、`.env.example`、fixtureへ保存しない。
- 個人token、固定home path、特定accountをtemplateの既定値にしない。
- secretの保存方式は一つに強制せず、利用runtimeのprocess environmentから参照可能であることだけを要件にする。
- 同一tokenの複数machine共有を必須にしない。machineごとに認証・失効・rotationを管理する。
- diagnostic、CI log、作業記録にはcredentialの有無または認証成否だけを残し、値を残さない。

## Multi-machine notes

repository canonical stateはmachine間で共有できるが、runtime installation、Trust acceptance、credential、OS
permission、scheduler environmentはmachine-localである。新しいmachineごとにInitial setupとpreflightを実行し、
別machineでの成功を認証済み・Trust済みの証拠にしない。

## Troubleshooting

1. `RUNTIME_READINESS_BLOCKED reason=workspace-root-mismatch`: `git rev-parse --show-toplevel`で対象rootを確認し、
   そのdirectoryへ`cd`して再実行する。
2. `claude=executable-unavailable`: 公式install手順でClaude Codeを導入し、shellの`PATH`を確認する。
3. `claude=auth-unavailable`: 同じuser・environmentで`claude auth status`を確認する。scheduled環境なら
   secret injectionとtoken expiryを確認し、必要なら`claude setup-token`で再発行する。
4. Trust promptが繰り返される: `$HOME`から起動していないか、実Project rootが変わっていないか、Claude version、
   Trust対象、設定破損を確認する。内部JSON fieldを直接変更しない。
5. 選択runtimeの起動または実行が失敗する: file / Git / output / external side effect / idempotencyを照合し、
   同じProvider内でrecoveryする。通常のtask failureや品質不足をProvider変更で隠さず既存self-repairへ戻す。
6. CodexまたはClaudeの仕様が本文と異なる: repositoryのworkaroundよりProvider公式文書を優先し、本書の
   current implementation部分だけを更新する。

## Verification

```bash
bash tools/setup-local-environment.sh
bash tools/setup-github-auth.sh --check --remote backup  # GitHub backup構成だけ
bash tools/check-runtime-readiness.sh --require-codex     # OpenAI主運用
bash tools/check-runtime-readiness.sh --require-claude    # Anthropic運用時
bash tools/validate-agent-directory.sh --strict --full
```

runtime readinessは利用するProviderごとに実行する。両方を導入していることを、一つのtaskでの分業やfallbackの
根拠にしない。
