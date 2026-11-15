# sbx-kit-claude-token

A [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) kit (schema 3, mixin). It gives one sandbox a Claude
subscription token of its own. Claude Code in that sandbox makes its model calls with this token. All other sandboxes
keep the global Claude login of sbx. The token stays on the Mac side of the sbx proxy. The VM holds only a
placeholder.

> [!WARNING]
> **Model calls only.** A token of `claude setup-token` has the one scope `user:inference`. In a sandbox with this
> kit, Claude Code has no artifacts, no claude.ai connectors (Slack, Atlassian and others) and no Claude in Chrome.
> Do not use the kit for a project that needs them.
>
> **The proxy sets the token on every request to `api.anthropic.com`,** also on a request of other code in the VM
> that brings a token of its own. All code in the sandbox can use the subscription.
>
> **Check the account** in the browser when you run `claude setup-token`. The token belongs to the account that the
> browser shows.

## Why a kit

sbx holds one Claude login for all sandboxes: the global service secret `anthropic`, an OAuth login. sbx allows an
OAuth secret in the global scope only. Probes with sbx v0.53.0 showed one way to give one sandbox another account:

| Approach | Result |
|---|---|
| A custom secret for the sandbox (`sbx secret set-custom --sandbox`) | The global login still wins |
| The service secret `anthropic` for the sandbox | Wins, but sbx sends it as an API key. A subscription token is a bearer |
| A kit credential of its own for `api.anthropic.com`, sent as a bearer | Works. This kit |

## What the kit does

| Part | What |
|---|---|
| Credential | The service `claude-subscription`. The proxy sets its value as `Authorization: Bearer` on each request to `api.anthropic.com` |
| Variable | `CLAUDE_CODE_OAUTH_TOKEN` in the VM holds the placeholder `proxy-managed`. Claude Code prefers this variable over the login file of the Claude kit |
| Network rule | A runtime allow rule for `api.anthropic.com`. sbx wants the inject domain in the kit's own rules; the Claude kit allows the host too |

The kit has no hook, no file and no arg.

## The token

1. On the Mac, make a token. It is valid for one year.

   ```bash
   claude setup-token
   ```

2. Store the token in a secret store. With gopass:

   ```bash
   gopass insert <path of the token>
   ```

Never put the token into a file of the project, into a kit or into the global scope of sbx.

## Use in a project file

```yaml
kits:
  - source: docker.io/docker/sbx-kit-claude:latest
  - source: git+https://github.com/<owner>/sbx-kit-claude-token.git
bindings:
  claude-subscription:
    apiKey:
      domains:
        - api.anthropic.com
secrets:
  claude-subscription:
    command: gopass show -o <path of the token>   # runs on the Mac, at the create
    snapshot: true                                # sbx reads the value one time
```

| Part | Why |
|---|---|
| `bindings` | The approval for the credential. sbx merges it into the global `~/.config/sbx/credentials.yaml`. Without it sbx does not inject the token ("no binding authorizes claude-subscription") |
| `secrets` | The source of the token. `sbx env create` shows the command and asks for approval. The secret is stored for this sandbox only |

Unlock the secret store before the create. After the create, test the account:

```bash
bash tests/live.sh <sandbox>
```

The test sends one request with no messages (no model call) and prints the organization id of the token. Give the
wanted id as a second argument, and the test compares.

## Behavior to know

| Case | What happens |
|---|---|
| No bound token (the store was locked, the `secrets` entry is missing) | `sbx env create` prints "required credential not found for service" and does **not** fail. In the sandbox, Claude Code says "401 Invalid bearer token". The global login is not in use |
| A new token | Create the sandbox again, or run `sbx secret set claude-subscription --sandbox <name>` |
| `sbx env rm` | Removes the secret of the sandbox. The next create reads the token again |
| `sbx env rm --prune-bindings` | Removes the approval for **every** sandbox with this kit. Do not use it |
| A direct request from the VM to `claude.ai`, `mcp-proxy.anthropic.com` or `console.anthropic.com` | The proxy still sets the global login there. Claude Code makes no such request with this token |

## The echo check

Anthropic's answer to a request with a bound marker holds the marker in no header and not in the body
(`tests/check.sh`, 2026-11-15). The check also finds the marker in no env variable, command line or file of the VM.

## The tests

```bash
bash tests/check.sh
```

The check needs the base image `sbx-stack-base` (run `build.sh` there first). It creates the sandbox
`check-claude-token`, asserts with no token and with a marker that is no secret, and removes the sandbox. It needs no
token and makes no model call. It stops when a global `claude-subscription` secret exists. `KEEP=1` leaves the sandbox
for a look after a failure.

`tests/live.sh` is the test with a real token (see above).

## License

MIT, see [LICENSE](LICENSE).
