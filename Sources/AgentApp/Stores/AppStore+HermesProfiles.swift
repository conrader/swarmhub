import Foundation

extension AppStore {
    var hermesConfigured: Bool { defaults.object(forKey: "hermesBaseURL") != nil || !keyStore.key(for: "hermes").isEmpty }
    /// Launch probes the global server only if its URL was set explicitly or a Hermes bot routes through it;
    /// bots with their own `hermesBaseURL` never make the unset default (`127.0.0.1:8642`) worth an alert.
    var launchProbesGlobalHermes: Bool {
        defaults.object(forKey: "hermesBaseURL") != nil || bots.contains { $0.backend == .hermes && $0.hermesBaseURL == nil }
    }

    var namedHermesProfiles: [String] {
        get { (defaults.string(forKey: "hermesProfiles") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        set {
            var seen: Set<String> = []
            defaults.set(newValue.filter { seen.insert($0).inserted }.joined(separator: ", "), forKey: "hermesProfiles")
        }
    }

    /// Probes the default and named profiles and adds one bot per available profile that has none yet.
    /// Idempotent; never removes bots. Profiles whose prefix the server ignored are never added.
    @discardableResult func refreshHermesAgents() async -> [HermesProfileProbe] {
        guard let baseURL = HermesBackend.validatedBaseURL(defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { errorMessage = BackendError.invalidURL.localizedDescription; return [] }
        let keyStore = keyStore
        let probes = await HermesBackend(baseURL: baseURL, apiKey: keyStore.key(for: "hermes"), session: hermesSession)
            .probeProfiles(named: namedHermesProfiles, keyFor: { keyStore.key(for: "hermes.\($0)") })
        for probe in probes {
            if probe.status == .prefixIgnored { prefixIgnoredHermesProfiles.insert(probe.id) }
            if case .available(let profile) = probe.status { prefixIgnoredHermesProfiles.remove(profile.id) }
        }
        appendAgents(from: probes)
        if let first = probes.first, first.id == "default", case .unavailable(let reason) = first.status { errorMessage = reason }
        if selectedBot == nil, selectedGroup == nil, selectedBoxProfile == nil { selectVisibleChat() }
        save()
        return probes
    }

    /// "Add bots from box": stores each pasted key in the key store as `hermes.<profile>`, adds the
    /// profile to the named list, runs discovery and reports one result per pasted entry.
    func addBotsFromBox(_ text: String) async -> [HermesBotAddResult] {
        let parsed = HermesKeyPaste.parse(text)
        var results = parsed.invalid.map { HermesBotAddResult(label: $0.label, outcome: .rejected($0.reason)) }
        guard !parsed.entries.isEmpty else { return results }
        for entry in parsed.entries { keyStore.setKey(entry.key, for: "hermes.\(entry.profile)") }
        namedHermesProfiles += parsed.entries.map(\.profile)
        typedKeyProfiles.formUnion(parsed.entries.map(\.profile))
        // A Grok-imported history-only bot takes its pasted profile first, so discovery adds no second bot for it.
        bindUnboundGrokBots()
        let present = Set(bots.filter { $0.backend == .hermes }.map { $0.hermesProfile ?? "default" })
        let probes = await refreshHermesAgents()
        for entry in parsed.entries {
            let outcome: HermesBotAddResult.Outcome
            switch probes.first(where: { $0.id == entry.profile })?.status {
            case .available(let profile): outcome = present.contains(profile.id) ? .alreadyPresent : .added(profile.name)
            case .some(let status): outcome = .rejected(status.reason ?? "Unavailable.")
            case nil: outcome = .rejected("Not checked: \(BackendError.invalidURL.localizedDescription)")
            }
            results.append(.init(label: entry.profile, outcome: outcome))
        }
        return results
    }

    /// The profile an imported template binds to: `grok-<slug>` or `<slug>` when a key exists for it.
    func hermesProfile(forTemplateSlug slug: String?) -> String? {
        guard hermesConfigured, let slug, HermesKeyPaste.isValidProfileName(slug) else { return nil }
        return ["grok-\(slug)", slug].first { $0 != "default" && !prefixIgnoredHermesProfiles.contains($0) && !keyStore.key(for: "hermes.\($0)").isEmpty }
    }

    func makeImportPlan(from manifest: ImportedTemplateManifest) -> TemplateImportPlan {
        TemplateImportMapper.makePlan(from: manifest, hermesConfigured: hermesConfigured, hermesProfile: hermesProfile(forTemplateSlug: manifest.slug))
    }
}
