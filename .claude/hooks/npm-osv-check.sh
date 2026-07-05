#!/usr/bin/env bash
# PreToolUse hook: scan the relevant lockfile with osv-scanner before any
# npm/npx/pnpm/yarn/bun command runs. Blocks if osv-scanner is missing,
# fails, or finds vulnerabilities.

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

# Read the hook payload and bail out unless the bash command actually runs a
# package-manager binary. We keep this guard because some Claude Code versions
# ignore `if` for command-type hooks.
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')

# Split common shell command separators onto new lines, then find the first
# segment whose command word (after `env` and VAR=val prefixes) is one of the
# package managers. Also track the last `cd <dir>` seen before it, so
# `cd app && npm ci` scans the lockfile npm will actually use. This
# intentionally avoids treating "echo npm install" as an npm invocation.
match=$(
  printf '%s' "$cmd" |
    sed -E 's/[[:space:]]*(&&|\|\||;|\|)[[:space:]]*/\
/g' |
    awk '
      {
        line=$0
        sub(/^[[:space:](]+/, "", line)
        sub(/[[:space:])]+$/, "", line)
        if (line ~ /^cd[[:space:]]+[^[:space:]]/) {
          t=line
          sub(/^cd[[:space:]]+/, "", t)
          sub(/[[:space:]]+$/, "", t)
          gsub(/^"|"$/, "", t)
          gsub(/^'\''|'\''$/, "", t)
          cdt=t
        }
        work=line
        sub(/^env[[:space:]]+/, "", work)
        while (work ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/)
          sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", work)
        split(work, w, /[[:space:]]+/)
        if (w[1] == "npm" || w[1] == "npx" || w[1] == "pnpm" ||
            w[1] == "yarn" || w[1] == "bun" || w[1] == "bunx") {
          printf "%s\t%s\n", w[1], cdt
          exit
        }
      }
    '
)

if [ -z "$match" ]; then
  exit 0
fi

tab=$(printf '\t')
tool=${match%%"$tab"*}
cd_target=${match#*"$tab"}

if ! command -v osv-scanner >/dev/null 2>&1; then
  deny "osv-scanner is not installed. Install with: brew install osv-scanner"
fi

workdir=$(pwd)

if [ -n "$cd_target" ]; then
  case "$cd_target" in
    /*) candidate_dir=$cd_target ;;
    *) candidate_dir=$workdir/$cd_target ;;
  esac
  if [ -d "$candidate_dir" ]; then
    workdir=$candidate_dir
  fi
fi

# Scan the lockfile(s) the invoked tool actually resolves dependencies from.
case "$tool" in
  npm|npx)  lockfile_names="package-lock.json npm-shrinkwrap.json" ;;
  pnpm)     lockfile_names="pnpm-lock.yaml" ;;
  yarn)     lockfile_names="yarn.lock" ;;
  bun|bunx) lockfile_names="bun.lock" ;;
esac

for name in $lockfile_names; do
  lockfile=$workdir/$name
  if [ ! -f "$lockfile" ]; then
    # First-time install (no lockfile yet) — let the tool run; future
    # invocations will scan the lockfile it produces.
    continue
  fi

  out=$(osv-scanner --lockfile="$lockfile" 2>&1)
  status=$?
  out=$(printf '%s\n' "$out" | grep -vE '^(Starting filesystem walk for root:|End status:)')

  case $status in
    0)
      # Clean scan.
      ;;
    128)
      # No packages in the lockfile — nothing to flag.
      ;;
    1)
      deny "osv-scanner found known vulnerabilities in $lockfile. Blocking $tool command.

$out

Re-run \`osv-scanner --lockfile \"$lockfile\"\` for full details. If you've reviewed the finding and want to proceed, temporarily disable this hook in .claude/settings.local.json."
      ;;
    *)
      deny "osv-scanner failed while scanning $lockfile (exit $status), so the $tool command was blocked as a precaution.

$out

This is a scanner error, not a vulnerability finding. Fix the scanner problem (or temporarily disable this hook in .claude/settings.local.json) and retry."
      ;;
  esac
done

exit 0
