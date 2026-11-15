#!/usr/bin/env bash
# The test with a real bound token, for the owner of the token: does the sandbox use the wanted Claude account?
# It sends one request to the Messages API with no messages, so Anthropic makes no model call. It prints the
# organization id that Anthropic names for the token, and no other header.
# The single-quoted check commands expand in the sandbox's shell, not here.
# shellcheck disable=SC2016
set -euo pipefail

usage() {
  echo "usage: live.sh <sandbox> [<organization id>]" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
name=$1
want=${2:-}
log=$(mktemp)
trap 'rm -f "$log"' EXIT
fails=0

pass() { echo "PASS $1"; }

fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}

# check <what> <sh script>: the script runs in the sandbox
check() {
  if sbx exec "$name" sh -c "$2" >>"$log" 2>&1; then
    pass "$1"
  else
    fail "$1"
  fi
}

check "the variable holds the placeholder of sbx" '[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = proxy-managed ]'
check "Claude Code uses the token of the variable" \
  'claude auth status 2>&1 | grep -q "\"authMethod\": \"oauth_token\""'
# 400: Anthropic takes the token and refuses the request with no messages. 401: no token is bound, or it is not valid.
check "Anthropic takes the bound token" \
  'curl -sS -m 30 -D /tmp/h -o /tmp/b -w "%{http_code}\n" -X POST \
    -H "authorization: Bearer ${CLAUDE_CODE_OAUTH_TOKEN:-none}" -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    -d "{\"model\":\"claude-haiku-5-5\",\"max_tokens\":1}" https://api.anthropic.com/v1/messages >/tmp/s \
    && [ "$(cat /tmp/s)" = 400 ]'

# The headers in /tmp/h are new only when the request check passed. After a failure the file can be an old one.
org=
if [ "$fails" -eq 0 ]; then
  org=$(sbx exec "$name" sh -c 'grep -i "^anthropic-organization-id:" /tmp/h' 2>>"$log" | tr -d '\r' |
    cut -d' ' -f2) || true
fi
if [ "$fails" -gt 0 ]; then
  echo "SKIP the organization of the token: a check before it failed"
elif [ -z "$org" ]; then
  fail "Anthropic names the organization of the token"
elif [ -z "$want" ]; then
  pass "Anthropic names the organization of the token: $org"
elif [ "$org" = "$want" ]; then
  pass "the token belongs to the wanted organization"
else
  fail "the token belongs to the organization $org, not to the wanted one"
fi

if [ "$fails" -gt 0 ]; then
  echo "--- the last lines of the log ---"
  tail -20 "$log"
  echo "$fails failed"
  exit 1
fi
echo "all passed"
