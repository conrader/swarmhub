import SwiftUI

extension HerdrClient {
    struct CIInbox: Decodable {
        let ciFailures: [CIFailure]?
    }

    struct CIFailure: Decodable, Equatable, Identifiable {
        let id: Int64
        let bot: String
        let pullRequest: String
        let checkRun: String

        var checkURL: URL? {
            guard checkRun.wholeMatch(of: #/https:\/\/github\.com\/[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\/runs\/[0-9]+/#) != nil else { return nil }
            return URL(string: checkRun)
        }
    }
}

struct WorkspaceCIFailureRow: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let failure: HerdrClient.CIFailure
    let onReviewed: () -> Void
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failure.pullRequest.replacingOccurrences(of: "https://github.com/", with: "")).font(.body.weight(.medium))
            Text("\(failure.bot) · \(server.name)").font(.callout).foregroundStyle(.secondary)
            HStack {
                if let url = failure.checkURL { Link("Open failed check", destination: url) }
                Button("Mark reviewed") {
                    saving = true
                    error = nil
                    Task {
                        defer { saving = false }
                        do {
                            struct Receipt: Decodable { let reviewed: Bool }
                            let client = try store.herdrClient(for: server)
                            let receipt: Receipt = try await client.post("/api/attention/ci/\(failure.id)/review", [:])
                            if receipt.reviewed { onReviewed() }
                            else { error = "The workspace could not confirm this review." }
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(saving)
            }.controlSize(.small)
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }.padding(6)
    }
}
