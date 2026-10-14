import Foundation

/// Which secrets are alive right now (the lifetime table in briefs/P10.md; tests assert it state by state).
/// The Keychain bytes never appear here: they live in one local and are zeroed as soon as the key is derived.
struct GrokSecretLifetime: Sendable, Equatable {
    var derivedKey = false
    var credentials = false

    static let none = GrokSecretLifetime()
}

/// The one place a run's sign-in lives, in memory only (Rule 2): the three decrypted values while running or paused for
/// the network, and the derived key only while paused for an expired token, so Check again needs no second prompt.
/// A pause holds them for at most `hold` (continuous clock), then both are dropped; `forget()` drops them at once.
actor GrokSecretHolder {
    private var key: [UInt8] = []
    private var credentials: GrokCredentials?
    private var pausedSince: Duration?
    let hold: Duration
    let clock: any GrokClock

    init(hold: Duration = GrokProtocol.signInHold, clock: any GrokClock) {
        self.hold = hold
        self.clock = clock
    }

    var lifetime: GrokSecretLifetime { GrokSecretLifetime(derivedKey: !key.isEmpty, credentials: credentials != nil) }

    /// The credentials for building a client; nil when none are held (a new Keychain read is needed).
    func currentCredentials() -> GrokCredentials? {
        expireIfDue()
        return credentials
    }

    func store(_ credentials: GrokCredentials) {
        dropKey()
        self.credentials = credentials
        pausedSince = nil
    }

    /// Keeps a copy of the derived key for an expired-token pause; the caller zeroes its own copy.
    func holdKey(_ derived: [UInt8]) {
        dropKey()
        key = derived
        credentials = nil
    }

    /// Runs `body` with the held key (Check again). Nil when no key is held or the hold has run out.
    func withHeldKey<T: Sendable>(_ body: @Sendable ([UInt8]) throws -> T) rethrows -> T? {
        expireIfDue()
        guard !key.isEmpty else { return nil }
        return try body(key)
    }

    var hasHeldKey: Bool {
        expireIfDue()
        return !key.isEmpty
    }

    /// A pause starts the hold (a second pause, such as Check again finding the token still expired, keeps the first
    /// start, so the hold never stretches past `hold`); resuming the run (`store`) ends it.
    func pause() { if pausedSince == nil { pausedSince = clock.now() } }
    func resume() { pausedSince = nil }

    /// Drops everything once a pause has outlived its hold. Returns true when it did.
    @discardableResult func expireIfDue() -> Bool {
        guard let pausedSince, clock.now() - pausedSince >= hold, !key.isEmpty || credentials != nil else { return false }
        forget()
        return true
    }

    /// Finished, cancelled, failed, dismissed or "Forget sign-in": everything goes.
    func forget() {
        dropKey()
        credentials = nil
        pausedSince = nil
    }

    func dropCredentials() { credentials = nil }

    private func dropKey() {
        GrokSafeStorage.zero(&key)
        key = []
    }
}
