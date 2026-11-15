#!/usr/bin/env bash
# Creates the sandbox check-claude-token from tests/sbxenv.yaml and asserts with sbx exec in two phases (no token,
# then a marker that is no secret). A second sandbox, check-claude-token-nobind, proves the case of a bound value
# with no approval. The check removes both sandboxes. It needs no token and makes no model call.
# Run build.sh in sbx-stack-base first.
# The single-quoted check commands expand in the sandbox's shell, not here.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
name=check-claude-token
service=claude-subscription
env_file=$repo/tests/sbxenv.yaml
ws=$repo/tests/ws
# The phase with no approval uses a copy of the kit with a service name of its own. So the check never touches the
# approval of the real service in ~/.config/sbx/credentials.yaml, which other sandboxes use.
nb_name=check-claude-token-nobind
nb_service=claude-subscription-check-nobind
nb_dir=$repo/tests/nobind
credentials=$HOME/.config/sbx/credentials.yaml
# The marker stands in for a token. It is not a secret. It has the form of a subscription token, so that Anthropic
# answers with its text for such a token. The check binds it for its own sandboxes only. In the sandbox the check
# searches with marker_re, so that no command line there holds the marker.
marker=sk-ant-oat01-marker-not-a-secret-0000000000000000
marker_re='sk-ant-oat01-marker-not-a-secret-[0]000000000000000'
# The control proves that the search for the marker can find a value at all.
control=sbx-control-not-a-secret-1111111111111111
fails=0
in_vm=$name
# The check sets "reported" before each exit that it explains itself. Every other exit with a failure is a step that
# is no assertion (set -e stops the check there): cleanup then prints the FAIL line.
reported=

# api <bearer> runs in the sandbox: one request to the Messages API with no messages, so Anthropic makes no model
# call. With a valid login the answer is 400, with no valid login it is 401. The headers go to /tmp/h, the body to
# /tmp/b, the status to /tmp/s. A response of Anthropic has the header request-id. A refusal of the sbx proxy has not.
api_fn='api() {
  curl -sS -m 30 -D /tmp/h -o /tmp/b -w "%{http_code}\n" -X POST -H "authorization: Bearer $1" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    -d "{\"model\":\"claude-haiku-5-5\",\"max_tokens\":1}" https://api.anthropic.com/v1/messages >/tmp/s \
    && grep -qi "^request-id:" /tmp/h
}'
# Anthropic's answers (401) to a bearer: "Invalid bearer token" to the placeholder and to a made-up value, "OAuth
# access token is invalid" to a value with the form of a subscription token. To a wrong API key: "invalid x-api-key".
# An answer 400 means a valid login: the proxy then set the global login of sbx on the request.
not_sent='[ "$(cat /tmp/s)" = 401 ] && grep -q "Invalid bearer token" /tmp/b'

# The check reads "nothing there" from a listing of sbx. A failing sbx must never look like an empty listing: the two
# functions below return 2 then, and "no" takes only the status 1 as "not there".

# has_secret <scope> [<service>]: sbx has a secret of the service in the scope ("(global)" or a sandbox name)
has_secret() {
  local out
  out=$(sbx secret ls) || return 2
  awk -v scope="$1" -v service="${2:-$service}" \
    '$1 == scope && $2 == "service" && $3 == service { found = 1 } END { exit !found }' <<<"$out"
}

# listed <regex> <sbx arguments...>: a line of the sbx listing matches the extended regular expression
listed() {
  local re=$1 out
  shift
  out=$(sbx "$@") || return 2
  grep -qE "$re" <<<"$out"
}

# no <function> <arguments...>: the function says "not there"
no() {
  local status=0
  "$@" || status=$?
  [ "$status" -eq 1 ]
}

remove_all() {
  sbx secret rm "$service" --sandbox "$name" -f >/dev/null 2>&1 || true
  # Never with --prune-bindings: the approval of the service is in use by other sandboxes.
  sbx env rm --force --no-input --name "$name" "$env_file" >/dev/null 2>&1 || true
  sbx secret rm "$nb_service" --sandbox "$nb_name" -f >/dev/null 2>&1 || true
  [ ! -f "$nb_dir/sbxenv.yaml" ] ||
    sbx env rm --force --no-input --name "$nb_name" "$nb_dir/sbxenv.yaml" >/dev/null 2>&1 || true
  rm -rf "$ws" "$nb_dir"
}

