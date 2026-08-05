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
  *\$\(* | *\`* | *\$\{*) exit 0 ;;
esac

# Build the shell skeleton by dropping everything bash treats as literal data —
# quoted spans and backslash-escaped characters — leaving only the characters
# where bash's metacharacters actually operate. Tracking bash's quoting state
# character by character is the whole point: `\"` is a literal to bash though it
# looks like a delimiter, and a quote of one type inside a span of the other
# closes nothing, so any reading that disagrees with bash on where a quoted span
# begins and ends will hide a top-level `;` behind what it mistakes for data.
skeleton=""
state=unquoted
i=0
len=${#command}
while ((i < len)); do
  char=${command:i:1}
  case "$state" in
    unquoted)
      case "$char" in
        \\)
          # Escapes whatever follows, so that character is data rather than
          # structure — and `\<newline>` is a line continuation. A backslash with
          # nothing after it doesn't parse; don't approve what we can't read.
          ((i + 1 < len)) || exit 0
          ((i++))
          ;;
        "'") state=single ;;
        '"') state=double ;;
        *) skeleton+="$char" ;;
      esac
      ;;
    single)
      # Backslash is not special inside single quotes: the span ends at the next `'`.
      [[ "$char" == "'" ]] && state=unquoted
      ;;
    double)
      case "$char" in
        \\)
          ((i + 1 < len)) || exit 0
          ((i++))
          ;;
        '"') state=unquoted ;;
      esac
      ;;
  esac
  ((i++))
done

# An unterminated quote means the command does not parse the way we just read it.
[[ "$state" == unquoted ]] || exit 0

# On the skeleton every remaining metacharacter is top-level: command chaining
# (`;` `|` `&`), redirection or heredoc (`<` `>`), comments (`#`), grouping or
# subshells (`(` `)` `{` `}`), or a newline joining two commands. Any of them
# means more than one simple command.
case "$skeleton" in
  *';'* | *'|'* | *'&'* | *'<'* | *'>'* | *'#'* | *'('* | *')'* | *'{'* | *'}'* | *$'\n'*) exit 0 ;;
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
