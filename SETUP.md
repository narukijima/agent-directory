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
6. 設定済みGitHub HTTPS `backup` remoteがあるWorkspaceでは、通常taskを始める前に
   `bash tools/setup-github-auth.sh --install-from-gh --remote backup`、続けて
   `bash tools/setup-github-auth.sh --check --remote backup`を実行する。最後にprocess環境を引き継がない別shellで
   `bash tools/setup-github-auth.sh --machine-ready --remote backup`が合格することを確認する。GitHub remoteを使わないWorkspaceでは省略する。
7. 利用するProviderのruntimeを認証する。OpenAI主運用では
   `bash tools/check-runtime-readiness.sh --require-codex`、Anthropic運用では`--require-claude`を実行する。
8. `bash tools/validate-agent-directory.sh --strict --full`を実行する。

両Providerを同じmachineへ導入していても、一つのtaskに両方を必須にしない。明示的に両runtimeのmachine readinessを
監査するときだけ両flagを指定する。引数なしのpreflightは両runtimeをread-onlyで診断するが、runtime unavailable
だけでは非0にしない。

GitHub bootstrapは、有効な保存済み`gh`認証をmachine-local `github.env`へ安全に導入する非対話処理である。
`interactive-setup-required`なら、有効な保存済み認証がないため通常taskを開始せず、Operatorが専用setupとして
GitHub CLIの認証を完了してから同じ2コマンドを再実行する。Agentは通常task中にBrowser loginを開始しない。
設定済みGitHub HTTPS `backup`を持つWorkspaceでは、`tools/task.sh context`がnetwork接続前にmachine storeの
実在・権限・形式を検査する。process `GH_TOKEN`だけでは合格しないため、一つのAgentだけが成功して別Agentが
失敗する状態を通常task開始前に拒否する。これはcredentialの有効性probeではなくcross-process readiness gateである。

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

## Preflight checks

`tools/check-runtime-readiness.sh`はnetwork mutationを行わず、secret値を表示しないread-only diagnosticである。

```bash
bash tools/check-runtime-readiness.sh
bash tools/check-runtime-readiness.sh --require-codex
bash tools/check-runtime-readiness.sh --require-claude
```

次を確認する。

- cwdがこのAgent WorkspaceのGit rootそのものであること
- `codex` / `claude` executable availabilityとversion
- `codex login status` / `claude auth status`
- `CLAUDE_CODE_OAUTH_TOKEN`がprocess environmentに存在するか（値は表示しない）

成功時は`RUNTIME_READINESS`を1行で返す。required runtimeが利用不能なら診断行に続けて
`RUNTIME_READINESS_BLOCKED reason=<reason>`を返し、非0で終了する。これはavailabilityの観測であり、
taskのowner変更やfallback実行は行わない。

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
