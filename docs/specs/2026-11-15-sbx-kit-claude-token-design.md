# sbx-kit-claude-token: a Claude subscription token for one sandbox

Status: approved by the owner on 2026-11-15 (short design).

## Intent

sbx holds one Claude login for all sandboxes (the global service secret `anthropic`, an OAuth login). On the owner's
Mac that login is the account for one kind of project. A project of another kind must use another Claude
subscription. The kit gives
one sandbox a token of its own, and the global login stays for all other sandboxes.

## Goals, non-goals, anti-goals

- **Goal:** Claude Code in a sandbox with the kit makes its model calls with the token that the project file names.
- **Goal:** the VM holds only a placeholder. The token stays on the Mac side of the sbx proxy.
- **Goal:** a sandbox with the kit and no bound token does not use the global login.
- **Non-goal:** artifacts, claude.ai connectors and Claude in Chrome. A token of `claude setup-token` has the one
  scope `user:inference`, so Claude Code switches these parts off.
- **Non-goal:** a second OAuth login in sbx. sbx allows an OAuth secret in the global scope only.
- **Anti-goal:** a real token in the VM, in a kit, in a test or in a log.
- **Anti-goal:** a sandbox that falls back to the global login without a word.

## Approaches

Probes of 2026-11-15, sbx v0.53.0, each with a marker that is no secret:

| Approach | Result |
|---|---|
| A custom secret for the sandbox (`sbx secret set-custom --sandbox`) with `CLAUDE_CODE_OAUTH_TOKEN` | Fails. The proxy still sets the global login on each request to `api.anthropic.com` (the API answers 400 to a request with no messages, not 401) |
| The service secret `anthropic` for the sandbox (`sbx secret set anthropic --sandbox`) | Wins over the global login, but sbx sends it as `x-api-key` ("invalid x-api-key"). A subscription token is a bearer |
| **A kit credential of its own for `api.anthropic.com`, sent as `Authorization: Bearer`** | **Works, picked.** The marker reaches Anthropic ("OAuth access token is invalid"). With the owner's real token: a model call works, and the API names the owner's own organization |

## The design

1. **The kit** `sbx-kit-claude-token` (schema 3, mixin, descriptor `claude-token.yaml`, version 0.1.0). No recipe, no
   hook, no file.
   - `network-policy@2`: a runtime allow rule for `api.anthropic.com`. sbx refuses a credential whose inject domain
     is not in the kit's own rules. The Claude kit allows the host too.
   - `credential@1`: service `claude-subscription`, `optional: false`, `phase: runtime`, `apiKey` with
     `name: CLAUDE_CODE_OAUTH_TOKEN`, `proxyManaged: true` and one inject entry: domain `api.anthropic.com`, header
     `Authorization`, format `Bearer %s`.
2. **In the VM** the variable `CLAUDE_CODE_OAUTH_TOKEN` holds the placeholder `proxy-managed`. Claude Code prefers
   this variable over the credentials file of the Claude kit (`claude auth status`: `oauth_token`).
3. **The project file** of a private project names the kit, one approval entry and the source of the token:

   ```yaml
   bindings:
     claude-subscription:
       apiKey:
         domains:
           - api.anthropic.com
   secrets:
     claude-subscription:
       command: gopass show -o <path of the token>
       snapshot: true
   ```

   sbx merges the approval into the global `~/.config/sbx/credentials.yaml`. Without it sbx does not inject the
   credential ("no binding authorizes claude-subscription").
4. **No bound token:** the proxy sets nothing and does not use the global login. The API answers 401 ("Invalid
   bearer token"). `optional: false` makes `sbx env create` print "required credential not found for service". The
   create does not fail.
5. **The token** comes from `claude setup-token` on the Mac, with the browser logged in to the wanted account. It is
   valid for one year. The owner stores it in a secret store. `snapshot: true` reads it one time, at the create.

## Limits (the README names them)

- Model calls only: no artifacts, no claude.ai connectors, no Claude in Chrome.
- The proxy sets the token on **every** request to `api.anthropic.com`, also on a request of other code in the VM
  with a token of its own. The global login behaves the same way today.
- For other hosts of Anthropic (`claude.ai`, `mcp-proxy.anthropic.com`, `console.anthropic.com`) the global login
  stays in use for a direct request from the VM. Claude Code makes no such request with this token.
- `sbx env rm --prune-bindings` removes the approval for every sandbox.
- A new token needs a new create of the sandbox (or `sbx secret set claude-subscription --sandbox <name>`).

## The check

`tests/check.sh` creates `check-claude-token` on the base image, asserts in two phases, and removes the sandbox.

- **No token:** the placeholder is in the variable; `claude auth status` says `oauth_token`; a request to
  `https://api.anthropic.com/v1/messages` with no messages gets 401, with the placeholder and with a made-up bearer
  (a 400 means that the global login was in use); the create log has the "required credential" line. The same after
  a stop and a start.
- **Marker** `sk-ant-oat01-marker-not-a-secret-0000000000000000`, bound for `check-claude-token` only: the API
  answers 401 with "OAuth access token is invalid"; no response header or body holds the marker (the echo check);
  no env variable, command line or file of the VM holds it.
- The check stops first when a global `claude-subscription` secret exists. Its last assertions: no secret and no
  sandbox is left. It never uses `--prune-bindings`.

`tests/live.sh <sandbox> [<organization id>]` is the owner's test with a real token: a request with no messages (no
model call) gets 400, and the response header `anthropic-organization-id` is printed, or compared with the argument.

## Left to the builder

The wording of the README, the helper names of the check, and the rows for the kit-builder skill (`secrets.md`,
`lessons.md`; the lessons row on claude.ai connectors is out of date).
