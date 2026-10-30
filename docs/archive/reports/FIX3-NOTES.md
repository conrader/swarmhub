# Template import FIX3 notes

## Changed

- Moved validated Basic-auth redaction ahead of the generic secret-value patterns, so `Authorization: Basic <base64 user:pass>` is removed before the authorization pattern can split it.
- Added a regression test using `Authorization: Basic c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz` and asserting the base64 marker is absent from preview instructions, the imported bot persona, and the saved `store.json`.
- Kept the existing bare `Basic <base64>` coverage. No LOW review findings were changed.

## Verification

- `./scripts/build.sh`: passed via the repository's direct Xcode 16.2 compiler fallback (`docs/template-import-fix3-build.log`).
- Direct Swift 6 production-module emission and complete test-target type-check: passed (`docs/template-import-fix3-test-typecheck.log`).
- `swift build` and `swift test`: both attempted and both blocked before compilation by the host Xcode/CoreDevice `_XPCTypeBool` loader failure, exit 72 (`docs/template-import-fix3-swift-build.log`, `docs/template-import-fix3-swift-test.log`). The unit tests did not execute on this host.
- `git diff --check`: passed.
- Package command: passed (`docs/template-import-fix3-package.log`). Nothing was installed.

## Package

- Path: `dist/AgentApp-9617dcffe179-dirty-arm64.zip`
- SHA-256: `6d85abd53374a553c903b25c8501101d6595d09fd7ef215242e95594db47f51f`

No files were staged or committed.
