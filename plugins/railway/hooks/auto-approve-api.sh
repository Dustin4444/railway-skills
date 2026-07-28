#!/bin/bash
# Auto-approve railway-api.sh and railway CLI commands.
#
# An "allow" decision covers the WHOLE Bash command, so a prefix or substring
# match is not enough: `printf x # railway-api.sh` and `railway status; rm -rf ~`
# both start with (or contain) a trusted token yet run something else. We only
# approve when the command is a single simple invocation of the railway CLI or
# the railway-api.sh helper. Anything that chains, substitutes, redirects, or
# comments is left for the normal confirmation prompt — the safe direction.

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // empty')
command=$(echo "$input" | jq -r '.tool_input.command // empty')

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

approve() {
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "$1"
  }
}
EOF
  exit 0
}

# Command substitution and expansion fire even inside double quotes, so check the
# raw command for them before stripping anything. Legit GraphQL uses `$var`, not
# `$(`, backticks, or `${`.
case "$command" in
  *'$('* | *'`'* | *'${'*) exit 0 ;;
esac

# Build the shell skeleton: drop single- and double-quoted spans (the GraphQL
# query and JSON args live there) so only the shell structure is left. -0777
# slurps the whole command, so multi-line quoted args collapse away.
skeleton=$(printf '%s' "$command" | perl -0777 -pe "s/'[^']*'//g; s/\"[^\"]*\"//g" 2>/dev/null)
if [[ -z "$skeleton" && -n "$command" ]]; then
  # perl unavailable or failed — can't vet the command, so don't auto-approve.
  exit 0
fi

# On the skeleton every remaining metacharacter is top-level: command chaining
# (`;` `|` `&`), redirection or heredoc (`<` `>`), comments (`#`), or a newline
# joining two commands. Any of them means more than one simple command.
case "$skeleton" in
  *';'* | *'|'* | *'&'* | *'<'* | *'>'* | *'#'* | *$'\n'*) exit 0 ;;
esac

# Optional skill telemetry env prefixes, then the executable must BE the trusted
# program — railway-api.sh (optionally path-qualified) or the railway CLI.
env_prefix="^[[:space:]]*((RAILWAY_CALLER|RAILWAY_AGENT_SESSION|RAILWAY_SKILL_VERSION)=[^[:space:]]+[[:space:]]+)*"

if [[ "$skeleton" =~ ${env_prefix}([^[:space:]]*/)?railway-api\.sh([[:space:]]|$) ]]; then
  approve "Railway API call auto-approved"
fi

if [[ "$skeleton" =~ ${env_prefix}railway([[:space:]]|$) ]]; then
  approve "Railway CLI command auto-approved"
fi

exit 0
