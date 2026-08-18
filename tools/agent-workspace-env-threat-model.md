# Agent Workspace Environment Threat Model

## Scope

Agent固有の環境変数、secret、API token、外部サービス設定は、各Agent Workspace rootの`.env`だけが所有する。
OS home、machine共通store、Keychain、別Agent root、global process environmentを通常localの正本・fallbackにしない。
本書は`.env`の読取・更新、必要keyのTool限定利用、GitHub child processへのtoken注入を対象とする。

## Assets and boundaries

- **Agent `.env`** — そのAgentだけの環境変数正本。Git管理外、owner=current user、mode `0600`、no symlink、nlink=1。
- **`agent-env.sh`** — `.env`をsourceせず、要求されたkeyだけをread-before/read-after identity検査付きで返す。
- **Tool process** — 必要keyだけを保持し、値をstdout、stderr、argv、remote URL、tracked fileへ出さない。
- **Child process** — GitHub等の外部操作を所有する固定childだけへ該当tokenを一時注入する。
- **Sibling Agent** — 別Workspace rootと別`.env`を持ち、自動探索・共通store・fallbackで接続しない。

同じOS userで任意filesystem readを実行できる悪意あるprocessに対し、`0600`は絶対的な秘密境界ではない。
本設計の目的は、通常Toolが別Agentのcredentialを誤選択・上書き・共有する構造をなくし、所有者をWorkspace rootへ固定することにある。
敵対的workloadの分離はRuntime sandboxまたは別OS userが所有する。

## Invariants

1. Agent固有環境変数の正本は`<agent-root>/.env`だけである。
2. OS home、`~/.config`、machine共通file、Keychain、別Agent rootを探索しない。
3. `.env`をshell source、eval、command substitutionとして実行しない。
4. Toolは必要なkeyだけを読む。未知keyの値をコピー・表示・子processへ一括exportしない。
5. `.env`と`.env.*`実値はGitへcommitしない。共有可能なkey名と説明だけ`.env.example`へ置く。
6. 同じAgentのrotationは同じrootの`.env`だけをatomic updateし、別Agentのcredentialを変更しない。
7. CI process tokenは`CI=true`かつ明示的なrepository / operation一致時だけの例外である。

## Attack surfaces

| Surface | Boundary | Control |
|---|---|---|
| PAT stdin | Operator → setup Tool | 非表示入力、argv拒否、fine-grained形式検査 |
| Agent `.env` | Agent root → Tool | owner/mode/link/identity検査、非実行parse |
| dotenv content | file → parser | `KEY=VALUE`だけ、duplicate requested key拒否、未知keyは非利用 |
| Git remote | Agent → GitHub | exact GitHub URL、credential-free remote |
| authenticated child | Tool → Git/gh | hook/helper/global config/redirect隔離、必要tokenだけ注入 |
| CI environment | CI → Tool | explicit CI flags、exact repository / operation |

## Main risks

1. Agent rootを誤って解決し、別Agentの`.env`を読む。物理Git rootを引数として固定し、親・兄弟探索を禁止する。
2. `.env`へshell構文を入れて実行させる。parserはsourceせず、assignmentとしてだけ読む。
3. symlink/hardlink/raceでread/write対象を差し替える。owner、mode、link、identity、same-directory temporary file、atomic renameで低減する。
4. Git hookやambient credential helperがtokenを取得する。authenticated childでhook、helper、global/system config、redirectを遮断する。
5. Toolが全`.env`をexportし不要なsecretを子processへ渡す。key単位readerを唯一経路にする。
6. `.env`を誤commitする。root `.gitignore`、boundary scanner、validator fixtureで拒否する。
7. 同一OS userの悪意あるprocessが別rootを直接読む。通常Tool構造では防止し、敵対的分離はRuntime / OS boundaryへ委ねる。

## Verification

- 二つのfixture Workspaceへ異なるPATを置き、各resolverが自身のtokenだけを選ぶ。
- OS homeに旧machine storeを置いても読まない。
- ambient `GH_TOKEN`が存在しても通常localでは消費しない。
- missing、mode違反、symlink、hardlink、duplicate key、malformed dotenvを拒否する。
- setupが他keyを保持して`GH_TOKEN`だけをatomic replaceする。
- token値がdiagnostic、test output、Git remote、tracked fileへ出ない。
