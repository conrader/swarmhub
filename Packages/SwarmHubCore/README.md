# SwarmHub shared core

Foundation-only Swift package used by the desktop Hermes adapter and the native iOS application. The desktop adapter imports the extracted `HermesContent` encoder; the iOS client also uses the package's connection validation, domain types, stock Hermes session/stream/control APIs and actor-serialized SQLite cache.

Credentials are injected into a client rather than included in domain models or persisted snapshots. Platform UI, Keychain access, lifecycle handling and system sheets belong in the app targets. Android will reuse the wire contract and synthetic fixtures rather than import this Swift-only package.

```bash
swift test --package-path Packages/SwarmHubCore
./scripts/test-ios-core.sh  # adds the loopback real-HTTP fixture suite
```

The SSE byte decoder preserves blank event boundaries, multiline data, CRLF and split UTF-8. Stream EOF and `[DONE]` alone cannot imply a completed Hermes run; completed, cancelled and failed terminal events stay distinct.

SQLite currently persists transactional snapshots of profiles, chat history, drafts and interrupted turns. Paged local transcript queries and full-text search remain future work. `AgentClient` provides the boundary for stock Hermes and the app's explicit network-free demo client.
