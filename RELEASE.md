# Release Notes

## claude-code-npm-osv-hook

## Unreleased

This release broadens coverage beyond `npm` and makes failure handling
precise.

### Highlights

- Covers `npx`, `pnpm`, `yarn`, `bun`, and `bunx` in addition to `npm`, each
  scanned against the lockfile that tool actually resolves dependencies from
  (`package-lock.json`/`npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`,
  `bun.lock`).
- Catches commands behind bare environment-variable prefixes
  (`CI=true npm test`) and inside subshells (`(cd app && npm ci)`).
- Distinguishes osv-scanner outcomes by exit code: findings (exit 1) block
  with the vulnerability report, scanner errors (network, malformed lockfile)
  block with a distinct "scanner error, not a finding" message, and lockfiles
  with no packages (exit 128) are allowed instead of misreported as
  vulnerable.
- Filters osv-scanner's filesystem-walk noise out of deny messages.
- Verified against osv-scanner v2.x (`--lockfile` remains compatible).
- Expands the test suite from 7 to 16 cases, including per-tool lockfile
  routing and scanner-error paths.

## Previous release

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
