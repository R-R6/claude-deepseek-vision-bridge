# macOS Verification Handoff

## Scope

This change is on `codex/merge-macos-adaptation`. It repairs two macOS recovery paths discovered during the pre-merge review:

- The installed `~/.claude/bridge/reinstall-vision-bridge.sh` must be self-contained rather than depending on the original repository checkout.
- `launchctl` reload and rollback must tolerate the observed bootout/bootstrap race and report a failed restoration explicitly.

Windows runtime, CC Switch provider records, user environment variables, and API credentials are outside this change.

## Changed Files

- `src/macos/install-vision-bridge.sh`
  - Supports both repository and installed-bundle layouts.
  - Installs the installer and its minimal runtime inputs into the bridge bundle.
  - Retries bootstrap/kickstart up to five times and confirms the LaunchAgent is loaded.
  - Reports restoration failure instead of silently treating it as a healthy rollback.
- `src/macos/restart-vision-bridge.sh`
  - Applies the same bounded launchctl retry and loaded-state confirmation to restart and rollback.
- `test/macos-smoke-test.js`
  - Covers installed-bundle reinstall and injected bootstrap failures during install and restart rollback.

## Verification Status Before Handoff

Passed on Windows:

- `npm.cmd run check`
- `node test/bridge-smoke-test.js`
- POSIX shell syntax checks using WSL with CRLF handled in the pipeline
- `git diff --check`

Not verified on a real macOS host:

- `npm test` macOS smoke execution
- Installed-bundle reinstall against a real LaunchAgent
- launchctl recovery behavior on the target macOS version

The macOS smoke test intentionally skips on Windows. Do not report this change as macOS-verified until the following checks pass on a Mac.

## Mac Test Procedure

Run from the repository checkout on `codex/merge-macos-adaptation` after confirming the expected commit.

```sh
git status --short --branch
git rev-parse HEAD
npm run check
npm test
```

Then verify the installed reinstaller. This uses the existing bridge configuration and may briefly restart the local bridge, but must not change a CC Switch route:

```sh
sh "$HOME/.claude/bridge/reinstall-vision-bridge.sh"
sh "$HOME/.claude/bridge/diagnose-vision-bridge.sh"
```

Confirm the bridge and LaunchAgent are healthy:

```sh
curl --fail --silent --show-error http://127.0.0.1:15720/health
launchctl print "gui/$(id -u)/com.claude.deepseek-vision-bridge"
```

If CC Switch is part of the local setup, also confirm its provider target remains unchanged and test one text request followed by one pasted-image request. Do not print API keys, bridge tokens, or provider configuration contents.

## Expected Result

- `npm test` passes on macOS.
- The installed reinstaller completes without needing the original repository path.
- Bridge health returns `ok=true` after reinstall.
- A transient launchctl bootstrap failure is retried or reported as a restoration failure, never silently claimed as a successful rollback.
- Existing CC Switch routing and credentials remain untouched.
