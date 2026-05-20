#!/usr/bin/env bash
# PreToolUse hook: scan package-lock.json with osv-scanner before any `npm`
# command runs. Blocks if osv-scanner is missing or finds vulnerabilities.

set -u

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"jq is not installed. Install jq so the npm OSV hook can parse Claude Code hook input safely."}}'
  exit 0
fi

# Read the hook payload and bail out unless the bash command actually runs
# `npm`. We keep this guard because some Claude Code versions ignore `if` for
# command-type hooks.
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')

# Split common shell command separators onto new lines. This intentionally
# avoids treating "echo npm install" as an npm invocation.
npm_segment=$(
  printf '%s' "$cmd" |
    sed -E 's/[[:space:]]*(&&|\|\||;|\|)[[:space:]]*/\
/g' |
    awk '
      {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line ~ /^(env[[:space:]]+[^[:space:]=]+=[^[:space:]]+[[:space:]]+)*npm([[:space:]]|$)/) {
          print line
          exit
        }
      }
    '
)

if [ -z "$npm_segment" ]; then
  exit 0
fi

if ! command -v osv-scanner >/dev/null 2>&1; then
  deny "osv-scanner is not installed. Install with: brew install osv-scanner"
fi

workdir=$(pwd)

# Handle the common `cd dir && npm ...` form so monorepo users scan the
# lockfile npm will actually use. More complex shell flows fall back to cwd.
cd_target=$(
  printf '%s' "$cmd" |
    sed -E 's/[[:space:]]*(&&|\|\||;|\|)[[:space:]]*/\
/g' |
    awk '
      {
        line=$0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line ~ /^cd[[:space:]]+/) {
          sub(/^cd[[:space:]]+/, "", line)
          sub(/[[:space:]]+$/, "", line)
          gsub(/^"|"$/, "", line)
          gsub(/^'\''|'\''$/, "", line)
          print line
        }
        if (line ~ /^(env[[:space:]]+[^[:space:]=]+=[^[:space:]]+[[:space:]]+)*npm([[:space:]]|$)/) {
          exit
        }
      }
    ' |
    tail -n 1
)

if [ -n "$cd_target" ]; then
  case "$cd_target" in
    /*) candidate_dir=$cd_target ;;
    *) candidate_dir=$workdir/$cd_target ;;
  esac
  if [ -d "$candidate_dir" ]; then
    workdir=$candidate_dir
  fi
fi

lockfile=$workdir/package-lock.json

if [ ! -f "$lockfile" ]; then
  # First-time install (no lockfile yet) — let npm run; future invocations
  # will scan the lockfile it produces.
  exit 0
fi

if out=$(osv-scanner --lockfile="$lockfile" 2>&1); then
  exit 0
fi

deny "osv-scanner found issues in $lockfile. Blocking npm command.

$out

Re-run \`osv-scanner --lockfile \"$lockfile\"\` for full details. If you've reviewed the finding and want to proceed, temporarily disable this hook in .claude/settings.local.json."
