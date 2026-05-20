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

# Read the hook payload and bail out unless the bash command actually runs
# `npm`. We can't fully rely on the settings.json `if` matcher because some
# Claude Code versions ignore it for command-type hooks.
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
# Match `npm` at start, or after `&&`, `||`, `;`, `|`, or whitespace. This
# catches `npm install`, `cd foo && npm ci`, etc., without matching `npmjs`
# in a URL or `npm-check` (a different tool).
if ! printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])npm($|[[:space:]])'; then
  exit 0
fi

if ! command -v osv-scanner >/dev/null 2>&1; then
  deny "osv-scanner is not installed. Install with: brew install osv-scanner"
fi

if [ ! -f package-lock.json ]; then
  # First-time install (no lockfile yet) — let npm run; future invocations
  # will scan the lockfile it produces.
  exit 0
fi

if out=$(osv-scanner --lockfile=package-lock.json 2>&1); then
  exit 0
fi

deny "osv-scanner found issues in package-lock.json. Blocking npm command.

$out

Re-run \`osv-scanner --lockfile package-lock.json\` for full details. If you've reviewed the finding and want to proceed, temporarily disable this hook in .claude/settings.local.json."
