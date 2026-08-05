#!/bin/bash
# The payloads below are shell source held as data, so the metacharacters and
# backslashes in them are deliberately literal and must not be rewritten.
# shellcheck disable=SC1003,SC2016
#
# Regression tests for auto-approve-api.sh. Run: bash auto-approve-api.test.sh
#
# The hook's invariant is that it never returns "allow" for a command bash would
# run as more than one simple command. Each case below pins one reading of shell
# quoting where a check that is not character-exact about bash's rules would let
# a top-level `;` through as if it were quoted data.

hook="$(dirname "$0")/auto-approve-api.sh"
pass=0
fail=0

# Feeds a command to the hook and echoes "allow" or "prompt". Declining to decide
# is silence on stdout, which is what leaves the command at the normal prompt.
decision() {
  local out
  out=$(printf '%s' "$1" |
    jq -Rs '{tool_name: "Bash", tool_input: {command: .}}' |
    bash "$hook")
  if [[ -z "$out" ]]; then
    echo prompt
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "prompt"'
  fi
}

check() {
  local want="$1" desc="$2" cmd="$3" got
  got=$(decision "$cmd")
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  ok       %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf '  FAILED   %s (wanted %s, got %s)\n' "$desc" "$want" "$got"
  fi
}

echo "Commands bash runs as more than one command — must prompt:"
check prompt 'escaped double quote'          'railway \" ; touch pwned ; echo \"'
check prompt 'escaped single quote'          "railway \\' ; touch pwned ; echo \\'"
check prompt 'escaped quote, api.sh branch'  'railway-api.sh \" ; touch pwned ; echo \"'
check prompt 'escaped quote, env prefix'     'RAILWAY_CALLER=x railway \" ; touch pwned ; echo \"'
check prompt 'single quote inside double'    'railway "a'"'"'b" ; touch pwned ; echo '"'"'c"d'"'"''
check prompt 'double quote inside single'    "railway 'a\"b' ; touch pwned ; echo \"c'd\""
check prompt 'trailing comment'              'touch pwned # railway-api.sh'
check prompt 'command chaining'              'railway status; touch pwned'
check prompt 'command substitution'          'railway status $(touch pwned)'
check prompt 'pipeline'                      'railway status | touch pwned'
check prompt 'redirection'                   'railway status > pwned'
check prompt 'newline between commands'      'railway status
touch pwned'
check prompt 'subshell'                      '(railway status; touch pwned)'
check prompt 'brace group'                   '{ railway status; touch pwned; }'
check prompt 'unterminated quote'            'railway " ; touch pwned'
check prompt 'trailing lone backslash'       'railway \'

echo
echo "Documented call forms — must auto-approve:"
check allow 'bare CLI'                       'railway status'
check allow 'CLI with flags'                  'railway status --json'
check allow 'quoted query and variables'      "scripts/railway-api.sh 'query { me { id } }' '{}'"
check allow 'double quotes inside argument'   "scripts/railway-api.sh 'query { project(id: \"abc\") { id } }' '{}'"
check allow 'telemetry env prefix'            'RAILWAY_CALLER=skill RAILWAY_SKILL_VERSION=1 railway status'
check allow 'escaped space in argument'       'railway variables --set FOO=a\ b'
check allow 'line continuation' "scripts/railway-api.sh \\
  'query getEnv(\$id: String!) { environment(id: \$id) { name } }' \\
  '{\"id\": \"env-uuid\"}'"
check allow 'multi-line quoted query' "scripts/railway-api.sh \\
  'query {
    me { id }
  }' \\
  '{}'"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