cleanup() {
  local status=$?
  # set -e can stop the check inside a group whose output goes to the log. So the report goes to the saved stdout.
  if [ "$status" -ne 0 ] && [ -z "$reported" ]; then
    {
      echo "FAIL the check stopped at a step that is no assertion (exit $status)"
      echo "--- the last lines of the log ---"
      tail -30 "$log"
    } >&3 2>&1
  fi
  # KEEP=1 leaves the sandboxes, the marker and the workspaces for a look after a failure.
  [ -n "${KEEP:-}" ] || remove_all
  rm -f "$log" "$create_log"
}

pass() { echo "PASS $1"; }

fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}

# check <what> <sh script>: the script runs in the sandbox that in_vm names
check() {
  if sbx exec "$in_vm" sh -c "$api_fn; $2" >>"$log" 2>&1; then
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

# The apt hosts are the base image's. The log must hold the check's own requests to api.anthropic.com: a failed or
# empty log would look like "nothing blocked".
no_other_blocked_host() {
  local json hosts
  json=$(sbx policy log "$name" --json) || return 1
  jq -e 'any(.allowed[]?; .host == "api.anthropic.com:443")' <<<"$json" >/dev/null || {
    echo "the policy log does not hold the check's own requests"
    return 1
  }
  hosts=$(jq -r '(.blocked // [])[].host' <<<"$json") || return 1
  hosts=$(sort -u <<<"$hosts" | grep -vxE '(deb\.debian\.org|dhi\.io):80' || true)
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
  check "with no token, the proxy sets nothing: the global login is not in use$s" \
    "api \"\${CLAUDE_CODE_OAUTH_TOKEN:-none}\" && $not_sent"
  check "with no token, a made-up bearer gets the same answer$s" "api made-up-not-a-token && $not_sent"
}

# as_bearer <what> <bearer>: Anthropic got the bound value as a subscription token, and sent no part of it back.
as_bearer() {
  check "$1" "api $2 && [ \"\$(cat /tmp/s)\" = 401 ] && grep -q 'OAuth access token is invalid' /tmp/b \
    && ! grep -qE '$marker_re' /tmp/h /tmp/b"
}

# The three searches of the VM. Each prints a sh command that is true when the extended regular expression matches.
# Without sudo the searches would find nothing and so prove nothing: the control assertions catch that.
in_env() { printf "%s\n" "sudo -n sh -c 'cat /proc/[0-9]*/environ 2>/dev/null' | tr '\\0' '\\n' | grep -qE '$1'"; }
in_cmdline() { printf "%s\n" "sudo -n sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null' | tr '\\0' '\\n' | grep -qE '$1'"; }
in_files() {
  printf "%s\n" "sudo -n grep -rlsaE '$1' /etc /tmp /run /var/log /root /home/agent/.config /home/agent/.claude \
    /home/agent/.claude.json | grep -q ."
}

searches() {
  # One process holds the control in its env and in its command line, one file of root holds it.
  local plant="printf %s $control | sudo -n tee /root/sbx-check-control >/dev/null; \
    CONTROL=$control sh -c 'sleep 20' $control >/dev/null 2>&1 & sleep 1"
  check "the search finds a control value in an env variable" "$plant; $(in_env "$control")"
  check "the search finds a control value in a command line" "$plant; $(in_cmdline "$control")"
  check "the search finds a control value in a file of root" "$plant; $(in_files "$control")"
  check "no env variable of a process holds the bound value" "! $(in_env "$marker_re")"
  check "no command line of a process holds the bound value" "! $(in_cmdline "$marker_re")"
  check "no file in the VM holds the bound value" "! $(in_files "$marker_re")"
}

marker_phase() {
  printf '%s' "$marker" | sbx secret set "$service" --sandbox "$name" -f >>"$log" 2>&1
  restart

  mac "the marker is bound to $name" has_secret "$name"
  as_bearer "the bound value reaches Anthropic as a bearer, and no response holds it" '"$CLAUDE_CODE_OAUTH_TOKEN"'
  as_bearer "the proxy replaces a bearer that code in the VM brings itself" made-up-not-a-token
  searches
}

no_approval() { ! grep -qs "$nb_service" "$credentials"; }

# A bound value with no approval (no bindings entry): sbx must send nothing, and must not use the global login.
no_approval_phase() {
  rm -rf "$nb_dir"
  mkdir -p "$nb_dir/kit" "$nb_dir/ws"
  sed "s/service: $service\$/service: $nb_service/" "$repo/claude-token.yaml" >"$nb_dir/kit/claude-token.yaml"
  sed -e '/^# The approval/,/^        - api\.anthropic\.com$/d' -e 's|source: \.\.$|source: ./kit|' "$env_file" \
    >"$nb_dir/sbxenv.yaml"
  mac "the kit copy has the service name of this phase" grep -q "service: $nb_service\$" "$nb_dir/kit/claude-token.yaml"
  mac "the project file of this phase has no approval entry" bash -c "! grep -q bindings '$nb_dir/sbxenv.yaml'"
  mac "no approval for the service of this phase exists before the create" no_approval

  printf '%s' "$marker" | sbx secret set "$nb_service" --sandbox "$nb_name" -f >>"$log" 2>&1
  if ! sbx env create --force --no-input --name "$nb_name" "$nb_dir/sbxenv.yaml" >"$create_log" 2>&1; then
    cat "$create_log" >>"$log"
    fail "create $nb_name"
    return
  fi
  cat "$create_log" >>"$log"
  mac "the marker is bound to $nb_name" has_secret "$nb_name" "$nb_service"
  mac "the create says that the approval is missing" grep -q 'no binding authorizes' "$create_log"
  in_vm=$nb_name
  check "with a bound value and no approval, the proxy sets nothing: the global login is not in use" \
    "api \"\${CLAUDE_CODE_OAUTH_TOKEN:-none}\" && $not_sent"
  in_vm=$name
  mac "the create stored no approval for the service of this phase" no_approval
}

# The guard runs before the trap and before every other sbx command. When it stops the check, the cleanup has nothing
# to undo, and no command of the check touched a secret.
global=0
has_secret "(global)" || global=$?
case $global in
  0)
    echo "A global $service secret is stored in sbx. The check binds a marker as the $service secret of one sandbox"
    echo "and must not meet a real one. Remove the global secret, or do not run this check."
    exit 1
    ;;
  1) ;;
  *)
    echo "FAIL sbx secret ls does not run: the check cannot see whether a global $service secret exists"
    exit 1
    ;;
