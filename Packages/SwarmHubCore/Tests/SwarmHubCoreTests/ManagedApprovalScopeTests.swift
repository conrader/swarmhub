import Foundation
import Testing
@testable import SwarmHubCore

struct ManagedApprovalScopeTests {
    static let first = "task." + String(repeating: "1", count: 32)
    static let second = "task." + String(repeating: "2", count: 32)
    static let third = "task." + String(repeating: "3", count: 32)

    static func fence(_ task: String, decider: String? = nil, kind: String = "outbound", gate: String = "owner") -> String {
        var object = #"{"op":"approval","task":"\#(task)","kind":"\#(kind)","gate":"\#(gate)","intent":"TEST""#
        if let decider { object += #","decider":"\#(decider)""# }
        return "Done.\n```swarmhub\n" + object + "}\n```\n"
    }

    static func profile(_ id: String, _ host: String, _ name: String) throws -> AgentProfile {
        AgentProfile(id: id, name: id, address: try ConnectionAddress("https://" + host, profile: name))
    }

    static func cache(_ texts: [String], role: TranscriptRole = .assistant) -> ChatCache {
        ChatCache(messages: texts.enumerated().map { TranscriptMessage(id: "m\($0.offset)", role: role, text: $0.element) })
    }

    @Test func noticesFollowTheMacGrammar() {
        #expect(ManagedApprovalNotice.parse(in: Self.fence(Self.first, decider: "owner")) == [.init(task: Self.first, decider: "owner")])
        let array = "```swarmhub\n[{\"op\":\"approval\",\"task\":\"\(Self.first)\",\"kind\":\"coding\",\"gate\":\"coordinator\"},"
            + "{\"op\":\"approval\",\"task\":\"\(Self.second)\",\"kind\":\"money\",\"gate\":\"owner\",\"decider\":\"bad name!\"}]\n```"
        #expect(ManagedApprovalNotice.parse(in: array) == [.init(task: Self.first, decider: nil), .init(task: Self.second, decider: nil)])
        #expect(ManagedApprovalNotice.parse(in: "{\"op\":\"approval\",\"task\":\"\(Self.third)\",\"kind\":\"read\",\"gate\":\"owner\"}").count == 1)
        #expect(ManagedApprovalNotice.parse(in: "Please approve {\"op\":\"approval\",\"task\":\"\(Self.third)\",\"kind\":\"read\",\"gate\":\"owner\"}").isEmpty)
        #expect(ManagedApprovalNotice.parse(in: Self.fence("task.", decider: nil)).isEmpty)
        #expect(ManagedApprovalNotice.parse(in: Self.fence(Self.first, kind: "launch")).isEmpty)
        #expect(ManagedApprovalNotice.parse(in: Self.fence(Self.first, gate: "anyone")).isEmpty)
        #expect(ManagedApprovalNotice.parse(in: "```json\n{\"op\":\"approval\",\"task\":\"\(Self.first)\",\"kind\":\"read\",\"gate\":\"owner\"}\n```").isEmpty)
    }

    @Test func onlyDeviceRequiredBoxesProduceTargets() throws {
        let settings = DeviceApprovalSettings(defaults: DeviceApprovalFixtures.defaults())
        let owner = try Self.profile("a", "box.example.invalid", "owner")
        let worker = try Self.profile("b", "box.example.invalid", "worker")
        let legacy = try Self.profile("c", "legacy.example.invalid", "owner")
        let profiles = [owner, worker, legacy]
        let caches: [String: ChatCache] = [
            "a": Self.cache([Self.fence(Self.first, decider: "owner")]),
            "b": Self.cache([Self.fence(Self.second, decider: "owner"), Self.fence(Self.third), Self.fence(Self.first, decider: "owner"),
                             Self.fence("task." + String(repeating: "4", count: 32), decider: "ghost")]),
            "c": Self.cache([Self.fence(Self.first, decider: "owner")])]
        // Nothing is shown before an operator cutover is confirmed on this device.
        #expect(ManagedApprovalScope.targets(profiles: profiles, caches: caches, settings: settings).isEmpty)
        #expect(ManagedApprovalScope.requiredOrigins(profiles, settings: settings).isEmpty)
        #expect(ManagedApprovalScope.enrollableOrigins(profiles) == ["https://box.example.invalid", "https://legacy.example.invalid"])

        settings.confirmOperatorCutover("https://box.example.invalid")
        let targets = ManagedApprovalScope.targets(profiles: profiles, caches: caches, settings: settings)
        #expect(ManagedApprovalScope.requiredOrigins(profiles, settings: settings) == ["https://box.example.invalid"])
        #expect(targets.map(\.task) == [Self.first, Self.second, Self.third])
        #expect(targets.map(\.agentID) == ["a", "a", "b"])
        #expect(targets.map(\.profile) == ["owner", "owner", "worker"])
        #expect(targets.allSatisfy { $0.origin == "https://box.example.invalid" && $0.address == "https://box.example.invalid" })
        #expect(!targets.contains { $0.agentID == "c" })
    }

    @Test func userMessagesAndUnusableAddressesAreIgnored() throws {
        let settings = DeviceApprovalSettings(defaults: DeviceApprovalFixtures.defaults())
        let proxied = try Self.profile("p", "box.example.invalid/hermes", "owner")
        let plain = try Self.profile("q", "box.example.invalid", "owner")
        settings.confirmOperatorCutover("https://box.example.invalid")
        #expect(ManagedApprovalScope.origin(of: proxied.address) == nil)
        let caches = ["p": Self.cache([Self.fence(Self.first)]), "q": Self.cache([Self.fence(Self.second)], role: .user)]
        #expect(ManagedApprovalScope.targets(profiles: [proxied, plain], caches: caches, settings: settings).isEmpty)
        let old = (0..<(ManagedApprovalScope.messageLimit + 1)).map { $0 == 0 ? Self.fence(Self.third) : "reply \($0)" }
        #expect(ManagedApprovalScope.targets(profiles: [plain], caches: ["q": Self.cache(old)], settings: settings).isEmpty)
    }
}

/// The Swift twin of scripts/check-ios-approvals.py: no shared-key approval symbol in code the iOS app compiles.
struct IOSApprovalBoundaryTests {
    @Test func iosTargetSourcesCarryNoSharedKeyPath() throws {
        let root = UpdateVerifierTests.repository
        let banned = ["HMAC", "SymmetricKey", "isValidAuthenticationCode", "swarmhub-approval-v1", "control/v1",
                      "X-SwarmHub-Signature", "ManagedRemoteControl", "requestForBox", "ManagedLocalControl"]
        var files: [URL] = []
        for folder in ["Apps/iOS/Sources", "Packages/SwarmHubCore/Sources"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL { if url.pathExtension == "swift" { files.append(url) } }
        }
        #expect(files.count > 20)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line) }
            for (number, line) in code.enumerated() {
                for token in banned where line.contains(token) && !line.contains("/// ") {
                    Issue.record("\(file.lastPathComponent):\(number + 1) contains \(token)")
                }
            }
        }
    }
}
