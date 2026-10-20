# SwarmHub shared core

Swift package using Foundation, SQLite and CryptoKit, shared by the desktop Hermes adapter and the native iOS application. The desktop adapter imports the extracted `HermesContent` encoder; the iOS client also uses the package's connection validation, domain types, stock Hermes session/stream/control APIs and actor-serialized SQLite cache.

Credentials are injected into a client rather than included in domain models or persisted snapshots. Platform UI, Keychain access, lifecycle handling and system sheets belong in the app targets. Android will reuse the wire contract and synthetic fixtures rather than import this Swift-only package.

```bash
swift test --package-path Packages/SwarmHubCore
./scripts/test-ios-core.sh  # adds the loopback real-HTTP fixture suite
```

The SSE byte decoder preserves blank event boundaries, multiline data, CRLF and split UTF-8. Stream EOF and `[DONE]` alone cannot imply a completed Hermes run; completed, cancelled and failed terminal events stay distinct.

SQLite currently persists transactional snapshots of profiles, chat history, drafts and interrupted turns. Paged local transcript queries and full-text search remain future work. `AgentClient` provides the boundary for stock Hermes and the app's explicit network-free demo client.

`UpdateVerifier.verify` implements the P0b verification order: local pins, root-signed key manifest, channel index and line selection, bundle manifest, then targeted compatible components and strict ustar rules. Ed25519 verification uses CryptoKit `Curve25519.Signing`; `JCS` implements the restricted canonical JSON profile in `docs/update-service/SCHEMAS.md`. Caller-supplied floors, time, consumer versions and limits are validated. Manifest/blob providers run only after earlier checks pass, and their errors propagate. The result contains the shared verdict and, on acceptance only, the verified manifest and blobs. The verifier performs no network or disk access, extraction, execution, persistence or apply decisions.

Run tests from a full repository checkout: `UpdateVerifierTests.swift` locates the unchanged P0a fixtures relative to its source file and reads every release and JCS vector. `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_update_vectors.py` checks that same catalogue against the P0b library on Linux; it does not execute Swift. P0c still requires both Mac commands above to pass. The app's `ManagedRemoteControlTests` require a separate Mac app-package test run (`swift test --filter ManagedRemoteControlTests`).