esac

log=$(mktemp)
create_log=$(mktemp)
exec 3>&1
trap cleanup EXIT

if no has_secret "(global)" anthropic; then
  echo "NOTE sbx has no global anthropic login: this run cannot show that the kit wins over such a login"
fi

mac "the kit is valid" sbx kit validate "$repo"

# A marker that an earlier run with KEEP=1 left would make the phase with no token a phase with a bound value.
sbx secret rm "$service" --sandbox "$name" -f >/dev/null 2>&1 || true
rm -rf "$ws"
mkdir -p "$ws"

if ! sbx env create --force --no-input --name "$name" "$env_file" >"$create_log" 2>&1; then
  tail -20 "$create_log"
  echo "FAIL create $name"
  reported=1
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
no_approval_phase

if [ -z "${KEEP:-}" ]; then
  remove_all
  mac "no secret is left for the two sandboxes" no listed "^($name|$nb_name) " secret ls
  # The pattern has no end: it also finds a marker of the second sandbox's service in the global scope.
  mac "no global $service secret exists" no listed "^\(global\) +service +$service" secret ls
  mac "the two sandboxes are gone" no listed "^($name|$nb_name) " ls
fi

if [ "$fails" -gt 0 ]; then
  echo "--- the last lines of the log ---"
  tail -30 "$log"
  echo "$fails failed"
  reported=1
  exit 1
fi
echo "all passed"
