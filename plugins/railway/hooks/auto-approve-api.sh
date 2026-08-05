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
cwd=$(echo "$input" | jq -r '.cwd // empty')

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

# Drop the optional skill telemetry env prefixes to reach the executable itself.
env_assignment="^[[:space:]]*(RAILWAY_CALLER|RAILWAY_AGENT_SESSION|RAILWAY_SKILL_VERSION)=[^[:space:]]+[[:space:]]+(.*)$"
remainder=$skeleton
while [[ "$remainder" =~ $env_assignment ]]; do
  remainder=${BASH_REMATCH[2]}
done
remainder=${remainder#"${remainder%%[![:space:]]*}"}
executable=${remainder%%[[:space:]]*}

# Resolve a path the way the command would, so the comparison below is about the
# file that will run rather than the spelling used to reach it. Symlinks and `..`
# in the directory part collapse; a directory that doesn't exist fails outright.
canonical_path() {
  local path=$1 dir
  if [[ "$path" != /* ]]; then
    [[ -n "$cwd" ]] || return 1
    path="$cwd/$path"
  fi
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$dir" "$(basename "$path")"
}

# The helper this hook vouches for is the one shipped beside it, so locate it
# from the hook's own path rather than trusting the name in the command. A file
# is only that helper if it resolves to the same path; the name alone says
# nothing about which file it is, and anything a repo or temp directory can
# supply is not this plugin's script.
if [[ "$executable" == *railway-api.sh ]]; then
  hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
  helper=$(canonical_path "$hook_dir/../skills/use-railway/scripts/railway-api.sh") || exit 0
  [[ -f "$helper" ]] || exit 0
  invoked=$(canonical_path "$executable") || exit 0
  if [[ "$invoked" == "$helper" ]]; then
    approve "Railway API call auto-approved"
  fi
  exit 0
fi

# The railway CLI is resolved from PATH by name, so require exactly that name —
# a path-qualified `railway` is some other file and gets the normal prompt.
if [[ "$executable" == "railway" ]]; then
  approve "Railway CLI command auto-approved"
fi

exit 0
