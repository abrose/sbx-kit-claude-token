#!/usr/bin/env bash
# Creates the sandbox check-claude-token from tests/sbxenv.yaml, asserts with sbx exec in two phases (no token, then
# a marker that is no secret), and removes the sandbox. It needs no token and makes no model call.
# Run build.sh in sbx-stack-base first.
# The single-quoted check commands expand in the sandbox's shell, not here.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
name=check-claude-token
service=claude-subscription
env_file=$repo/tests/sbxenv.yaml
ws=$repo/tests/ws
# The marker stands in for a token in the second phase. It is not a secret. It has the form of a subscription token,
# so that Anthropic answers with its text for such a token. The check binds it for the sandbox check-claude-token
# only. In the sandbox the check searches with marker_re, so that no command line there holds the marker.
marker=sk-ant-oat01-marker-not-a-secret-0000000000000000
marker_re='sk-ant-oat01-marker-not-a-secret-[0]000000000000000'
log=$(mktemp)
create_log=$(mktemp)
fails=0

# api <bearer> runs in the sandbox: one request to the Messages API with no messages, so Anthropic makes no model
# call. With a valid login the answer is 400, with no valid login it is 401. The headers go to /tmp/h, the body to
# /tmp/b, the status to /tmp/s. A response of Anthropic has the header request-id. A refusal of the sbx proxy has not.
api_fn='api() {
  curl -sS -m 30 -D /tmp/h -o /tmp/b -w "%{http_code}\n" -X POST -H "authorization: Bearer $1" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    -d "{\"model\":\"claude-haiku-5-5\",\"max_tokens\":1}" https://api.anthropic.com/v1/messages >/tmp/s \
    && grep -qi "^request-id:" /tmp/h
}'

# has_secret <scope>: sbx has a secret of the kit's service in the scope ("(global)" or a sandbox name)
has_secret() {
  sbx secret ls 2>/dev/null | awk -v scope="$1" -v service="$service" \
    '$1 == scope && $2 == "service" && $3 == service { found = 1 } END { exit !found }'
}

remove_all() {
  sbx secret rm "$service" --sandbox "$name" -f >/dev/null 2>&1 || true
  # Never with --prune-bindings: the approval of the service is in use by other sandboxes.
  sbx env rm --force --no-input --name "$name" "$env_file" >/dev/null 2>&1 || true
  rm -rf "$ws"
}

cleanup() {
  # KEEP=1 leaves the sandbox, the marker and the workspace for a look after a failure.
  [ -n "${KEEP:-}" ] || remove_all
  rm -f "$log" "$create_log"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }

fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}

# check <what> <sh script>: the script runs in the sandbox
check() {
  if sbx exec "$name" sh -c "$api_fn; $2" >>"$log" 2>&1; then
    pass "$1"
  else
    fail "$1"
  fi
}

# mac <what> <command...>: the command runs on the Mac
mac() {
  local what=$1
  shift
  if "$@" >>"$log" 2>&1; then
    pass "$what"
  else
    fail "$what"
  fi
}

restart() {
  {
    sbx stop "$name"
    sbx exec "$name" true
  } >>"$log" 2>&1
}

# The apt hosts are the base image's.
no_other_blocked_host() {
  local hosts
  hosts=$(sbx policy log "$name" --json | jq -r '.blocked[].host' | sort -u |
    grep -vxE '(deb\.debian\.org|dhi\.io):80' || true)
  [ -z "$hosts" ] || {
    echo "blocked:"
    echo "$hosts"
    return 1
  }
}

no_token_phase() {
  local s=$1
  check "the variable holds the placeholder of sbx$s" '[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = proxy-managed ]'
  check "Claude Code uses the token of the variable$s" \
    'claude auth status 2>&1 | grep -q "\"authMethod\": \"oauth_token\""'
  # A 400 means that the proxy set the global login of sbx on the request.
  check "with no token, the global login is not in use: Anthropic answers 401$s" \
    'api "${CLAUDE_CODE_OAUTH_TOKEN:-none}" && [ "$(cat /tmp/s)" = 401 ]'
  check "with no token, a made-up bearer gets 401 too$s" 'api made-up-not-a-token && [ "$(cat /tmp/s)" = 401 ]'
}

# as_bearer <what> <bearer>: Anthropic got the bound value as a subscription token, and sent no part of it back.
# "OAuth access token is invalid" is its answer to a bearer with the form of a subscription token. Its answer to
# another bearer is "Invalid bearer token", and to a wrong API key "invalid x-api-key".
as_bearer() {
  check "$1" "api $2 && [ \"\$(cat /tmp/s)\" = 401 ] && grep -q 'OAuth access token is invalid' /tmp/b \
    && ! grep -qE '$marker_re' /tmp/h /tmp/b"
}

marker_phase() {
  printf '%s' "$marker" | sbx secret set "$service" --sandbox "$name" -f >>"$log" 2>&1
  restart

  mac "the marker is bound to $name" has_secret "$name"
  as_bearer "the bound value reaches Anthropic as a bearer, and no response holds it" '"$CLAUDE_CODE_OAUTH_TOKEN"'
  as_bearer "the proxy replaces a bearer that code in the VM brings itself" made-up-not-a-token
  check "no env variable of a process holds the bound value" \
    "! sudo -n sh -c 'cat /proc/[0-9]*/environ 2>/dev/null' | tr '\\0' '\\n' | grep -qE '$marker_re'"
  check "no command line of a process holds the bound value" \
    "! sudo -n sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null' | tr '\\0' '\\n' | grep -qE '$marker_re'"
  check "no file in the VM holds the bound value" \
    "! sudo -n grep -rIlsE '$marker_re' /etc /tmp /run /var/log /root /home/agent/.config /home/agent/.claude \
      /home/agent/.claude.json | grep -q ."
}

if has_secret "(global)"; then
  echo "A global $service secret is stored in sbx. The check binds a marker as the $service secret of one sandbox"
  echo "and must not meet a real one. Remove the global secret, or do not run this check."
  exit 1
fi

mac "the kit is valid" sbx kit validate "$repo"

# A marker that an earlier run with KEEP=1 left would make the phase with no token a phase with a bound value.
sbx secret rm "$service" --sandbox "$name" -f >/dev/null 2>&1 || true
rm -rf "$ws"
mkdir -p "$ws"

if ! sbx env create --force --no-input --name "$name" "$env_file" >"$create_log" 2>&1; then
  tail -20 "$create_log"
  echo "FAIL create $name"
  exit 1
fi
cat "$create_log" >>"$log"

check "the sandbox runs on the base image" 'test -f /usr/local/share/sbx-stack/VERSION'
mac "the create says that the token is missing" grep -q 'required credential not found' "$create_log"
no_token_phase ""
restart
no_token_phase " (after stop and start)"
marker_phase
mac "the proxy blocked no other host" no_other_blocked_host

if [ -z "${KEEP:-}" ]; then
  remove_all
  mac "no secret is left for $name" bash -c "! sbx secret ls | grep -q '^$name '"
  mac "no global $service secret exists" bash -c "! sbx secret ls | grep -qE '^\(global\) +service +$service'"
  mac "the sandbox $name is gone" bash -c "! sbx ls | grep -q '^$name '"
fi

if [ "$fails" -gt 0 ]; then
  echo "--- the last lines of the log ---"
  tail -30 "$log"
  echo "$fails failed"
  exit 1
fi
echo "all passed"
