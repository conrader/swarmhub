# P6c — Stable code signing so Keychain keys survive rebuilds; then live check

Read `PLAN.md`; standing constraints apply. Start from `main`. Branch `p6c`.
Problem (P6b): ad-hoc signing makes every rebuild a different app to the Keychain, so keys stored by one build are
unreadable by the next without a GUI prompt. There is an "Apple Development" identity in the login keychain
(team A75C74DCN3).

1. `scripts/package-release.sh`: sign the executable and the bundle with the first valid "Apple Development" identity
   from `security find-identity -v -p codesigning` (override with env `TORVLI_SIGN_IDENTITY`), identifier
   `com.konrad.agentapp`; fall back to ad-hoc with a clear warning if none. Keep `codesign --verify --strict`.
   Record the signing identity's team id (not the cert) in SOURCE.txt. If codesign needs the login keychain unlocked and
   it is locked, stop and report — do not fall back silently.
2. Package and reinstall `~/Applications/Torvli.app` (same backup rule as P6). Check `codesign -dv` shows TeamIdentifier.
3. Remove the 17 old Keychain items stored by the ad-hoc build, by account name only, without reading them:
   `security delete-generic-password -s com.konrad.agentapp.backends -a <account>` for `hermes` and each
   `hermes.grok-*` account the app lists. If deletion would prompt, stop and report.
4. A fresh key file `~/.torvli-keys.import` (0600) is placed by the orchestrator before this run. Import it with the
   installed (stably signed) binary: `--import-keys`. Report profile names + OK only; confirm the file is gone.
5. Prove stability: make a trivial rebuild (e.g. bump `CFBundleVersion` build number), package and reinstall again, then
   run `--check-bots` with the NEW binary. Expect 16 lines all `key: present`, models match, no Keychain prompt.
6. Then `--chat "Jarvis" "Reply with exactly: Torvli OK"` (one real message, allowed once). Report the reply's first
   200 characters and the session id.
7. Build + `swift test` green; commit on `p6c` (author Konrad Sierzputowski <konrad@dmt.zone>); no push.
   Report: sha, totals, codesign -dv summary (identifier, team, no cert data), full `--check-bots` output, chat result.
