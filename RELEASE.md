# Release Notes

## claude-code-npm-osv-hook

This release improves the reliability and documentation of the Claude Code
`PreToolUse` hook that blocks unsafe npm commands when `osv-scanner` reports
known issues in `package-lock.json`.

## Highlights

- Blocks clearly when required tools are missing, including both `jq` and
  `osv-scanner`.
- Avoids false positives such as `echo npm install`.
- Detects npm commands after common shell separators, including simple forms
  like `cd app && npm ci`.
- Scans the lockfile from the inferred npm working directory when possible.
- Reports the exact lockfile path in OSV failure messages.
- Updates the settings example to let the script handle npm filtering.
- Adds a shell smoke test suite covering allow, deny, dependency, and
  subdirectory behavior.
- Clarifies README security guarantees and caveats around first installs,
  brand-new packages, and known-vulnerability coverage.

## Verification

The release was verified with:

```sh
bash -n .claude/hooks/npm-osv-check.sh
bash -n test/run-tests.sh
test/run-tests.sh
```

Result:

```text
7 tests passed
```

## Notes

This hook is a lockfile safety gate, not a full npm sandbox. It is strongest for
`npm ci`, repeat installs, and commands run against an existing
`package-lock.json`. First-time installs are allowed when no lockfile exists,
and OSV can only block known issues that are already present in its advisory
data.
