import Foundation
import Security

/// `AgentApp --check-account-names` (P53): the live check of account naming before a release. Reads this Mac's
/// `connected-apps.json` (never writes it or store.json) and the Composio key the silent way the app does, then for each
/// connected account runs only its identity call (`ConnectedAppsStore.identify`). One line per account:
/// `app · current name · tool · key path · name`, or `… · no name: <result shape>` (keys and types only). It never sets an
/// alias, runs no other tool and prints no key or token. Exit 0 when it ran; 1 when it could not (no key, no list).
@MainActor enum HeadlessCheckAccountNames {
    static let flag = "--check-account-names"

    static func run(arguments: [String]) -> Int32 {
        SecKeychainSetUserInteractionAllowed(false)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp", directoryHint: .isDirectory)
        let key = KeychainHermesKeyStore().key(for: ConnectedAppsStore.keyAccount)
        return HeadlessRunLoop.wait {
            await check(directory: directory, key: key, session: ComposioClient.defaultSession, apiURL: ComposioClient.productionURL, output: { print($0); fflush(stdout) })
        }
    }

    /// The whole check against `apiURL`; tests pass a stubbed session.
    static func check(directory: URL, key: String, session: URLSession, apiURL: URL, output: (String) -> Void) async -> Int32 {
        let file = directory.appending(path: "connected-apps.json")
        guard let data = try? Data(contentsOf: file) else { output("No connected apps on this Mac (\(file.path) not found)."); return 0 }
        guard let configuration = try? JSONDecoder().decode(ConnectedAppsConfiguration.self, from: data) else { output("\(file.path) could not be read."); return 1 }
        guard !key.isEmpty else { output("The Composio key could not be read without a prompt; nothing was checked."); return 1 }
        func redacted(_ error: Error) -> String { error.localizedDescription.replacingOccurrences(of: key, with: "[key]") }
        let client = ComposioClient(apiKey: key, session: session, baseURL: apiURL)
        let accounts: [ComposioAccount]
        do { accounts = try await client.accounts(userID: configuration.userID) }
        catch { output("Listing the connected accounts failed: \(redacted(error))"); return 1 }
        var named = 0, unnamed = 0, inactive = 0
        for account in accounts {
            let head = "\(account.toolkit) · \(account.label)"
            guard account.isActive else { inactive += 1; output("\(head) · not active, skipped"); continue }
            do {
                let identity = try await ConnectedAppsStore.identify(account, userID: configuration.userID, using: client)
                if let found = identity.found { named += 1; output("\(head) · \(identity.tool ?? "-") · \(found.path) · \(found.name)") }
                else { unnamed += 1; output("\(head) · \(identity.tool ?? "no identity tool") · no name: \(identity.shape)") }
            } catch { unnamed += 1; output("\(head) · no name: \(redacted(error))") }
        }
        output("Checked \(accounts.count) account\(accounts.count == 1 ? "" : "s"): \(named) named, \(unnamed) no name, \(inactive) not active")
        return 0
    }
}
