#!/usr/bin/env bash
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/.claude/hooks/npm-osv-check.sh"
jq_bin=$(command -v jq)

pass_count=0
tmp_dirs=""

cleanup() {
  for dir in $tmp_dirs; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

new_tmp() {
  dir=$(mktemp -d)
  tmp_dirs="$tmp_dirs $dir"
  printf '%s\n' "$dir"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %s - %s\n' "$pass_count" "$1"
}

payload() {
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | "$jq_bin" -Rs .)"
}

# make_fake_path <dir> <mode> — mode is "missing" or the exit code the fake
# osv-scanner should return (0 clean, 1 findings, 127 error, 128 no packages).
make_fake_path() {
  dir=$1
  mode=$2
  mkdir -p "$dir/bin"
  ln -s "$jq_bin" "$dir/bin/jq"
  if [ "$mode" != missing ]; then
    cat > "$dir/bin/osv-scanner" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$OSV_LOG"
if [ "$mode" -eq 1 ]; then
  printf 'fake vulnerability found\n' >&2
elif [ "$mode" -ne 0 ] && [ "$mode" -ne 128 ]; then
  printf 'fake scanner failure\n' >&2
fi
exit $mode
SH
    chmod +x "$dir/bin/osv-scanner"
  fi
}

run_hook() {
  dir=$1
  shift
  (cd "$dir" && payload "$1" | env OSV_LOG="$dir/osv.log" PATH="$dir/bin:/usr/bin:/bin" /bin/bash "$hook")
}

assert_empty() {
  [ -z "$1" ] || fail "$2: expected empty output, got: $1"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: expected to find '$2' in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3: expected NOT to find '$2' in: $1" ;;
  esac
}

tmp=$(new_tmp)
make_fake_path "$tmp" 0
output=$(run_hook "$tmp" "echo npm install")
assert_empty "$output" "non-npm command with npm as argument"
[ ! -f "$tmp/osv.log" ] || fail "non-npm command should not run osv-scanner"
pass "ignores npm mentioned as an argument"

tmp=$(new_tmp)
make_fake_path "$tmp" missing
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "npm install")
assert_contains "$output" '"permissionDecision": "deny"' "missing osv-scanner"
assert_contains "$output" "osv-scanner is not installed" "missing osv-scanner"
pass "blocks npm when osv-scanner is missing"

tmp=$(new_tmp)
make_fake_path "$tmp" 0
output=$(run_hook "$tmp" "npm install")
assert_empty "$output" "npm without lockfile"
[ ! -f "$tmp/osv.log" ] || fail "npm without lockfile should not run osv-scanner"
pass "allows npm when no package-lock.json exists"

tmp=$(new_tmp)
make_fake_path "$tmp" 0
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "npm ci")
assert_empty "$output" "clean scan"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/package-lock.json" "clean scan lockfile"
pass "scans the current package-lock.json"

tmp=$(new_tmp)
make_fake_path "$tmp" 0
mkdir -p "$tmp/app"
touch "$tmp/app/package-lock.json"
output=$(run_hook "$tmp" "cd app && npm ci")
assert_empty "$output" "subdirectory scan"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/app/package-lock.json" "subdirectory lockfile"
pass "scans package-lock.json from a simple cd target"

tmp=$(new_tmp)
make_fake_path "$tmp" 0
mkdir -p "$tmp/app"
touch "$tmp/app/package-lock.json"
output=$(run_hook "$tmp" "(cd app && npm ci)")
assert_empty "$output" "subshell scan"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/app/package-lock.json" "subshell lockfile"
pass "scans package-lock.json from a subshell cd target"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "npm install")
assert_contains "$output" '"permissionDecision": "deny"' "failing scan"
assert_contains "$output" "fake vulnerability found" "failing scan"
assert_contains "$output" "found known vulnerabilities" "failing scan message"
pass "blocks npm when osv-scanner reports issues"

tmp=$(new_tmp)
make_fake_path "$tmp" 127
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "npm install")
assert_contains "$output" '"permissionDecision": "deny"' "scanner error"
assert_contains "$output" "scanner error, not a vulnerability finding" "scanner error"
assert_not_contains "$output" "found known vulnerabilities" "scanner error"
pass "blocks with a distinct message when osv-scanner itself fails"

tmp=$(new_tmp)
make_fake_path "$tmp" 128
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "npm install")
assert_empty "$output" "empty lockfile"
pass "allows npm when the lockfile has no packages (exit 128)"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "CI=true npm test")
assert_contains "$output" '"permissionDecision": "deny"' "env-var prefix"
pass "catches npm behind a VAR=value prefix"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/package-lock.json"
output=$(run_hook "$tmp" "npx create-react-app my-app")
assert_contains "$output" '"permissionDecision": "deny"' "npx"
pass "covers npx against package-lock.json"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/yarn.lock"
output=$(run_hook "$tmp" "yarn install")
assert_contains "$output" '"permissionDecision": "deny"' "yarn"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/yarn.lock" "yarn lockfile"
pass "covers yarn against yarn.lock"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/pnpm-lock.yaml"
output=$(run_hook "$tmp" "pnpm install")
assert_contains "$output" '"permissionDecision": "deny"' "pnpm"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/pnpm-lock.yaml" "pnpm lockfile"
pass "covers pnpm against pnpm-lock.yaml"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/bun.lock"
output=$(run_hook "$tmp" "bun install")
assert_contains "$output" '"permissionDecision": "deny"' "bun"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/bun.lock" "bun lockfile"
pass "covers bun against bun.lock"

tmp=$(new_tmp)
make_fake_path "$tmp" 1
touch "$tmp/yarn.lock"
output=$(run_hook "$tmp" "npm install")
assert_empty "$output" "wrong-tool lockfile"
[ ! -f "$tmp/osv.log" ] || fail "npm should not scan yarn.lock"
pass "npm ignores lockfiles belonging to other package managers"

tmp=$(new_tmp)
output=$(payload "npm install" | env PATH="$tmp/bin" /bin/bash "$hook")
assert_contains "$output" '"permissionDecision":"deny"' "missing jq"
assert_contains "$output" "jq is not installed" "missing jq"
pass "blocks with a clear message when jq is missing"

printf '%s tests passed\n' "$pass_count"
