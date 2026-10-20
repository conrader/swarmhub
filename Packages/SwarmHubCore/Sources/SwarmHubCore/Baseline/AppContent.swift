import Foundation

/// The app's launch-time content resolution, shared by Mac and iOS. P2c has no fetch client or persisted fetched
/// store yet. That future store must return verified content; absence or a read/fetch failure retains the baseline.
/// Archives are held as data only. Config interpretation is P6; box code is never consumed by this path.
public struct AppContent: Sendable, Equatable {
    public enum Target: String, Sendable { case mac, ios }

    public let target: Target
    public let baseline: EmbeddedBaseline?
    public let archives: [String: Data]

    private init(target: Target, baseline: EmbeddedBaseline?, archives: [String: Data]) {
        self.target = target
        self.baseline = baseline
        self.archives = archives
    }

    public static func resolve(in bundle: Bundle = .main, target: Target,
                               fetchedStore: () throws -> AppContent? = { nil }) -> AppContent {
        if let fetched = try? fetchedStore(), fetched.target == target { return fetched }
        do {
            guard let directory = AppBundleResources.directory("Baseline", in: bundle) else {
                return AppContent(target: target, baseline: nil, archives: [:])
            }
            let baseline = try EmbeddedBaseline.load(from: directory, target: target.rawValue)
            var archives: [String: Data] = [:]
            for item in baseline.components(for: target.rawValue) {
                guard item.contentClass == "data", ["config", "ui"].contains(item.kind), archives[item.name] == nil else {
                    throw EmbeddedBaseline.LoadError.malformed("app component \(item.name)")
                }
                archives[item.name] = try baseline.blob(for: item)
            }
            return AppContent(target: target, baseline: baseline, archives: archives)
        } catch {
            return AppContent(target: target, baseline: nil, archives: [:])
        }
    }
}
