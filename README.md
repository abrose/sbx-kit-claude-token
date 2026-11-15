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
    command: /opt/homebrew/bin/gopass show -o <path of the token>   # runs on the Mac, at the create
    snapshot: true                                                  # sbx reads the value one time
```

| Part | Why |
|---|---|
| `bindings` | The approval for the credential. sbx merges it into the global `~/.config/sbx/credentials.yaml`. Without it sbx does not inject the token ("no binding authorizes claude-subscription") |
| `secrets` | The source of the token. `sbx env create` shows the command and asks for approval. The secret is stored for this sandbox only |
| The absolute path in `command` | sbx runs the command on the Mac, in a new temporary folder. Name the program by its absolute path (`command -v gopass` prints it), so that the `PATH` of the shell does not choose the program that gives the token. gopass is one choice, not a dependency |

`kit.allowedSources` in the sbx settings must allow the source of the kit.

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
| A bound token and no approval (the `bindings` entry is missing or pruned) | `sbx env create` prints "no binding authorizes" and does **not** fail. The proxy sends no token: the same 401. The global login is not in use |
| A new token | Create the sandbox again. Or run `sbx secret set claude-subscription --sandbox <name>`, then stop and start the sandbox |
| `sbx env rm` | Removes the secret of the sandbox. The next create reads the token again |
| `sbx env rm --prune-bindings` | Removes the approval for **every** sandbox with this kit: they all get the 401 until a create stores the approval again. Do not use it |
| A direct request from the VM to `claude.ai`, `mcp-proxy.anthropic.com` or `console.anthropic.com` | The proxy still sets the global login there. Claude Code makes no such request with this token |

## The echo check

Anthropic's answer to a request with a bound marker holds the marker in no header and not in the body
(`tests/check.sh`, 2026-11-15). The check also finds the marker in no env variable, command line or file of the VM.

Not probed: a request of other code in the VM with an `x-api-key` header, and a valid bearer of other code in a
sandbox with no bound token.

## The tests

```bash
bash tests/check.sh
```

The check needs the base image `sbx-stack-base` (run `build.sh` there first). It needs no token and makes no model
call. It stops, before it changes anything, when a global `claude-subscription` secret exists or when `sbx secret ls`
fails. A failing `sbx` listing is a FAIL, never "nothing there". `KEEP=1` leaves the sandboxes for a look after a
failure.

| Sandbox | What the check asserts |
|---|---|
| `check-claude-token` | With no token: the placeholder, and "Invalid bearer token" from Anthropic. With a marker that is no secret: Anthropic gets it as a bearer, and the VM holds it nowhere. Control values prove that the search of the VM works |
| `check-claude-token-nobind` | A copy of the kit with a service name of its own, a bound marker and no approval: "Invalid bearer token" from Anthropic |

The check removes both sandboxes and their markers. It leaves one thing on the Mac: the approval `claude-subscription`
in `~/.config/sbx/credentials.yaml`, which each sandbox with this kit needs.

`tests/live.sh` is the test with a real token (see above).

## License

MIT, see [LICENSE](LICENSE).
