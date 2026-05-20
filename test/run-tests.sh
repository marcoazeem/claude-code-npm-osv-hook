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

make_fake_path() {
  dir=$1
  mode=$2
  mkdir -p "$dir/bin"
  ln -s "$jq_bin" "$dir/bin/jq"
  case "$mode" in
    pass)
      cat > "$dir/bin/osv-scanner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OSV_LOG"
exit 0
SH
      ;;
    fail)
      cat > "$dir/bin/osv-scanner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OSV_LOG"
printf 'fake vulnerability found\n' >&2
exit 1
SH
      ;;
    missing)
      ;;
    *)
      fail "unknown fake osv mode: $mode"
      ;;
  esac
  if [ -f "$dir/bin/osv-scanner" ]; then
    chmod +x "$dir/bin/osv-scanner"
  fi
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

tmp=$(new_tmp)
make_fake_path "$tmp" pass
output=$(cd "$tmp" && payload "echo npm install" | env OSV_LOG="$tmp/osv.log" PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$hook")
assert_empty "$output" "non-npm command with npm as argument"
[ ! -f "$tmp/osv.log" ] || fail "non-npm command should not run osv-scanner"
pass "ignores npm mentioned as an argument"

tmp=$(new_tmp)
make_fake_path "$tmp" missing
touch "$tmp/package-lock.json"
output=$(cd "$tmp" && payload "npm install" | env OSV_LOG="$tmp/osv.log" PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$hook")
assert_contains "$output" '"permissionDecision": "deny"' "missing osv-scanner"
assert_contains "$output" "osv-scanner is not installed" "missing osv-scanner"
pass "blocks npm when osv-scanner is missing"

tmp=$(new_tmp)
make_fake_path "$tmp" pass
output=$(cd "$tmp" && payload "npm install" | env OSV_LOG="$tmp/osv.log" PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$hook")
assert_empty "$output" "npm without lockfile"
[ ! -f "$tmp/osv.log" ] || fail "npm without lockfile should not run osv-scanner"
pass "allows npm when no package-lock.json exists"

tmp=$(new_tmp)
make_fake_path "$tmp" pass
touch "$tmp/package-lock.json"
output=$(cd "$tmp" && payload "npm ci" | env OSV_LOG="$tmp/osv.log" PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$hook")
assert_empty "$output" "clean scan"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/package-lock.json" "clean scan lockfile"
pass "scans the current package-lock.json"

tmp=$(new_tmp)
make_fake_path "$tmp" pass
mkdir -p "$tmp/app"
touch "$tmp/app/package-lock.json"
output=$(cd "$tmp" && payload "cd app && npm ci" | env OSV_LOG="$tmp/osv.log" PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$hook")
assert_empty "$output" "subdirectory scan"
assert_contains "$(cat "$tmp/osv.log")" "--lockfile=$tmp/app/package-lock.json" "subdirectory lockfile"
pass "scans package-lock.json from a simple cd target"

tmp=$(new_tmp)
make_fake_path "$tmp" fail
touch "$tmp/package-lock.json"
output=$(cd "$tmp" && payload "npm install" | env OSV_LOG="$tmp/osv.log" PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$hook")
assert_contains "$output" '"permissionDecision": "deny"' "failing scan"
assert_contains "$output" "fake vulnerability found" "failing scan"
pass "blocks npm when osv-scanner reports issues"

tmp=$(new_tmp)
output=$(payload "npm install" | env PATH="$tmp/bin" /bin/bash "$hook")
assert_contains "$output" '"permissionDecision":"deny"' "missing jq"
assert_contains "$output" "jq is not installed" "missing jq"
pass "blocks with a clear message when jq is missing"

printf '%s tests passed\n' "$pass_count"
