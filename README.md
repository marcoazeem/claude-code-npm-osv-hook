# claude-code-npm-osv-hook

A [Claude Code](https://claude.com/claude-code) `PreToolUse` hook that scans
`package-lock.json` with [osv-scanner](https://google.github.io/osv-scanner/)
before Claude Code runs an `npm` command. If OSV reports known malware,
supply-chain compromises, or vulnerable package versions in the lockfile, the
npm command is **blocked** and the findings surface inline. If required tools
are missing, the command is blocked with install instructions.

## Why

Recent npm supply-chain attacks have shipped malicious code through
compromised maintainer accounts on widely-used packages. By the time you
notice "weird" install output, the postinstall script has already run.
Running OSV against the lockfile before `npm install`, `npm ci`, or any
`npm run …` catches known-bad versions already present in the lockfile before
code executes.

OSV pulls from the GitHub Advisory Database, which receives malware
disclosures for npm.

## Install

```sh
# 1. Install osv-scanner
brew install osv-scanner
# (or see https://google.github.io/osv-scanner/installation/ for other platforms)

# 2. Make sure jq is installed
brew install jq

# 3. Drop the .claude/ folder into the root of your project
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/marcoazeem/claude-code-npm-osv-hook/main/.claude/hooks/npm-osv-check.sh \
  -o .claude/hooks/npm-osv-check.sh
chmod +x .claude/hooks/npm-osv-check.sh

# 4. Merge the hook entry into .claude/settings.local.json
#    (or .claude/settings.json if you want it team-wide).
#    See settings.example.json for the snippet.
```

Or just clone and copy:

```sh
git clone https://github.com/marcoazeem/claude-code-npm-osv-hook
cp -r claude-code-npm-osv-hook/.claude/hooks /path/to/your/project/.claude/
# then merge .claude/settings.example.json into your settings
```

After installing, open `/hooks` in Claude Code once (or restart the session)
so the settings watcher picks up the new file. After that, every `npm …`
command Claude tries to run will trigger the scan first.

## Files

```
.claude/
├── hooks/
│   └── npm-osv-check.sh    # the scanner script
└── settings.example.json   # the hook entry — merge into your settings.json
```

## Behavior

| Situation | Outcome |
|---|---|
| `osv-scanner` not installed | npm blocked with install message |
| No `package-lock.json` (first install) | npm allowed — there's nothing to scan yet |
| osv-scanner finds zero issues | npm allowed (silent) |
| osv-scanner finds issues | npm blocked, findings surfaced in the deny reason |

The settings example runs the hook for Bash tool calls, and the script exits
immediately unless it finds a command segment that starts with `npm` (including
simple forms like `cd app && npm ci`). `git`, `ls`, `node`, and `echo npm
install` are unaffected.

## Manual override

If you've reviewed a finding and want to proceed anyway, comment out the
`hooks.PreToolUse` block in `.claude/settings.local.json` (or remove the
file). Reverse the change when you're done. Or, since the hook only blocks
inside Claude Code, you can run the npm command yourself in a terminal.

## Caveats

- The scan adds a second or two to every npm invocation. If that's too
  slow, you can add a narrower matcher, but doing so may miss commands such as
  `cd app && npm ci`.
- `npx`, `pnpm`, `yarn` aren't covered — only `npm`. Extend the matcher if
  you use those.
- OSV catches **known** issues. A true zero-day supply-chain attack won't
  be in the database yet. This is a safety net, not a guarantee.
- First-time installs are allowed when no `package-lock.json` exists, because
  there is no lockfile to scan yet.
- Installing a brand-new package may introduce versions that were not in the
  lockfile before the command started. This hook is strongest for `npm ci`,
  repeat installs, and commands run against an existing lockfile.
- The hook handles simple `cd app && npm ...` commands and scans that
  directory's lockfile. More complex shell flows fall back to the current
  working directory.

## Test

```sh
chmod +x test/run-tests.sh
test/run-tests.sh
```

## Project settings vs local settings

- `.claude/settings.local.json` — gitignored, personal to you.
- `.claude/settings.json` — checked into the repo, applies to everyone on
  the team.

Move the `hooks` block into `.claude/settings.json` if you want the whole
team to get the scan (and have them install osv-scanner).

## License

MIT — see [LICENSE](./LICENSE).
