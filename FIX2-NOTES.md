# Template import FIX2 notes

## Completed

- Private-key redaction now removes a complete PEM/PGP private-key block, including its multi-line body and matching `END` line. An unterminated block is removed through end of text.
- Because sanitization still happens once before mapping, the same cleaned value feeds the preview, `store.json`, and the Hermes system persona/SOUL.
- Added regression coverage with a realistic three-line fake PGP key body across the preview model, saved bot/store, and Hermes persona, plus an unterminated RSA private-key case.
- Basic auth is redacted only when the candidate decodes as a `user:credential` value; ordinary prose such as “basic troubleshooting” remains unchanged.
- The preview heading is now “Instructions”, and its Hermes profile report row is omitted when Hermes is not configured.

## Verification

- `swift build`: attempted; blocked before compilation by the host Xcode/CoreDevice `_XPCTypeBool` loader failure (exit 72). See `docs/template-import-fix2-swift-build.log`.
- `./scripts/build.sh`: passed with the repository's direct Xcode 16.2 compiler fallback. See `docs/template-import-fix2-build.log`.
- `swift test`: attempted; blocked by the same host loader failure (exit 72). See `docs/template-import-fix2-swift-test.log`.
- Direct Swift 6 production-module emission and complete test-target type-check: passed. See `docs/template-import-fix2-test-typecheck.log`.
- Standalone Foundation regex smoke check: terminated PGP and unterminated RSA sample bodies were both fully removed.
- `git diff --check`: passed.

No repository files were staged or committed, and no external Hermes server was used.
